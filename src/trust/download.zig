//! Bounded artifact/result transport (TRUST-009/011/012, STRICT-007/008).
//!
//! The receiver supplies a digest and length, never an identity learned from an
//! HTTP header. Store.importReader owns the private staging/atomic commit point.
//! Retries start from byte zero: neither a partial filename nor a server ETag is
//! an integrity proof. A 304 or explicit reuse rehashes the committed object.
//! Redirects are handled here, not by std.http: credentials require an identical
//! origin (scheme, canonical host, effective port), not merely a parent domain.
//! Errors and results carry no URL or authorization value; credentials are
//! memory-only headers and are never part of a lockfile/provenance record.
const std = @import("std");
const store_module = @import("../core/store.zig");
const digest = @import("../core/digest.zig");
const canonical = @import("../core/canonical.zig");
const redact = @import("../core/redact.zig");
const cache_module = @import("../plan/cache.zig");
const keys = @import("keys.zig");

pub const Error = error{
    InvalidUrl,
    CredentialsInUrl,
    InvalidHeader,
    InvalidLimits,
    DownloadTooLarge,
    LengthMismatch,
    TruncatedBody,
    UnexpectedStatus,
    RetryLimit,
    RedirectLimit,
    InvalidRedirect,
    AuthRedirectRefused,
    InsecureRedirect,
    UnsupportedEncoding,
    UnverifiedNotModified,
    ActionMismatch,
    ArtifactMismatch,
    ProvenanceRequired,
    ProvenanceIncompatible,
    InvalidOutputDeclaration,
    UndeclaredOutput,
    MissingOutput,
    DuplicateOutput,
    OutputTooLarge,
    ActionNotReconciled,
    ActionAlreadyVerified,
    ActionFailed,
    InvalidReconciliation,
};

pub const Artifact = struct { digest: digest.Digest, byte_length: u64 };

pub const Retry = struct {
    max_attempts: u8 = 3,
    initial_delay_ms: u32 = 25,
    max_delay_ms: u32 = 1000,
};

pub const Request = struct {
    url: []const u8,
    expected: Artifact,
    /// Complete header value, e.g. "Bearer ...". Never embed it in url.
    authorization: ?[]const u8 = null,
    if_none_match: ?[]const u8 = null,
    reuse_verified: bool = false,
    max_bytes: u64 = 1024 * 1024 * 1024,
    max_redirects: u8 = 5,
    retry: Retry = .{},
};

pub const Result = struct {
    artifact: Artifact,
    not_modified: bool = false,
    attempts: u8,
    /// Opaque, bounded validator; callers own it through Result.deinit.
    etag: ?[]u8 = null,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Result) void {
        if (self.etag) |value| self.gpa.free(value);
        self.* = undefined;
    }
};

pub const Client = struct {
    http: std.http.Client,
    store: store_module.Store,

    pub fn init(io: std.Io, gpa: std.mem.Allocator, store: store_module.Store) Client {
        return .{ .http = .{ .io = io, .allocator = gpa }, .store = store };
    }

    pub fn deinit(self: *Client) void {
        self.http.deinit();
        self.* = undefined;
    }

    pub fn download(self: *Client, request: Request) !Result {
        try validateRequest(request);
        _ = try checkedUri(request.url, request.authorization);
        if (request.reuse_verified and self.store.hasBlob(request.expected.digest)) {
            try verifyExisting(self.store, request.expected);
            return .{ .artifact = request.expected, .attempts = 0, .gpa = self.http.allocator };
        }
        var attempt: u8 = 1;
        var delay: u32 = request.retry.initial_delay_ms;
        while (true) : (attempt += 1) {
            var result = self.downloadAttempt(request) catch |err| {
                // A failed store import removes its own private staging path.
                // A retry always receives and verifies a new complete body.
                const transient = err == error.RetryLimit or err == error.TruncatedBody or
                    err == error.ConnectionResetByPeer or err == error.ConnectionRefused or
                    err == error.ConnectionTimedOut or err == error.HttpConnectionClosing or
                    err == error.HttpConnectionReset or err == error.HttpRequestTruncated;
                if (!transient or attempt >= request.retry.max_attempts) return err;
                try self.http.io.sleep(.fromMilliseconds(delay), .awake);
                delay = @min(request.retry.max_delay_ms, delay *| 2);
                continue;
            };
            result.attempts = attempt;
            return result;
        }
    }

    fn downloadAttempt(self: *Client, request: Request) !Result {
        const gpa = self.http.allocator;
        var url = try gpa.dupe(u8, request.url);
        defer gpa.free(url);
        var redirects: u8 = 0;
        while (true) {
            const uri = try checkedUri(url, request.authorization);
            var extra: [1]std.http.Header = undefined;
            var extra_count: usize = 0;
            if (request.if_none_match) |validator| {
                extra[0] = .{ .name = "If-None-Match", .value = validator };
                extra_count = 1;
            }
            var req = try self.http.request(.GET, uri, .{
                .redirect_behavior = .unhandled,
                .keep_alive = false,
                .headers = .{
                    .authorization = if (request.authorization) |value| .{ .override = value } else .omit,
                    .accept_encoding = .{ .override = "identity" },
                },
                .extra_headers = extra[0..extra_count],
            });
            defer req.deinit();
            try req.sendBodiless();
            var response = try req.receiveHead(&.{});
            const status = @backingInt(response.head.status);
            if (status == 301 or status == 302 or status == 303 or status == 307 or status == 308) {
                if (redirects >= request.max_redirects) return error.RedirectLimit;
                const location = response.head.location orelse return error.InvalidRedirect;
                if (location.len > 4096) return error.InvalidRedirect;
                var redirect_buffer: [8192]u8 = undefined;
                @memcpy(redirect_buffer[0..location.len], location);
                var unused: []u8 = &redirect_buffer;
                const next = uri.resolveInPlace(location.len, &unused) catch return error.InvalidRedirect;
                const next_url = try std.fmt.allocPrint(gpa, "{f}", .{next.fmt(.all)});
                errdefer gpa.free(next_url);
                const checked_next = try checkedUri(next_url, request.authorization);
                if (std.ascii.eqlIgnoreCase(uri.scheme, "https") and !std.ascii.eqlIgnoreCase(checked_next.scheme, "https")) {
                    return error.InsecureRedirect;
                }
                if (request.authorization != null and !try sameOrigin(uri, checked_next)) return error.AuthRedirectRefused;
                // Unauthenticated cross-origin redirects send no authorization;
                // authenticated ones are refused before opening another socket.
                gpa.free(url);
                url = next_url;
                redirects += 1;
                continue;
            }
            if (status == 429 or status == 503) return error.RetryLimit;
            if (status == 304) {
                if (request.if_none_match == null) return error.UnverifiedNotModified;
                verifyExisting(self.store, request.expected) catch return error.UnverifiedNotModified;
                return .{
                    .artifact = request.expected,
                    .not_modified = true,
                    .attempts = 0,
                    .etag = try copyEtag(gpa, response.head.bytes, request.authorization),
                    .gpa = gpa,
                };
            }
            if (status != 200) return error.UnexpectedStatus;
            if (response.head.content_encoding != .identity) return error.UnsupportedEncoding;
            if (response.head.content_length) |length| {
                if (length != request.expected.byte_length) return error.LengthMismatch;
            }
            const etag = try copyEtag(gpa, response.head.bytes, request.authorization);
            errdefer if (etag) |value| gpa.free(value);
            var transfer_buffer: [8192]u8 = undefined;
            const body = response.reader(&transfer_buffer);
            // Read one extra byte: even chunked/close-delimited overlong bodies
            // fail length verification, without unbounded writes to staging.
            var bound_buffer: [8192]u8 = undefined;
            var bounded = body.limited(.limited64(request.expected.byte_length + 1), &bound_buffer);
            const object = self.store.importReader(&bounded.interface, request.expected.byte_length, request.expected.digest) catch |err| switch (err) {
                error.ReadFailed => return error.TruncatedBody,
                error.LengthMismatch => return if (bounded.remaining != .nothing) error.TruncatedBody else error.LengthMismatch,
                else => return err,
            };
            return .{ .artifact = .{ .digest = object, .byte_length = request.expected.byte_length }, .attempts = 0, .etag = etag, .gpa = gpa };
        }
    }
};

fn validateRequest(request: Request) Error!void {
    if (request.retry.max_attempts == 0 or request.retry.max_attempts > 10 or request.max_redirects > 16 or
        request.retry.initial_delay_ms > request.retry.max_delay_ms or request.retry.max_delay_ms > 60_000)
        return error.InvalidLimits;
    if (request.expected.byte_length > request.max_bytes or request.expected.byte_length == std.math.maxInt(u64)) return error.DownloadTooLarge;
    if (request.authorization) |value| try validHeader(value);
    if (request.if_none_match) |value| {
        try validHeader(value);
        if (containsCredential(value, request.authorization)) return error.InvalidHeader;
    }
}

fn validHeader(value: []const u8) Error!void {
    if (value.len == 0 or value.len > 1024) return error.InvalidHeader;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidHeader;
}

fn containsCredential(value: []const u8, authorization: ?[]const u8) bool {
    if (authorization) |header| {
        const clean_header = std.mem.trim(u8, header, " ");
        const secret = if (std.mem.indexOfScalar(u8, clean_header, ' ')) |space|
            std.mem.trim(u8, clean_header[space + 1 ..], " ")
        else
            clean_header;
        if (secret.len != 0 and std.mem.indexOf(u8, value, secret) != null) return true;
    }
    for (redact.patterns) |pattern| {
        if (std.mem.indexOf(u8, value, pattern.prefix)) |start| {
            if (value.len - start - pattern.prefix.len >= pattern.min_tail) return true;
        }
    }
    return false;
}

fn checkedUri(url: []const u8, authorization: ?[]const u8) Error!std.Uri {
    if (url.len == 0 or url.len > 4096) return error.InvalidUrl;
    for (url) |byte| if (byte <= 0x20 or byte == 0x7f or byte == '\\') return error.InvalidUrl;
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.InvalidUrl;
    if (uri.host == null) return error.InvalidUrl;
    if (uri.user != null or uri.password != null or uri.fragment != null) return error.CredentialsInUrl;
    var decoded: [4096]u8 = undefined;
    const raw = (std.Uri.Component{ .percent_encoded = url }).toRaw(&decoded) catch return error.InvalidUrl;
    if (containsCredential(raw, authorization)) return error.CredentialsInUrl;
    if (uri.query) |query| {
        var query_buffer: [4096]u8 = undefined;
        const plain = query.toRaw(&query_buffer) catch return error.InvalidUrl;
        var pairs = std.mem.splitScalar(u8, plain, '&');
        while (pairs.next()) |pair| {
            const name = pair[0 .. std.mem.indexOfScalar(u8, pair, '=') orelse pair.len];
            if (redact.looksSecretName(name) or std.ascii.eqlIgnoreCase(name, "key")) return error.CredentialsInUrl;
        }
    }
    return uri;
}

fn sameOrigin(a: std.Uri, b: std.Uri) !bool {
    var a_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    var b_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const a_host = try std.Io.net.HostName.fromUri(a, &a_buffer);
    const b_host = try std.Io.net.HostName.fromUri(b, &b_buffer);
    const a_port = a.port orelse if (std.ascii.eqlIgnoreCase(a.scheme, "https")) @as(u16, 443) else 80;
    const b_port = b.port orelse if (std.ascii.eqlIgnoreCase(b.scheme, "https")) @as(u16, 443) else 80;
    return std.ascii.eqlIgnoreCase(a.scheme, b.scheme) and a_host.eql(b_host) and a_port == b_port;
}

fn verifyExisting(store: store_module.Store, expected: Artifact) !void {
    var path_buffer: [128]u8 = undefined;
    return verifyFile(store.io, store.dir, store.blobPath(expected.digest, &path_buffer), expected);
}

fn verifyFile(io: std.Io, dir: std.Io.Dir, path: []const u8, expected: Artifact) !void {
    const file = dir.openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.UnknownObject,
        else => return err,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size != expected.byte_length) return error.CorruptObject;
    // No allocation proportional to an untrusted on-disk size. Rehash the
    // bytes through the core digest primitive, bounded by the receiver length.
    var reader = file.readerStreaming(io, &.{});
    var buffer: [8192]u8 = undefined;
    var hasher = digest.Sha256.init(.{});
    var total: u64 = 0;
    while (true) {
        const count = try reader.interface.readSliceShort(&buffer);
        if (count == 0) break;
        if (count > expected.byte_length - total) return error.CorruptObject;
        total += count;
        hasher.update(buffer[0..count]);
    }
    var actual: digest.Digest = undefined;
    hasher.final(&actual.bytes);
    if (total != expected.byte_length or !actual.eql(expected.digest)) return error.CorruptObject;
}

fn copyEtag(gpa: std.mem.Allocator, head: []const u8, authorization: ?[]const u8) !?[]u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    var found: ?[]const u8 = null;
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], "etag")) continue;
        if (found != null) return error.InvalidHeader;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        try validHeader(value);
        if (containsCredential(value, authorization)) return error.InvalidHeader;
        found = value;
    }
    return if (found) |value| try gpa.dupe(u8, value) else null;
}

/// A remote cache record is an untrusted computation claim, not just a blob.
/// The trust root is supplied by the caller, never by the worker. Signatures
/// bind every policy/backend/output field plus the requested action and length.
pub const CacheClaim = struct {
    entry: cache_module.Entry,
    byte_length: u64,
    signatures: []const keys.SignatureEntry = &.{},
};

pub const CacheRequest = struct {
    action_digest: digest.Digest,
    requirements: cache_module.Requirements,
    authorities: keys.KeyRing = .{ .entries = &.{} },
    threshold: usize = 1,
};

/// Canonical signing transcript. No transport URL, credentials, or worker key
/// enrollment is included. Output order is significant, as in the cache entry.
pub fn provenanceBytes(gpa: std.mem.Allocator, claim: CacheClaim) ![]u8 {
    if (claim.byte_length > canonical.max_safe_integer) return error.InvalidLimits;
    const outputs = try gpa.alloc(canonical.Value, claim.entry.outputs.len);
    defer gpa.free(outputs);
    const fields = try gpa.alloc([2]canonical.Entry, claim.entry.outputs.len);
    defer gpa.free(fields);
    for (claim.entry.outputs, 0..) |output, index| {
        fields[index] = .{
            .{ .key = "digest", .value = .{ .string = output.digest } },
            .{ .key = "name", .value = .{ .string = output.name } },
        };
        outputs[index] = .{ .object = &fields[index] };
    }
    var entries = [_]canonical.Entry{
        .{ .key = "action", .value = .{ .string = claim.entry.action_digest } },
        .{ .key = "artifact", .value = .{ .string = claim.entry.artifact_digest } },
        .{ .key = "backend", .value = .{ .string = claim.entry.backend_identity } },
        .{ .key = "byteLength", .value = .{ .integer = @intCast(claim.byte_length) } },
        .{ .key = "format", .value = .{ .string = "jckg-cache-provenance-v1" } },
        .{ .key = "outputs", .value = .{ .array = outputs } },
        .{ .key = "policy", .value = .{ .string = @tagName(claim.entry.policy) } },
        .{ .key = "reproducible", .value = .{ .boolean = claim.entry.reproducible } },
    };
    return canonical.encodeAlloc(gpa, .{ .object = &entries });
}

fn verifyClaim(gpa: std.mem.Allocator, request: CacheRequest, claim: CacheClaim) !Artifact {
    const action = digest.Digest.parse(claim.entry.action_digest) catch return error.ActionMismatch;
    if (!action.eql(request.action_digest)) return error.ActionMismatch;
    const artifact = digest.Digest.parse(claim.entry.artifact_digest) catch return error.ArtifactMismatch;
    if (claim.entry.incompatibility(request.requirements) != null) return error.ProvenanceIncompatible;
    const signature_required = claim.entry.policy == .release or request.requirements.require_reproducible or request.requirements.require_backend != null;
    if (signature_required or claim.signatures.len != 0) {
        if (claim.signatures.len == 0 or request.threshold == 0) return error.ProvenanceRequired;
        const transcript = try provenanceBytes(gpa, claim);
        defer gpa.free(transcript);
        try request.authorities.verifyThreshold(.targets, request.threshold, transcript, claim.signatures);
    }
    return .{ .digest = artifact, .byte_length = claim.byte_length };
}

/// Verify the computation claim before importing any bytes or admitting an
/// entry to the action cache. A guessed action digest grants no authority.
pub fn importCacheClaim(store: store_module.Store, cache: *cache_module.Cache, request: CacheRequest, claim: CacheClaim, bytes: []const u8) !cache_module.RecordOutcome {
    const artifact = try verifyClaim(store.gpa, request, claim);
    if (bytes.len != artifact.byte_length) return error.LengthMismatch;
    _ = try store.importBytes(bytes, artifact.digest);
    return cache.record(claim.entry);
}

/// Recheck provenance and the actual stored bytes on every external-cache hit.
/// Persisted claim fields alone (including policy="release") are never trusted.
pub fn useCacheClaim(store: store_module.Store, request: CacheRequest, claim: CacheClaim) !digest.Digest {
    const artifact = try verifyClaim(store.gpa, request, claim);
    try verifyExisting(store, artifact);
    return artifact.digest;
}

pub const ReturnedArtifact = struct {
    name: []const u8,
    /// Borrowed bytes received into memory or a private staging area.
    bytes: []const u8,
};

pub const CollectionLimits = struct {
    max_outputs: usize = 1024,
    max_output_bytes: u64 = 64 * 1024 * 1024,
    max_total_bytes: u64 = 256 * 1024 * 1024,
};

pub const ReportedAction = struct {
    action_digest: digest.Digest,
    state: enum { unknown, running, completed, failed },
};

/// Receiver-side result collection, independent of the worker's wire format.
/// Names come from the requested action, not its reply. All names and all bytes
/// are checked before the first Store import. A transport disconnect leaves the
/// action uncertain; a completed reconciliation only permits collection, never
/// proves success. Only fully verified, published results set `verified`.
///
/// The request/claim use the existing computation-provenance policy. Valid blobs
/// left by a later filesystem failure are merely immutable content: no action
/// cache claim is admitted until every output and the result artifact is stored.
pub const ResultCollector = struct {
    action_digest: digest.Digest,
    declared_outputs: []const []const u8,
    limits: CollectionLimits,
    state: enum { running, interrupted, awaiting_result, verified, failed } = .running,

    /// Declarations are borrowed, immutable for the collector's lifetime.
    pub fn init(action_digest: digest.Digest, declared_outputs: []const []const u8, limits: CollectionLimits) !ResultCollector {
        if (declared_outputs.len > limits.max_outputs or limits.max_outputs > 1024) return error.InvalidLimits;
        for (declared_outputs, 0..) |name, index| {
            if (name.len == 0 or name.len > 4096 or !std.unicode.utf8ValidateSlice(name)) return error.InvalidOutputDeclaration;
            for (declared_outputs[index + 1 ..]) |other| {
                if (std.mem.eql(u8, name, other)) return error.DuplicateOutput;
            }
        }
        return .{ .action_digest = action_digest, .declared_outputs = declared_outputs, .limits = limits };
    }

    pub fn interrupted(self: *ResultCollector) void {
        if (self.state != .verified) self.state = .interrupted;
    }

    pub fn succeeded(self: ResultCollector) bool {
        return self.state == .verified;
    }

    /// The caller obtains this report on its reauthenticated control channel.
    /// Unknown/running is not completion; a different action cannot reconcile
    /// this one. Even completed must still pass every output/provenance check.
    pub fn reconcile(self: *ResultCollector, report: ReportedAction) !void {
        if (!report.action_digest.eql(self.action_digest)) return error.ActionMismatch;
        if (self.state == .verified) return error.ActionAlreadyVerified;
        self.state = switch (report.state) {
            .unknown => .interrupted,
            .running => .running,
            .completed => .awaiting_result,
            .failed => .failed,
        };
        if (self.state == .failed) return error.ActionFailed;
    }

    /// Bounded control-plane JSON adapter; not a new worker `run` wire schema.
    /// Accepts exactly {"actionDigest":"sha256:...","state":"completed"|...}.
    pub fn reconcileBytes(self: *ResultCollector, gpa: std.mem.Allocator, bytes: []const u8) !void {
        if (bytes.len > 4096) return error.InvalidReconciliation;
        var diagnostic: canonical.Diagnostic = .{};
        const document = canonical.parse(gpa, bytes, &diagnostic) catch return error.InvalidReconciliation;
        defer document.deinit(gpa);
        const fields = switch (document) {
            .object => |entries| entries,
            else => return error.InvalidReconciliation,
        };
        if (fields.len != 2) return error.InvalidReconciliation;
        var action_text: ?[]const u8 = null;
        var state_text: ?[]const u8 = null;
        for (fields) |field| {
            const text = switch (field.value) {
                .string => |value| value,
                else => return error.InvalidReconciliation,
            };
            if (std.mem.eql(u8, field.key, "actionDigest")) {
                action_text = text;
            } else if (std.mem.eql(u8, field.key, "state")) {
                state_text = text;
            } else return error.InvalidReconciliation;
        }
        const action = digest.Digest.parse(action_text orelse return error.InvalidReconciliation) catch return error.InvalidReconciliation;
        const text = state_text orelse return error.InvalidReconciliation;
        const report_state: @FieldType(ReportedAction, "state") = if (std.mem.eql(u8, text, "unknown"))
            .unknown
        else if (std.mem.eql(u8, text, "running"))
            .running
        else if (std.mem.eql(u8, text, "completed"))
            .completed
        else if (std.mem.eql(u8, text, "failed"))
            .failed
        else
            return error.InvalidReconciliation;
        try self.reconcile(.{ .action_digest = action, .state = report_state });
    }

    /// `checkpoint` was recorded by the receiver before interruption, not
    /// inferred from the partial filename or accepted from a resumed reply.
    /// Whole-output verification remains mandatory in collect, even when every
    /// reused chunk matches its checkpoint.
    pub fn verifyResumedFile(self: ResultCollector, io: std.Io, dir: std.Io.Dir, path: []const u8, checkpoint: Artifact) !void {
        if (self.state != .awaiting_result) return error.ActionNotReconciled;
        if (checkpoint.byte_length > self.limits.max_output_bytes) return error.OutputTooLarge;
        try verifyFile(io, dir, path, checkpoint);
    }

    fn declares(self: ResultCollector, name: []const u8) bool {
        for (self.declared_outputs) |declared| {
            if (std.mem.eql(u8, name, declared)) return true;
        }
        return false;
    }

    pub fn collect(self: *ResultCollector, store: store_module.Store, cache: *cache_module.Cache, request: CacheRequest, claim: CacheClaim, returned: []const ReturnedArtifact, result_bytes: []const u8) !cache_module.RecordOutcome {
        if (self.state != .awaiting_result) return error.ActionNotReconciled;
        if (!request.action_digest.eql(self.action_digest)) return error.ActionMismatch;
        if (claim.entry.outputs.len > self.declared_outputs.len or returned.len > self.declared_outputs.len) return error.UndeclaredOutput;
        if (claim.entry.outputs.len != self.declared_outputs.len or returned.len != self.declared_outputs.len) return error.MissingOutput;
        if (result_bytes.len > self.limits.max_output_bytes) return error.OutputTooLarge;
        for (claim.entry.outputs, 0..) |output, index| {
            if (!self.declares(output.name)) return error.UndeclaredOutput;
            for (claim.entry.outputs[index + 1 ..]) |other| {
                if (std.mem.eql(u8, output.name, other.name)) return error.DuplicateOutput;
            }
            _ = digest.Digest.parse(output.digest) catch return error.ArtifactMismatch;
        }
        const artifact = try verifyClaim(store.gpa, request, claim);
        if (result_bytes.len != artifact.byte_length) return error.LengthMismatch;
        if (!digest.ofBlob(result_bytes).eql(artifact.digest)) return error.IntegrityMismatch;
        var total: u64 = 0;
        for (returned, 0..) |output, index| {
            if (!self.declares(output.name)) return error.UndeclaredOutput;
            for (returned[index + 1 ..]) |other| {
                if (std.mem.eql(u8, output.name, other.name)) return error.DuplicateOutput;
            }
            if (output.bytes.len > self.limits.max_output_bytes or output.bytes.len > self.limits.max_total_bytes - total) return error.OutputTooLarge;
            total += output.bytes.len;
            const expected = claimOutputDigest(claim, output.name) orelse return error.UndeclaredOutput;
            if (!digest.ofBlob(output.bytes).eql(expected)) return error.IntegrityMismatch;
        }
        // No trusted Store or cache mutation precedes the complete preflight.
        for (returned) |output| {
            const expected = claimOutputDigest(claim, output.name) orelse return error.UndeclaredOutput;
            _ = try store.importBytes(output.bytes, expected);
        }
        _ = try store.importBytes(result_bytes, artifact.digest);
        const outcome = try cache.record(claim.entry);
        self.state = .verified;
        return outcome;
    }
};

fn claimOutputDigest(claim: CacheClaim, name: []const u8) ?digest.Digest {
    for (claim.entry.outputs) |output| {
        if (std.mem.eql(u8, output.name, name)) return digest.Digest.parse(output.digest) catch null;
    }
    return null;
}

/// Scripted, real HTTP/1.1 server for offline integration tests. init binds only
/// 127.0.0.1:0; start must be called on a stable address, deinit joins/cancels the
/// task before freeing resources. Routes/responses are borrowed for its life.
pub const FixtureResponse = struct {
    status: u16 = 200,
    body: []const u8 = "",
    declared_length: ?u64 = null,
    location: ?[]const u8 = null,
    etag: ?[]const u8 = null,
    /// Return 304 only when the request's If-None-Match equals etag.
    conditional: bool = false,
    /// Exercise a body with no Content-Length but bounded chunked framing.
    chunked: bool = false,
};

pub const FixtureRoute = struct {
    path: []const u8,
    /// Last response repeats; prior responses each serve once.
    responses: []const FixtureResponse,
};

pub const FixtureStats = struct {
    requests: usize = 0,
    authorized_requests: usize = 0,
    conditional_requests: usize = 0,
    credential_url_requests: usize = 0,
};

pub const FixtureServer = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    server: std.Io.net.Server,
    routes: []const FixtureRoute,
    hits: []usize,
    mutex: std.Io.Mutex = .init,
    stats: FixtureStats = .{},
    future: ?std.Io.Future(anyerror!void) = null,

    pub fn init(io: std.Io, gpa: std.mem.Allocator, routes: []const FixtureRoute) !FixtureServer {
        for (routes) |route| {
            if (route.responses.len == 0 or route.path.len == 0 or route.path[0] != '/') return error.InvalidUrl;
            for (route.responses) |response| {
                if (response.location) |value| try validHeader(value);
                if (response.etag) |value| try validHeader(value);
            }
        }
        const address = std.Io.net.IpAddress{ .ip4 = .loopback(0) };
        var server = try address.listen(io, .{});
        errdefer server.deinit(io);
        const hits = try gpa.alloc(usize, routes.len);
        @memset(hits, 0);
        return .{ .io = io, .gpa = gpa, .server = server, .routes = routes, .hits = hits };
    }

    pub fn start(self: *FixtureServer) !void {
        self.future = try self.io.concurrent(serve, .{self});
    }

    pub fn deinit(self: *FixtureServer) void {
        if (self.future) |*future| _ = future.cancel(self.io) catch {};
        self.server.deinit(self.io);
        self.gpa.free(self.hits);
        self.* = undefined;
    }

    pub fn port(self: *const FixtureServer) u16 {
        return self.server.socket.address.ip4.port;
    }

    pub fn urlAlloc(self: *const FixtureServer, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
        return gpa.print("http://127.0.0.1:{d}{s}", .{ self.port(), path });
    }

    /// Counters only: the fixture never retains request URLs/header values.
    pub fn snapshot(self: *FixtureServer) FixtureStats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.stats;
    }

    fn serve(self: *FixtureServer) anyerror!void {
        while (true) {
            const stream = try self.server.accept(self.io);
            defer stream.close(self.io);
            try self.respond(stream);
        }
    }

    fn respond(self: *FixtureServer, stream: std.Io.net.Stream) !void {
        var read_buffer: [8192]u8 = undefined;
        var reader = stream.reader(self.io, &read_buffer);
        const first = try reader.interface.takeDelimiterInclusive('\n');
        if (!std.mem.startsWith(u8, first, "GET ")) return error.InvalidUrl;
        const end = std.mem.indexOfScalarPos(u8, first, 4, ' ') orelse return error.InvalidUrl;
        var path_buffer: [4096]u8 = undefined;
        if (end - 4 > path_buffer.len) return error.InvalidUrl;
        const path = path_buffer[0 .. end - 4];
        @memcpy(path, first[4..end]);
        var authorized = false;
        var conditional: [1024]u8 = undefined;
        var conditional_len: usize = 0;
        var head_length = first.len;
        while (true) {
            const line = try reader.interface.takeDelimiterInclusive('\n');
            head_length += line.len;
            if (head_length > 16 * 1024) return error.InvalidHeader;
            if (std.mem.eql(u8, line, "\r\n")) break;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeader;
            if (std.ascii.eqlIgnoreCase(line[0..colon], "authorization")) authorized = true;
            if (std.ascii.eqlIgnoreCase(line[0..colon], "if-none-match")) {
                const value = std.mem.trim(u8, line[colon + 1 ..], " \r\n\t");
                if (value.len > conditional.len) return error.InvalidHeader;
                conditional_len = value.len;
                @memcpy(conditional[0..value.len], value);
            }
        }
        var response = FixtureResponse{ .status = 404 };
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.stats.requests += 1;
            if (authorized) self.stats.authorized_requests += 1;
            if (conditional_len != 0) self.stats.conditional_requests += 1;
            if (containsCredential(path, null) or std.mem.indexOf(u8, path, "token=") != null) self.stats.credential_url_requests += 1;
            for (self.routes, 0..) |route, index| {
                if (!std.mem.eql(u8, path, route.path)) continue;
                response = route.responses[@min(self.hits[index], route.responses.len - 1)];
                self.hits[index] += 1;
                break;
            }
        }
        const not_modified = response.conditional and response.etag != null and std.mem.eql(u8, conditional[0..conditional_len], response.etag.?);
        var write_buffer: [8192]u8 = undefined;
        var writer = stream.writer(self.io, &write_buffer);
        try writer.interface.print("HTTP/1.1 {d} Fixture\r\nConnection: close\r\n", .{if (not_modified) @as(u16, 304) else response.status});
        if (response.chunked and !not_modified) {
            try writer.interface.writeAll("Transfer-Encoding: chunked\r\n");
        } else {
            try writer.interface.print("Content-Length: {d}\r\n", .{if (not_modified) @as(u64, 0) else response.declared_length orelse response.body.len});
        }
        if (response.location) |location| try writer.interface.print("Location: {s}\r\n", .{location});
        if (response.etag) |etag| try writer.interface.print("ETag: {s}\r\n", .{etag});
        if (response.status == 429 or response.status == 503) try writer.interface.writeAll("Retry-After: 0\r\n");
        try writer.interface.writeAll("\r\n");
        if (!not_modified) {
            if (response.chunked) {
                if (response.body.len != 0) {
                    try writer.interface.print("{x}\r\n", .{response.body.len});
                    try writer.interface.writeAll(response.body);
                    try writer.interface.writeAll("\r\n");
                }
                try writer.interface.writeAll("0\r\n\r\n");
            } else try writer.interface.writeAll(response.body);
        }
        try writer.interface.flush();
    }
};

fn testStore(io: std.Io, gpa: std.mem.Allocator, prefix: []const u8) !struct { name: []u8, store: store_module.Store } {
    var token: [12]u8 = undefined;
    io.random(&token);
    const name = try gpa.print(".zig-cache/{s}-{s}", .{ prefix, std.fmt.bytesToHex(token, .lower) });
    errdefer gpa.free(name);
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, name);
    var dir = try cwd.openDir(io, name, .{});
    errdefer dir.close(io);
    const store = store_module.Store.init(io, gpa, dir);
    try store.ensureLayout();
    return .{ .name = name, .store = store };
}

fn cleanupTestStore(io: std.Io, gpa: std.mem.Allocator, fixture: anytype) void {
    fixture.store.dir.close(io);
    std.Io.Dir.cwd().deleteTree(io, fixture.name) catch {};
    gpa.free(fixture.name);
}

test "m07/TRUST-009 bound and verify downloads" {
    std.debug.print("JCKG_EVIDENCE TRUST-009\n", .{});
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const bytes = "verified loopback artifact\n";
    const object = digest.ofBlob(bytes);
    const responses = [_]FixtureResponse{
        .{ .body = bytes, .etag = "\"artifact-v1\"", .conditional = true },
        .{ .body = "wrong bytes of same length!" },
        .{ .body = "short", .declared_length = bytes.len },
        .{ .status = 429 }, .{ .status = 503 },
        .{ .body = bytes, .chunked = true },
    };
    const retry_responses = [_]FixtureResponse{ responses[3], responses[4], responses[0] };
    const interruption = [_]FixtureResponse{ responses[2], responses[0] };
    const overlong = [_]FixtureResponse{.{ .body = bytes ++ "x", .chunked = true }};
    const empty_response = [_]FixtureResponse{.{}};
    const declared_wrong = [_]FixtureResponse{.{ .body = bytes, .declared_length = bytes.len + 1 }};
    const routes = [_]FixtureRoute{
        .{ .path = "/ok", .responses = responses[0..1] },
        .{ .path = "/wrong", .responses = responses[1..2] },
        .{ .path = "/short", .responses = responses[2..3] },
        .{ .path = "/retry", .responses = &retry_responses },
        .{ .path = "/interrupt", .responses = &interruption },
        .{ .path = "/chunked", .responses = responses[5..6] },
        .{ .path = "/overlong", .responses = &overlong },
        .{ .path = "/limited", .responses = responses[3..4] },
        .{ .path = "/empty", .responses = &empty_response },
        .{ .path = "/declared-wrong", .responses = &declared_wrong },
    };
    var server = try FixtureServer.init(io, gpa, &routes);
    defer server.deinit();
    try server.start();
    const fixture = try testStore(io, gpa, "trust009");
    defer cleanupTestStore(io, gpa, fixture);
    var client = Client.init(io, gpa, fixture.store);
    defer client.deinit();
    const expected = Artifact{ .digest = object, .byte_length = bytes.len };
    const missing_url = try server.urlAlloc(gpa, "/ok");
    defer gpa.free(missing_url);
    try std.testing.expectError(error.UnverifiedNotModified, client.download(.{ .url = missing_url, .expected = expected, .if_none_match = "\"artifact-v1\"" }));
    try std.testing.expect(!fixture.store.hasBlob(object));
    const declared_wrong_url = try server.urlAlloc(gpa, "/declared-wrong");
    defer gpa.free(declared_wrong_url);
    try std.testing.expectError(error.LengthMismatch, client.download(.{ .url = declared_wrong_url, .expected = expected }));
    try std.testing.expect(!fixture.store.hasBlob(object));
    const short_url = try server.urlAlloc(gpa, "/short");
    defer gpa.free(short_url);
    try std.testing.expectError(error.TruncatedBody, client.download(.{ .url = short_url, .expected = expected, .retry = .{ .max_attempts = 1 } }));
    try std.testing.expect(!fixture.store.hasBlob(object));
    const wrong_url = try server.urlAlloc(gpa, "/wrong");
    defer gpa.free(wrong_url);
    try std.testing.expectEqual(bytes.len, responses[1].body.len);
    try std.testing.expectError(error.IntegrityMismatch, client.download(.{ .url = wrong_url, .expected = expected }));
    try std.testing.expect(!fixture.store.hasBlob(object));
    try std.testing.expect(!fixture.store.hasBlob(digest.ofBlob(responses[1].body)));
    const overlong_url = try server.urlAlloc(gpa, "/overlong");
    defer gpa.free(overlong_url);
    try std.testing.expectError(error.LengthMismatch, client.download(.{ .url = overlong_url, .expected = expected }));
    try std.testing.expect(!fixture.store.hasBlob(object));
    try std.testing.expectEqual(@as(usize, 0), try fixture.store.recover());

    // A guessed partial filename, even with the right digest in its name,
    // grants no trust. Retries discard their own chunks and restart from zero.
    var partial_dir_buffer: [128]u8 = undefined;
    const partial_dir = try std.fmt.bufPrint(&partial_dir_buffer, "staging/{s}", .{std.fmt.bytesToHex(object.bytes, .lower)});
    var partial_data_buffer: [160]u8 = undefined;
    const partial_data = try std.fmt.bufPrint(&partial_data_buffer, "{s}/data", .{partial_dir});
    try fixture.store.dir.createDirPath(io, partial_dir);
    try fixture.store.dir.writeFile(io, .{ .sub_path = partial_data, .data = "attacker partial" });
    const retry_url = try server.urlAlloc(gpa, "/retry");
    defer gpa.free(retry_url);
    var received = try client.download(.{ .url = retry_url, .expected = expected, .retry = .{ .initial_delay_ms = 1, .max_delay_ms = 2 } });
    defer received.deinit();
    try std.testing.expectEqual(@as(u8, 3), received.attempts);
    try std.testing.expect(received.artifact.digest.eql(object));
    const stored = try fixture.store.readBlobAlloc(gpa, object);
    defer gpa.free(stored);
    try std.testing.expectEqualStrings(bytes, stored);
    try std.testing.expectEqual(@as(usize, 1), try fixture.store.recover());
    const interrupted_url = try server.urlAlloc(gpa, "/interrupt");
    defer gpa.free(interrupted_url);
    var recovered = try client.download(.{ .url = interrupted_url, .expected = expected, .retry = .{ .initial_delay_ms = 1 } });
    defer recovered.deinit();
    try std.testing.expectEqual(@as(u8, 2), recovered.attempts);
    const limited_url = try server.urlAlloc(gpa, "/limited");
    defer gpa.free(limited_url);
    try std.testing.expectError(error.RetryLimit, client.download(.{ .url = limited_url, .expected = expected, .retry = .{ .max_attempts = 2, .initial_delay_ms = 1 } }));
    const ok_url = try server.urlAlloc(gpa, "/ok");
    defer gpa.free(ok_url);
    var conditional = try client.download(.{ .url = ok_url, .expected = expected, .if_none_match = "\"artifact-v1\"" });
    defer conditional.deinit();
    try std.testing.expect(conditional.not_modified);
    try std.testing.expect(conditional.etag != null);
    try std.testing.expectEqualStrings("\"artifact-v1\"", conditional.etag.?);
    const chunked_url = try server.urlAlloc(gpa, "/chunked");
    defer gpa.free(chunked_url);
    var chunked = try client.download(.{ .url = chunked_url, .expected = expected });
    defer chunked.deinit();
    try std.testing.expect(chunked.artifact.digest.eql(object));
    try std.testing.expectError(error.DownloadTooLarge, client.download(.{ .url = ok_url, .expected = expected, .max_bytes = 1 }));
    const empty_url = try server.urlAlloc(gpa, "/empty");
    defer gpa.free(empty_url);
    var empty = try client.download(.{ .url = empty_url, .expected = .{ .digest = digest.ofBlob(""), .byte_length = 0 } });
    defer empty.deinit();
    try std.testing.expect(fixture.store.hasBlob(digest.ofBlob("")));
    var path_buffer: [128]u8 = undefined;
    // Preserve length so only a real byte/digest recheck can detect corruption.
    try fixture.store.dir.writeFile(io, .{ .sub_path = fixture.store.blobPath(object, &path_buffer), .data = responses[1].body });
    try std.testing.expectError(error.UnverifiedNotModified, client.download(.{ .url = ok_url, .expected = expected, .if_none_match = "\"artifact-v1\"" }));
    try std.testing.expectError(error.CorruptObject, client.download(.{ .url = ok_url, .expected = expected, .reuse_verified = true }));
}

test "m07/TRUST-011 protect authorization redirects" {
    std.debug.print("JCKG_EVIDENCE TRUST-011\n", .{});
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const bytes = "private artifact";
    const token = "Bearer ghp_0123456789abcdefghijklmnop";
    const payload = [_]FixtureResponse{.{ .body = bytes }};
    const other_routes = [_]FixtureRoute{.{ .path = "/artifact", .responses = &payload }};
    var other = try FixtureServer.init(io, gpa, &other_routes);
    defer other.deinit();
    try other.start();
    // Different host text, still exclusively loopback: no network dependency.
    const other_url = try gpa.print("http://localhost:{d}/artifact", .{other.port()});
    defer gpa.free(other_url);
    const same = [_]FixtureResponse{.{ .status = 302, .location = "/artifact" }};
    const cross = [_]FixtureResponse{.{ .status = 302, .location = other_url }};
    const loop = [_]FixtureResponse{.{ .status = 307, .location = "/loop" }};
    const leak = [_]FixtureResponse{.{ .status = 302, .location = "/artifact?token=ghp_0123456789abcdefghijklmnop" }};
    const routes = [_]FixtureRoute{
        .{ .path = "/artifact", .responses = &payload },
        .{ .path = "/same", .responses = &same },
        .{ .path = "/cross", .responses = &cross },
        .{ .path = "/loop", .responses = &loop },
        .{ .path = "/leak", .responses = &leak },
    };
    var server = try FixtureServer.init(io, gpa, &routes);
    defer server.deinit();
    try server.start();
    const fixture = try testStore(io, gpa, "trust011");
    defer cleanupTestStore(io, gpa, fixture);
    var client = Client.init(io, gpa, fixture.store);
    defer client.deinit();
    const expected = Artifact{ .digest = digest.ofBlob(bytes), .byte_length = bytes.len };
    const same_url = try server.urlAlloc(gpa, "/same");
    defer gpa.free(same_url);
    var result = try client.download(.{ .url = same_url, .expected = expected, .authorization = token });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), server.snapshot().authorized_requests);
    const cross_url = try server.urlAlloc(gpa, "/cross");
    defer gpa.free(cross_url);
    try std.testing.expectError(error.AuthRedirectRefused, client.download(.{ .url = cross_url, .expected = expected, .authorization = token }));
    try std.testing.expectEqual(@as(usize, 0), other.snapshot().requests);
    var public_result = try client.download(.{ .url = cross_url, .expected = expected });
    defer public_result.deinit();
    try std.testing.expectEqual(@as(usize, 1), other.snapshot().requests);
    try std.testing.expectEqual(@as(usize, 0), other.snapshot().authorized_requests);
    const leak_url = try server.urlAlloc(gpa, "/leak");
    defer gpa.free(leak_url);
    try std.testing.expectError(error.CredentialsInUrl, client.download(.{ .url = leak_url, .expected = expected, .authorization = token }));
    const private_urls = [_][]const u8{
        "http://user:secret@127.0.0.1/artifact",
        "http://127.0.0.1/artifact?token=private",
        "http://127.0.0.1/artifact?access_%74oken=private",
        "http://127.0.0.1/ghp_0123456789abcdefghijklmnop",
        "http://127.0.0.1/ghp_%300123456789abcdefghijklmnop",
    };
    const before = server.snapshot().requests;
    for (private_urls) |url| try std.testing.expectError(error.CredentialsInUrl, client.download(.{ .url = url, .expected = expected, .authorization = token }));
    const opaque_url = try server.urlAlloc(gpa, "/OPAQUE-private-credential-12345");
    defer gpa.free(opaque_url);
    const opaque_headers = [_][]const u8{
        "Bearer OPAQUE-private-credential-12345",
        "Bearer   OPAQUE-private-credential-12345",
        "  Bearer   OPAQUE-private-credential-12345  ",
    };
    for (opaque_headers) |header| try std.testing.expectError(error.CredentialsInUrl, client.download(.{ .url = opaque_url, .expected = expected, .authorization = header }));
    try std.testing.expectEqual(before, server.snapshot().requests);
    try std.testing.expectEqual(@as(usize, 0), server.snapshot().credential_url_requests);
    try std.testing.expectError(error.InvalidHeader, client.download(.{ .url = same_url, .expected = expected, .authorization = "Bearer secret\r\nInjected: yes" }));
    const loop_url = try server.urlAlloc(gpa, "/loop");
    defer gpa.free(loop_url);
    try std.testing.expectError(error.RedirectLimit, client.download(.{ .url = loop_url, .expected = expected, .max_redirects = 2 }));
    try std.testing.expect(!try sameOrigin(try std.Uri.parse("https://example.com/a"), try std.Uri.parse("https://sub.example.com/a")));
    try std.testing.expect(!try sameOrigin(try std.Uri.parse("https://example.com/a"), try std.Uri.parse("https://example.com:444/a")));
    try std.testing.expect(try sameOrigin(try std.Uri.parse("https://EXAMPLE.com/a"), try std.Uri.parse("https://example.com:443/a")));
    // Safe public diagnostics are fixed error names; any caller displaying a
    // separate URL must use the shared second-line redactor.
    const diagnostic = try redact.redactUrlAlloc(gpa, "http://user:ghp_0123456789abcdefghijklmnop@127.0.0.1/artifact");
    defer gpa.free(diagnostic);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, token[7..]) == null);
    try std.testing.expect(std.mem.indexOf(u8, @errorName(error.AuthRedirectRefused), token[7..]) == null);
}

test "m07/TRUST-012 resist computation cache poisoning" {
    std.debug.print("JCKG_EVIDENCE TRUST-012\n", .{});
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const fixture = try testStore(io, gpa, "trust012");
    defer cleanupTestStore(io, gpa, fixture);
    var cache = cache_module.Cache.init(gpa);
    defer cache.deinit();
    const bytes = "release computation result";
    const artifact = digest.ofBlob(bytes);
    const action = digest.ofCanonicalBytes(.action, "guessed action");
    var action_buffer: [digest.Digest.text_length]u8 = undefined;
    var artifact_buffer: [digest.Digest.text_length]u8 = undefined;
    const pair = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(0x71));
    const public = keys.PublicKey{ .bytes = pair.public_key.toBytes() };
    const ring_entries = [_]keys.RingEntry{.{ .id = public.id(), .key = public, .roles = &.{.targets} }};
    const request = CacheRequest{
        .action_digest = action,
        .requirements = .{ .policy = .release, .require_reproducible = true, .require_backend = "strict-linux" },
        .authorities = .{ .entries = &ring_entries },
    };
    var claim = CacheClaim{
        .entry = .{
            .action_digest = action.text(&action_buffer),
            .artifact_digest = artifact.text(&artifact_buffer),
            .policy = .release,
            .backend_identity = "strict-linux",
            .reproducible = true,
        },
        .byte_length = bytes.len,
    };
    // Merely guessing the action and claiming every required policy field
    // does not authorize a release cache entry, even with correct blob bytes.
    try std.testing.expectError(error.ProvenanceRequired, importCacheClaim(fixture.store, &cache, request, claim, bytes));
    try std.testing.expectEqual(@as(usize, 0), cache.count());
    try std.testing.expect(!fixture.store.hasBlob(artifact));
    _ = try fixture.store.importBytes(bytes, artifact);
    try std.testing.expectError(error.ProvenanceRequired, useCacheClaim(fixture.store, request, claim));
    try std.testing.expect(cache.lookup(claim.entry.action_digest, request.requirements) == .miss);

    // A development import proves bytes, not the requested release provenance.
    var development = claim;
    development.entry.policy = .development;
    development.entry.reproducible = false;
    const dev_request = CacheRequest{ .action_digest = action, .requirements = .{ .policy = .development } };
    try std.testing.expectEqual(cache_module.RecordOutcome.inserted, try importCacheClaim(fixture.store, &cache, dev_request, development, bytes));
    try std.testing.expect(cache.lookup(claim.entry.action_digest, request.requirements) == .incompatible);
    try std.testing.expectError(error.ProvenanceIncompatible, useCacheClaim(fixture.store, request, development));

    // An untrusted worker cannot enroll its own signing key in the caller ring.
    const attacker = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(0x72));
    const attacker_public = keys.PublicKey{ .bytes = attacker.public_key.toBytes() };
    const transcript = try provenanceBytes(gpa, claim);
    defer gpa.free(transcript);
    var signatures = [_]keys.SignatureEntry{.{ .key_id = attacker_public.id(), .signature = (try attacker.sign(transcript, null)).toBytes() }};
    claim.signatures = &signatures;
    try std.testing.expectError(error.UnknownKey, importCacheClaim(fixture.store, &cache, request, claim, bytes));
    signatures[0] = .{ .key_id = public.id(), .signature = (try pair.sign(transcript, null)).toBytes() };
    const wrong = "poisoned computation bytes";
    try std.testing.expectEqual(bytes.len, wrong.len);
    try std.testing.expectError(error.IntegrityMismatch, importCacheClaim(fixture.store, &cache, request, claim, wrong));
    try std.testing.expect(!fixture.store.hasBlob(digest.ofBlob(wrong)));
    // Canonical provenance binds backend, action, reproduction and all outputs.
    var changed = claim;
    changed.entry.backend_identity = "forged-backend";
    try std.testing.expectError(error.InvalidSignature, useCacheClaim(fixture.store, .{ .action_digest = action, .requirements = .{ .policy = .release }, .authorities = request.authorities }, changed));
    changed = claim;
    changed.entry.reproducible = false;
    try std.testing.expectError(error.ProvenanceIncompatible, useCacheClaim(fixture.store, request, changed));
    changed = claim;
    const different_action = digest.ofCanonicalBytes(.action, "different computation");
    try std.testing.expectError(error.ActionMismatch, useCacheClaim(fixture.store, .{ .action_digest = different_action, .requirements = request.requirements, .authorities = request.authorities }, changed));
    changed = claim;
    changed.byte_length += 1;
    try std.testing.expectError(error.InvalidSignature, useCacheClaim(fixture.store, request, changed));

    // A genuine release computation claim for the already-imported exact bytes
    // adds provenance, rather than being hidden by the earlier development hit.
    try std.testing.expectEqual(cache_module.RecordOutcome.provenance_added, try importCacheClaim(fixture.store, &cache, request, claim, bytes));
    try std.testing.expectEqual(@as(usize, 2), cache.count());
    const release_hit = cache.lookup(claim.entry.action_digest, request.requirements);
    try std.testing.expect(release_hit == .hit);
    try std.testing.expectEqual(@as(usize, 1), release_hit.hit);
    const development_hit = cache.lookup(claim.entry.action_digest, dev_request.requirements);
    try std.testing.expect(development_hit == .hit);
    try std.testing.expectEqual(@as(usize, 0), development_hit.hit);
    try std.testing.expectEqual(cache_module.RecordOutcome.converged, try importCacheClaim(fixture.store, &cache, request, claim, bytes));
    try std.testing.expect((try useCacheClaim(fixture.store, request, claim)).eql(artifact));
    var path_buffer: [128]u8 = undefined;
    // Same-length corruption defeats a size-only cache-hit check.
    try fixture.store.dir.writeFile(io, .{ .sub_path = fixture.store.blobPath(artifact, &path_buffer), .data = wrong });
    try std.testing.expectError(error.CorruptObject, useCacheClaim(fixture.store, request, claim));
}

/// Tests read real loopback replies without publishing them. Production callers
/// likewise hand collect bytes received into memory/private staging, never a
/// worker-selected trusted Store path.
fn readFixtureBytes(client: *Client, url: []const u8) ![]u8 {
    var request = try client.http.request(.GET, try std.Uri.parse(url), .{
        .redirect_behavior = .not_allowed,
        .keep_alive = false,
        .headers = .{ .authorization = .omit, .accept_encoding = .{ .override = "identity" } },
    });
    defer request.deinit();
    try request.sendBodiless();
    var response = try request.receiveHead(&.{});
    if (response.head.status != .ok) return error.UnexpectedStatus;
    var transfer_buffer: [8192]u8 = undefined;
    const body = response.reader(&transfer_buffer);
    var bytes: [4097]u8 = undefined;
    const count = try body.readSliceShort(&bytes);
    if (count > 4096) return error.DownloadTooLarge;
    return client.http.allocator.dupe(u8, bytes[0..count]);
}

fn expectNoResultCommit(store: store_module.Store, cache: cache_module.Cache, objects: []const digest.Digest) !void {
    try std.testing.expectEqual(@as(usize, 0), cache.count());
    for (objects) |object| try std.testing.expect(!store.hasBlob(object));
}

test "m08/STRICT-007 verify returned artifacts before commitment" {
    std.debug.print("JCKG_EVIDENCE STRICT-007\n", .{});
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const first = "first returned output";
    const second = "second returned data";
    const corrupt_second = "second poisoned data";
    const unexpected = "undeclared but hash-correct";
    try std.testing.expectEqual(second.len, corrupt_second.len);
    const first_digest = digest.ofBlob(first);
    const second_digest = digest.ofBlob(second);
    const unexpected_digest = digest.ofBlob(unexpected);
    const action = digest.ofCanonicalBytes(.action, "{\"kind\":\"strict-output-collection\"}");
    var action_buffer: [digest.Digest.text_length]u8 = undefined;
    var first_buffer: [digest.Digest.text_length]u8 = undefined;
    var second_buffer: [digest.Digest.text_length]u8 = undefined;
    var unexpected_buffer: [digest.Digest.text_length]u8 = undefined;
    const declarations = [_][]const u8{ "first", "second" };
    var collector = try ResultCollector.init(action, &declarations, .{});
    try collector.reconcile(.{ .action_digest = action, .state = .completed });
    const output_records = [_]cache_module.OutputRecord{
        .{ .name = "first", .digest = first_digest.text(&first_buffer) },
        .{ .name = "second", .digest = second_digest.text(&second_buffer) },
    };
    const claim = CacheClaim{
        .entry = .{
            .action_digest = action.text(&action_buffer),
            .artifact_digest = output_records[0].digest,
            .policy = .development,
            .backend_identity = "authenticated-remote-worker",
            .outputs = &output_records,
        },
        .byte_length = first.len,
    };
    const request = CacheRequest{ .action_digest = action, .requirements = .{ .policy = .development } };
    const first_response = [_]FixtureResponse{.{ .body = first }};
    const second_responses = [_]FixtureResponse{ .{ .body = corrupt_second }, .{ .body = second } };
    const unexpected_response = [_]FixtureResponse{.{ .body = unexpected }};
    const routes = [_]FixtureRoute{
        .{ .path = "/first", .responses = &first_response },
        .{ .path = "/second", .responses = &second_responses },
        .{ .path = "/undeclared", .responses = &unexpected_response },
    };
    var server = try FixtureServer.init(io, gpa, &routes);
    defer server.deinit();
    try server.start();
    const fixture = try testStore(io, gpa, "strict007");
    defer cleanupTestStore(io, gpa, fixture);
    var client = Client.init(io, gpa, fixture.store);
    defer client.deinit();
    var cache = cache_module.Cache.init(gpa);
    defer cache.deinit();
    const first_url = try server.urlAlloc(gpa, "/first");
    defer gpa.free(first_url);
    const second_url = try server.urlAlloc(gpa, "/second");
    defer gpa.free(second_url);
    const unexpected_url = try server.urlAlloc(gpa, "/undeclared");
    defer gpa.free(unexpected_url);
    const received_first = try readFixtureBytes(&client, first_url);
    defer gpa.free(received_first);
    const received_corrupt = try readFixtureBytes(&client, second_url);
    defer gpa.free(received_corrupt);
    const received_unexpected = try readFixtureBytes(&client, unexpected_url);
    defer gpa.free(received_unexpected);
    const corrupt_batch = [_]ReturnedArtifact{
        .{ .name = "first", .bytes = received_first },
        .{ .name = "second", .bytes = received_corrupt },
    };
    // An earlier good output must not be committed while a later one is bad.
    try std.testing.expectError(error.IntegrityMismatch, collector.collect(fixture.store, &cache, request, claim, &corrupt_batch, received_first));
    try expectNoResultCommit(fixture.store, cache, &.{ first_digest, second_digest, digest.ofBlob(corrupt_second) });
    try std.testing.expect(!collector.succeeded());

    // Keep the count unchanged and the bytes/digests correct. Only the
    // receiver's declared set distinguishes this forged output claim.
    const forged_records = [_]cache_module.OutputRecord{
        output_records[0],
        .{ .name = "undeclared", .digest = unexpected_digest.text(&unexpected_buffer) },
    };
    var forged_claim = claim;
    forged_claim.entry.outputs = &forged_records;
    const undeclared_batch = [_]ReturnedArtifact{
        corrupt_batch[0],
        .{ .name = "undeclared", .bytes = received_unexpected },
    };
    try std.testing.expectError(error.UndeclaredOutput, collector.collect(fixture.store, &cache, request, forged_claim, &undeclared_batch, received_first));
    try expectNoResultCommit(fixture.store, cache, &.{ first_digest, second_digest, unexpected_digest });
    try std.testing.expect(!collector.succeeded());
    try std.testing.expectError(error.MissingOutput, collector.collect(fixture.store, &cache, request, claim, corrupt_batch[0..1], received_first));
    const duplicate_batch = [_]ReturnedArtifact{ corrupt_batch[0], corrupt_batch[0] };
    try std.testing.expectError(error.DuplicateOutput, collector.collect(fixture.store, &cache, request, claim, &duplicate_batch, received_first));
    try expectNoResultCommit(fixture.store, cache, &.{ first_digest, second_digest });
    try std.testing.expectEqual(@as(usize, 0), try fixture.store.recover());

    const received_second = try readFixtureBytes(&client, second_url);
    defer gpa.free(received_second);
    const valid_batch = [_]ReturnedArtifact{
        corrupt_batch[0],
        .{ .name = "second", .bytes = received_second },
    };
    try std.testing.expectEqual(cache_module.RecordOutcome.inserted, try collector.collect(fixture.store, &cache, request, claim, &valid_batch, received_first));
    try std.testing.expect(collector.succeeded());
    try std.testing.expect(fixture.store.hasBlob(first_digest));
    try std.testing.expect(fixture.store.hasBlob(second_digest));
    try std.testing.expectEqual(@as(usize, 1), cache.count());
    try std.testing.expect(cache.lookup(claim.entry.action_digest, request.requirements) == .hit);
}

test "m08/STRICT-008 reconcile interrupted actions and verify resumed data" {
    std.debug.print("JCKG_EVIDENCE STRICT-008\n", .{});
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const full_bytes = "resumed remote artifact bytes\n";
    const prefix = full_bytes[0..8];
    const artifact = Artifact{ .digest = digest.ofBlob(full_bytes), .byte_length = full_bytes.len };
    const checkpoint = Artifact{ .digest = digest.ofBlob(prefix), .byte_length = prefix.len };
    const action = digest.ofCanonicalBytes(.action, "{\"kind\":\"strict-interrupted-action\"}");
    const wrong_action = digest.ofCanonicalBytes(.action, "{\"kind\":\"different-action\"}");
    var action_buffer: [digest.Digest.text_length]u8 = undefined;
    var wrong_action_buffer: [digest.Digest.text_length]u8 = undefined;
    var artifact_buffer: [digest.Digest.text_length]u8 = undefined;
    const action_text = action.text(&action_buffer);
    const unknown_report = try gpa.print("{{\"actionDigest\":\"{s}\",\"state\":\"unknown\"}}", .{action_text});
    defer gpa.free(unknown_report);
    const running_report = try gpa.print("{{\"actionDigest\":\"{s}\",\"state\":\"running\"}}", .{action_text});
    defer gpa.free(running_report);
    const completed_report = try gpa.print("{{\"actionDigest\":\"{s}\",\"state\":\"completed\"}}", .{action_text});
    defer gpa.free(completed_report);
    const different_report = try gpa.print("{{\"actionDigest\":\"{s}\",\"state\":\"completed\"}}", .{wrong_action.text(&wrong_action_buffer)});
    defer gpa.free(different_report);
    const transfer = [_]FixtureResponse{
        .{ .body = prefix, .declared_length = full_bytes.len },
        .{ .body = full_bytes },
    };
    const status_responses = [_]FixtureResponse{
        .{ .body = unknown_report },
        .{ .body = running_report },
        .{ .body = completed_report },
    };
    const different_response = [_]FixtureResponse{.{ .body = different_report }};
    const routes = [_]FixtureRoute{
        .{ .path = "/transfer", .responses = &transfer },
        .{ .path = "/reconcile", .responses = &status_responses },
        .{ .path = "/different-action", .responses = &different_response },
    };
    var server = try FixtureServer.init(io, gpa, &routes);
    defer server.deinit();
    try server.start();
    const fixture = try testStore(io, gpa, "strict008");
    defer cleanupTestStore(io, gpa, fixture);
    var client = Client.init(io, gpa, fixture.store);
    defer client.deinit();
    var cache = cache_module.Cache.init(gpa);
    defer cache.deinit();
    const declarations = [_][]const u8{"out"};
    var collector = try ResultCollector.init(action, &declarations, .{});
    const records = [_]cache_module.OutputRecord{.{ .name = "out", .digest = artifact.digest.text(&artifact_buffer) }};
    const claim = CacheClaim{
        .entry = .{
            .action_digest = action_text,
            .artifact_digest = records[0].digest,
            .policy = .development,
            .backend_identity = "authenticated-remote-worker",
            .outputs = &records,
        },
        .byte_length = full_bytes.len,
    };
    const request = CacheRequest{ .action_digest = action, .requirements = .{ .policy = .development } };
    const transfer_url = try server.urlAlloc(gpa, "/transfer");
    defer gpa.free(transfer_url);
    const status_url = try server.urlAlloc(gpa, "/reconcile");
    defer gpa.free(status_url);
    const different_url = try server.urlAlloc(gpa, "/different-action");
    defer gpa.free(different_url);
    var partial_path_buffer: [128]u8 = undefined;
    const partial_path = try std.fmt.bufPrint(&partial_path_buffer, "staging/{s}", .{std.fmt.bytesToHex(artifact.digest.bytes, .lower)});
    try fixture.store.dir.writeFile(io, .{ .sub_path = partial_path, .data = prefix });
    try std.testing.expectError(error.TruncatedBody, client.download(.{ .url = transfer_url, .expected = artifact, .retry = .{ .max_attempts = 1 } }));
    collector.interrupted();
    // Disconnect cannot guess success, even if a plausible result is supplied.
    try std.testing.expect(!collector.succeeded());
    const plausible = [_]ReturnedArtifact{.{ .name = "out", .bytes = full_bytes }};
    try std.testing.expectError(error.ActionNotReconciled, collector.collect(fixture.store, &cache, request, claim, &plausible, full_bytes));
    try std.testing.expectError(error.ActionNotReconciled, collector.verifyResumedFile(io, fixture.store.dir, partial_path, checkpoint));
    try expectNoResultCommit(fixture.store, cache, &.{artifact.digest});
    try std.testing.expectError(error.InvalidReconciliation, collector.reconcileBytes(gpa, "{}"));

    // Each control-plane reply comes over a new real loopback connection.
    const unknown = try readFixtureBytes(&client, status_url);
    defer gpa.free(unknown);
    try collector.reconcileBytes(gpa, unknown);
    try std.testing.expect(!collector.succeeded());
    try std.testing.expectError(error.ActionNotReconciled, collector.collect(fixture.store, &cache, request, claim, &plausible, full_bytes));
    const different = try readFixtureBytes(&client, different_url);
    defer gpa.free(different);
    try std.testing.expectError(error.ActionMismatch, collector.reconcileBytes(gpa, different));
    const running = try readFixtureBytes(&client, status_url);
    defer gpa.free(running);
    try collector.reconcileBytes(gpa, running);
    try std.testing.expect(!collector.succeeded());
    try std.testing.expectError(error.ActionNotReconciled, collector.verifyResumedFile(io, fixture.store.dir, partial_path, checkpoint));
    const completed = try readFixtureBytes(&client, status_url);
    defer gpa.free(completed);
    try collector.reconcileBytes(gpa, completed);
    try std.testing.expect(!collector.succeeded());

    // A digest-shaped filename and unchanged size cannot validate a checkpoint.
    var poisoned_prefix: [prefix.len]u8 = undefined;
    @memcpy(&poisoned_prefix, prefix);
    poisoned_prefix[0] ^= 1;
    try fixture.store.dir.writeFile(io, .{ .sub_path = partial_path, .data = &poisoned_prefix });
    try std.testing.expectError(error.CorruptObject, collector.verifyResumedFile(io, fixture.store.dir, partial_path, checkpoint));
    try std.testing.expect(!collector.succeeded());
    try expectNoResultCommit(fixture.store, cache, &.{artifact.digest});
    try fixture.store.dir.writeFile(io, .{ .sub_path = partial_path, .data = prefix });
    try collector.verifyResumedFile(io, fixture.store.dir, partial_path, checkpoint);

    const resumed_bytes = try readFixtureBytes(&client, transfer_url);
    defer gpa.free(resumed_bytes);
    const saved_chunk = try fixture.store.dir.readFileAlloc(io, partial_path, gpa, .limited(64));
    defer gpa.free(saved_chunk);
    try std.testing.expectEqual(prefix.len, saved_chunk.len);
    try std.testing.expectEqual(full_bytes.len, resumed_bytes.len);
    @memcpy(resumed_bytes[0..saved_chunk.len], saved_chunk);
    const resumed = [_]ReturnedArtifact{.{ .name = "out", .bytes = resumed_bytes }};
    // Correct reused chunks still do not exempt the whole output from hashing.
    resumed_bytes[resumed_bytes.len - 1] ^= 1;
    try std.testing.expectError(error.IntegrityMismatch, collector.collect(fixture.store, &cache, request, claim, &resumed, resumed_bytes));
    try std.testing.expect(!collector.succeeded());
    try expectNoResultCommit(fixture.store, cache, &.{artifact.digest});
    resumed_bytes[resumed_bytes.len - 1] ^= 1;
    try std.testing.expectEqual(cache_module.RecordOutcome.inserted, try collector.collect(fixture.store, &cache, request, claim, &resumed, resumed_bytes));
    try std.testing.expect(collector.succeeded());
    try std.testing.expectEqual(@as(usize, 1), cache.count());
    const stored = try fixture.store.readBlobAlloc(gpa, artifact.digest);
    defer gpa.free(stored);
    try std.testing.expectEqualStrings(full_bytes, stored);
    try std.testing.expectError(error.ActionAlreadyVerified, collector.reconcile(.{ .action_digest = action, .state = .completed }));
}
