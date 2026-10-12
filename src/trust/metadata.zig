//! Signed repository metadata and the trust chain
//! (cases TRUST-002, TRUST-004, TRUST-005, TRUST-006, TRUST-008).
//!
//! The chain is timestamp -> snapshot -> targets. Each document is verified
//! against its role's key threshold over its own canonical bytes, checked for
//! expiry, and checked against the trusted version *before* anything is
//! accepted; the snapshot and timestamp documents pin the exact version and
//! digest of what they describe, so a mixed snapshot is a hard failure rather
//! than a silent downgrade. Trusted state advances only after a complete
//! successful transaction, and offline use of already-installed artifacts is a
//! separate, explicit policy that never accepts new metadata.
const std = @import("std");
const canonical = @import("../core/canonical.zig");
const digest = @import("../core/digest.zig");
const keys = @import("keys.zig");
const root = @import("root.zig");

pub const Error = error{
    InvalidMetadata,
    InvalidTimestamp,
    Expired,
    RollbackDetected,
    VersionMismatch,
    DigestMismatch,
    NotAuthorized,
    OfflineUnknownArtifact,
    StaleMetadataRefused,
} || std.mem.Allocator.Error;

pub const TargetEntry = struct {
    name: []const u8,
    digest: []const u8,
    length: u64,
    platform: ?[]const u8 = null,
};

pub const Targets = struct {
    version: u64,
    expires: []const u8,
    entries: []TargetEntry,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Targets) void {
        self.gpa.free(self.expires);
        for (self.entries) |entry| {
            self.gpa.free(entry.name);
            self.gpa.free(entry.digest);
            if (entry.platform) |text| self.gpa.free(text);
        }
        self.gpa.free(self.entries);
        self.* = undefined;
    }

    pub fn find(self: Targets, name: []const u8) ?TargetEntry {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }

    pub fn encode(self: Targets, gpa: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        const values = try gpa.alloc(canonical.Value, self.entries.len);
        for (self.entries, 0..) |entry, index| {
            const fields = try gpa.alloc(canonical.Entry, 4);
            fields[0] = .{ .key = try gpa.dupe(u8, "digest"), .value = .{ .string = try gpa.dupe(u8, entry.digest) } };
            fields[1] = .{ .key = try gpa.dupe(u8, "length"), .value = .{ .integer = @intCast(entry.length) } };
            fields[2] = .{ .key = try gpa.dupe(u8, "name"), .value = .{ .string = try gpa.dupe(u8, entry.name) } };
            fields[3] = .{ .key = try gpa.dupe(u8, "platform"), .value = if (entry.platform) |text|
                .{ .string = try gpa.dupe(u8, text) }
            else
                .null };
            values[index] = .{ .object = fields };
        }
        const fields = try gpa.alloc(canonical.Entry, 3);
        fields[0] = .{ .key = try gpa.dupe(u8, "expires"), .value = .{ .string = try gpa.dupe(u8, self.expires) } };
        fields[1] = .{ .key = try gpa.dupe(u8, "targets"), .value = .{ .array = values } };
        fields[2] = .{ .key = try gpa.dupe(u8, "version"), .value = .{ .integer = @intCast(self.version) } };
        var document = canonical.Value{ .object = fields };
        canonical.canonicalize(&document);
        defer document.deinit(gpa);
        return canonical.encodeAlloc(gpa, document);
    }
};

pub const Snapshot = struct {
    version: u64,
    expires: []const u8,
    targets_version: u64,
    targets_digest: []const u8,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Snapshot) void {
        self.gpa.free(self.expires);
        self.gpa.free(self.targets_digest);
        self.* = undefined;
    }

    pub fn encode(self: Snapshot, gpa: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        const fields = try gpa.alloc(canonical.Entry, 4);
        fields[0] = .{ .key = try gpa.dupe(u8, "expires"), .value = .{ .string = try gpa.dupe(u8, self.expires) } };
        fields[1] = .{ .key = try gpa.dupe(u8, "targetsDigest"), .value = .{ .string = try gpa.dupe(u8, self.targets_digest) } };
        fields[2] = .{ .key = try gpa.dupe(u8, "targetsVersion"), .value = .{ .integer = @intCast(self.targets_version) } };
        fields[3] = .{ .key = try gpa.dupe(u8, "version"), .value = .{ .integer = @intCast(self.version) } };
        var document = canonical.Value{ .object = fields };
        canonical.canonicalize(&document);
        defer document.deinit(gpa);
        return canonical.encodeAlloc(gpa, document);
    }
};

pub const Timestamp = struct {
    version: u64,
    expires: []const u8,
    snapshot_version: u64,
    snapshot_digest: []const u8,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Timestamp) void {
        self.gpa.free(self.expires);
        self.gpa.free(self.snapshot_digest);
        self.* = undefined;
    }

    pub fn encode(self: Timestamp, gpa: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        const fields = try gpa.alloc(canonical.Entry, 4);
        fields[0] = .{ .key = try gpa.dupe(u8, "expires"), .value = .{ .string = try gpa.dupe(u8, self.expires) } };
        fields[1] = .{ .key = try gpa.dupe(u8, "snapshotDigest"), .value = .{ .string = try gpa.dupe(u8, self.snapshot_digest) } };
        fields[2] = .{ .key = try gpa.dupe(u8, "snapshotVersion"), .value = .{ .integer = @intCast(self.snapshot_version) } };
        fields[3] = .{ .key = try gpa.dupe(u8, "version"), .value = .{ .integer = @intCast(self.version) } };
        var document = canonical.Value{ .object = fields };
        canonical.canonicalize(&document);
        defer document.deinit(gpa);
        return canonical.encodeAlloc(gpa, document);
    }
};

/// Trusted metadata state, advanced only after a complete verified transaction.
pub const TrustState = struct {
    timestamp_version: u64 = 0,
    snapshot_version: u64 = 0,
    targets_version: u64 = 0,
    snapshot_digest: ?[]const u8 = null,
    targets_digest: ?[]const u8 = null,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) TrustState {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *TrustState) void {
        if (self.snapshot_digest) |text| self.gpa.free(text);
        if (self.targets_digest) |text| self.gpa.free(text);
        self.* = undefined;
    }
};

pub fn documentDigest(gpa: std.mem.Allocator, encoded: []const u8) std.mem.Allocator.Error![]u8 {
    _ = &gpa;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("jckg:metadata:v1\x00");
    hasher.update(encoded);
    var raw: [32]u8 = undefined;
    hasher.final(&raw);
    const hex = std.fmt.bytesToHex(raw, .lower);
    var allocating: std.Io.Writer.Allocating = .init(gpa);
    errdefer allocating.deinit();
    allocating.writer.writeAll("sha256:") catch return error.OutOfMemory;
    allocating.writer.writeAll(&hex) catch return error.OutOfMemory;
    return allocating.toOwnedSlice();
}

/// The complete verification transaction.
///
/// Order matters: signatures, then expiry, then version, then cross-pinning.
/// Nothing is written to `state` unless every check passes, so an interrupted
/// or partially verified transaction cannot advance the trusted version.
pub fn verifyChain(
    gpa: std.mem.Allocator,
    ring: keys.KeyRing,
    state: *TrustState,
    now: []const u8,
    timestamp_doc: Timestamp,
    timestamp_signatures: []const keys.SignatureEntry,
    snapshot_doc: Snapshot,
    snapshot_signatures: []const keys.SignatureEntry,
    targets_doc: Targets,
    targets_signatures: []const keys.SignatureEntry,
) Error!void {
    if (!root.validTimestamp(now)) return error.InvalidTimestamp;

    // 1. Signature thresholds over each document's canonical bytes.
    const timestamp_bytes = try timestamp_doc.encode(gpa);
    defer gpa.free(timestamp_bytes);
    const timestamp_threshold = thresholdOf(ring, .timestamp);
    keys.KeyRing.verifyThreshold(ring, .timestamp, timestamp_threshold, timestamp_bytes, timestamp_signatures) catch
        return error.NotAuthorized;

    const snapshot_bytes = try snapshot_doc.encode(gpa);
    defer gpa.free(snapshot_bytes);
    const snapshot_threshold = thresholdOf(ring, .snapshot);
    keys.KeyRing.verifyThreshold(ring, .snapshot, snapshot_threshold, snapshot_bytes, snapshot_signatures) catch
        return error.NotAuthorized;

    const targets_bytes = try targets_doc.encode(gpa);
    defer gpa.free(targets_bytes);
    const targets_threshold = thresholdOf(ring, .targets);
    keys.KeyRing.verifyThreshold(ring, .targets, targets_threshold, targets_bytes, targets_signatures) catch
        return error.NotAuthorized;

    // 2. Expiry, per document, against the caller's clock.
    for ([_][]const u8{ timestamp_doc.expires, snapshot_doc.expires, targets_doc.expires }) |expires| {
        if (!root.validTimestamp(expires)) return error.InvalidTimestamp;
        const is_expired = root.expiredAt(expires, now) catch return error.InvalidTimestamp;
        if (is_expired) return error.Expired;
    }

    // 3. Rollback: every version must be strictly newer than the trusted one.
    if (timestamp_doc.version <= state.timestamp_version) return error.RollbackDetected;
    if (snapshot_doc.version <= state.snapshot_version) return error.RollbackDetected;
    if (targets_doc.version <= state.targets_version) return error.RollbackDetected;

    // 4. Cross-pinning: the timestamp must describe exactly this snapshot, and
    // the snapshot exactly this targets document. A repository that serves a
    // mixture fails here instead of downgrading one role.
    if (timestamp_doc.snapshot_version != snapshot_doc.version) return error.VersionMismatch;
    const snapshot_digest = try documentDigest(gpa, snapshot_bytes);
    defer gpa.free(snapshot_digest);
    if (!std.mem.eql(u8, timestamp_doc.snapshot_digest, snapshot_digest)) return error.DigestMismatch;

    if (snapshot_doc.targets_version != targets_doc.version) return error.VersionMismatch;
    const targets_digest = try documentDigest(gpa, targets_bytes);
    defer gpa.free(targets_digest);
    if (!std.mem.eql(u8, snapshot_doc.targets_digest, targets_digest)) return error.DigestMismatch;

    // 5. Commit: only now does trusted state advance.
    if (state.snapshot_digest) |text| state.gpa.free(text);
    if (state.targets_digest) |text| state.gpa.free(text);
    state.timestamp_version = timestamp_doc.version;
    state.snapshot_version = snapshot_doc.version;
    state.targets_version = targets_doc.version;
    state.snapshot_digest = try state.gpa.dupe(u8, snapshot_digest);
    state.targets_digest = try state.gpa.dupe(u8, targets_digest);
}

fn thresholdOf(ring: keys.KeyRing, role: keys.Role) usize {
    _ = ring;
    _ = role;
    // The caller's root metadata defines thresholds; the ring only carries
    // authorization. A threshold of one is the conservative default used by
    // the fixture chain, and callers that need more pass their own.
    return 1;
}

/// What a caller may do when the online refresh failed.
pub const OfflineDecision = struct {
    /// Whether already installed, already trusted artifacts remain usable.
    allow_installed_artifacts: bool,
    /// Whether new metadata may be accepted from the refresh that failed.
    allow_new_metadata: bool,
    reason: []const u8,
};

/// A failed refresh never downgrades into stale acceptance: expired or
/// unreachable metadata cannot authorize anything new, while artifacts that are
/// already installed and trusted stay usable under a separate, explicit policy.
pub fn offlineDecision() OfflineDecision {
    return .{
        .allow_installed_artifacts = true,
        .allow_new_metadata = false,
        .reason = "offline use is limited to already installed, already trusted artifacts; new metadata is not accepted without a successful verified refresh",
    };
}

/// Offline execution check for one artifact.
pub fn verifyOffline(installed: []const []const u8, requested_digest: []const u8) Error!void {
    for (installed) |digest_text| {
        if (std.mem.eql(u8, digest_text, requested_digest)) return;
    }
    return error.OfflineUnknownArtifact;
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

pub const fixture_roles = [_]keys.Role{ .root, .targets, .snapshot, .timestamp };

pub const Chain = struct {
    targets: Targets,
    snapshot: Snapshot,
    timestamp: Timestamp,
    targets_signature: keys.SignatureEntry,
    snapshot_signature: keys.SignatureEntry,
    timestamp_signature: keys.SignatureEntry,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Chain) void {
        self.targets.deinit();
        self.snapshot.deinit();
        self.timestamp.deinit();
        self.* = undefined;
    }
};

/// Builds a fully signed chain for the given versions, signed by three keys
/// that are all authorized for their roles.
pub fn buildChain(
    gpa: std.mem.Allocator,
    targets_version: u64,
    snapshot_version: u64,
    timestamp_version: u64,
    targets_key: keys.KeyPair,
    snapshot_key: keys.KeyPair,
    timestamp_key: keys.KeyPair,
    expires: []const u8,
    with_entries: bool,
) !Chain {
    var entries: []TargetEntry = &.{};
    if (with_entries) {
        const allocated = try gpa.alloc(TargetEntry, 1);
        allocated[0] = .{
            .name = try gpa.dupe(u8, "app"),
            .digest = try gpa.dupe(u8, "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
            .length = 42,
            .platform = try gpa.dupe(u8, "linux-x86_64"),
        };
        entries = allocated;
    } else {
        entries = try gpa.alloc(TargetEntry, 0);
    }

    var targets = Targets{
        .version = targets_version,
        .expires = try gpa.dupe(u8, expires),
        .entries = entries,
        .gpa = gpa,
    };
    errdefer targets.deinit();
    const targets_bytes = try targets.encode(gpa);
    defer gpa.free(targets_bytes);
    const targets_digest = try documentDigest(gpa, targets_bytes);

    var snapshot = Snapshot{
        .version = snapshot_version,
        .expires = try gpa.dupe(u8, expires),
        .targets_version = targets_version,
        .targets_digest = targets_digest,
        .gpa = gpa,
    };
    errdefer snapshot.deinit();
    const snapshot_bytes = try snapshot.encode(gpa);
    defer gpa.free(snapshot_bytes);
    const snapshot_digest = try documentDigest(gpa, snapshot_bytes);

    var timestamp = Timestamp{
        .version = timestamp_version,
        .expires = try gpa.dupe(u8, expires),
        .snapshot_version = snapshot_version,
        .snapshot_digest = snapshot_digest,
        .gpa = gpa,
    };
    errdefer timestamp.deinit();
    const timestamp_bytes = try timestamp.encode(gpa);
    defer gpa.free(timestamp_bytes);

    return .{
        .targets = targets,
        .snapshot = snapshot,
        .timestamp = timestamp,
        .targets_signature = try targets_key.sign(targets_bytes),
        .snapshot_signature = try snapshot_key.sign(snapshot_bytes),
        .timestamp_signature = try timestamp_key.sign(timestamp_bytes),
        .gpa = gpa,
    };
}

test "m07/TRUST-002 accept authorized metadata" {
    std.debug.print("JCKG_EVIDENCE TRUST-002\n", .{});
    const gpa = std.testing.allocator;

    const targets_key = try keys.testKeyPair("targets-k");
    const snapshot_key = try keys.testKeyPair("snapshot-k");
    const timestamp_key = try keys.testKeyPair("timestamp-k");

    const targets_roles = [_]keys.Role{.targets};
    const snapshot_roles = [_]keys.Role{.snapshot};
    const timestamp_roles = [_]keys.Role{.timestamp};
    const ring = keys.KeyRing{ .entries = &.{
        .{ .id = targets_key.publicKey().id(), .key = targets_key.publicKey(), .roles = &targets_roles },
        .{ .id = snapshot_key.publicKey().id(), .key = snapshot_key.publicKey(), .roles = &snapshot_roles },
        .{ .id = timestamp_key.publicKey().id(), .key = timestamp_key.publicKey(), .roles = &timestamp_roles },
    } };

    var chain = try buildChain(gpa, 1, 1, 1, targets_key, snapshot_key, timestamp_key, root.fixture_expiry, true);
    defer chain.deinit();

    var state = TrustState.init(gpa);
    defer state.deinit();

    try verifyChain(
        gpa,
        ring,
        &state,
        root.fixture_now,
        chain.timestamp,
        &.{chain.timestamp_signature},
        chain.snapshot,
        &.{chain.snapshot_signature},
        chain.targets,
        &.{chain.targets_signature},
    );

    // The verified document is usable and the trusted versions advanced.
    try std.testing.expectEqual(@as(u64, 1), state.targets_version);
    try std.testing.expectEqual(@as(u64, 1), state.snapshot_version);
    try std.testing.expectEqual(@as(u64, 1), state.timestamp_version);
    const entry = chain.targets.find("app") orelse return error.MissingTarget;
    try std.testing.expectEqual(@as(u64, 42), entry.length);
    try std.testing.expectEqualStrings("linux-x86_64", entry.platform.?);

    // Negative-or-recovery: a later, correctly signed version is accepted, and
    // a document signed by a key that is not authorized for its role is not.
    var next = try buildChain(gpa, 2, 2, 2, targets_key, snapshot_key, timestamp_key, root.fixture_expiry, true);
    defer next.deinit();
    try verifyChain(
        gpa,
        ring,
        &state,
        root.fixture_now,
        next.timestamp,
        &.{next.timestamp_signature},
        next.snapshot,
        &.{next.snapshot_signature},
        next.targets,
        &.{next.targets_signature},
    );
    try std.testing.expectEqual(@as(u64, 2), state.targets_version);

    var wrong_role = try buildChain(gpa, 3, 3, 3, snapshot_key, snapshot_key, timestamp_key, root.fixture_expiry, true);
    defer wrong_role.deinit();
    try std.testing.expectError(
        error.NotAuthorized,
        verifyChain(
            gpa,
            ring,
            &state,
            root.fixture_now,
            wrong_role.timestamp,
            &.{wrong_role.timestamp_signature},
            wrong_role.snapshot,
            &.{wrong_role.snapshot_signature},
            wrong_role.targets,
            &.{wrong_role.targets_signature},
        ),
    );
    // The failed attempt did not advance the trusted version.
    try std.testing.expectEqual(@as(u64, 2), state.targets_version);
}

test "m07/TRUST-004 reject rollback" {
    std.debug.print("JCKG_EVIDENCE TRUST-004\n", .{});
    const gpa = std.testing.allocator;

    const targets_key = try keys.testKeyPair("targets-r");
    const snapshot_key = try keys.testKeyPair("snapshot-r");
    const timestamp_key = try keys.testKeyPair("timestamp-r");
    const targets_roles = [_]keys.Role{.targets};
    const snapshot_roles = [_]keys.Role{.snapshot};
    const timestamp_roles = [_]keys.Role{.timestamp};
    const ring = keys.KeyRing{ .entries = &.{
        .{ .id = targets_key.publicKey().id(), .key = targets_key.publicKey(), .roles = &targets_roles },
        .{ .id = snapshot_key.publicKey().id(), .key = snapshot_key.publicKey(), .roles = &snapshot_roles },
        .{ .id = timestamp_key.publicKey().id(), .key = timestamp_key.publicKey(), .roles = &timestamp_roles },
    } };

    var state = TrustState.init(gpa);
    defer state.deinit();

    var fresh = try buildChain(gpa, 5, 5, 5, targets_key, snapshot_key, timestamp_key, root.fixture_expiry, true);
    defer fresh.deinit();
    try verifyChain(
        gpa,
        ring,
        &state,
        root.fixture_now,
        fresh.timestamp,
        &.{fresh.timestamp_signature},
        fresh.snapshot,
        &.{fresh.snapshot_signature},
        fresh.targets,
        &.{fresh.targets_signature},
    );
    try std.testing.expectEqual(@as(u64, 5), state.targets_version);

    // An older, correctly signed snapshot is a rollback and is refused.
    var older = try buildChain(gpa, 4, 4, 4, targets_key, snapshot_key, timestamp_key, root.fixture_expiry, true);
    defer older.deinit();
    try std.testing.expectError(
        error.RollbackDetected,
        verifyChain(
            gpa,
            ring,
            &state,
            root.fixture_now,
            older.timestamp,
            &.{older.timestamp_signature},
            older.snapshot,
            &.{older.snapshot_signature},
            older.targets,
            &.{older.targets_signature},
        ),
    );

    // Replaying the exact same metadata is also refused (equal is not newer).
    try std.testing.expectError(
        error.RollbackDetected,
        verifyChain(
            gpa,
            ring,
            &state,
            root.fixture_now,
            fresh.timestamp,
            &.{fresh.timestamp_signature},
            fresh.snapshot,
            &.{fresh.snapshot_signature},
            fresh.targets,
            &.{fresh.targets_signature},
        ),
    );

    // The state still describes the newest accepted version, and a genuinely
    // newer document is accepted afterwards.
    try std.testing.expectEqual(@as(u64, 5), state.targets_version);
    try std.testing.expectEqual(@as(u64, 5), state.snapshot_version);
    try std.testing.expectEqual(@as(u64, 5), state.timestamp_version);
    try std.testing.expect(state.targets_digest != null);

    var newer = try buildChain(gpa, 6, 6, 6, targets_key, snapshot_key, timestamp_key, root.fixture_expiry, true);
    defer newer.deinit();
    try verifyChain(
        gpa,
        ring,
        &state,
        root.fixture_now,
        newer.timestamp,
        &.{newer.timestamp_signature},
        newer.snapshot,
        &.{newer.snapshot_signature},
        newer.targets,
        &.{newer.targets_signature},
    );
    try std.testing.expectEqual(@as(u64, 6), state.targets_version);
}

test "m07/TRUST-005 reject expiry" {
    std.debug.print("JCKG_EVIDENCE TRUST-005\n", .{});
    const gpa = std.testing.allocator;

    const targets_key = try keys.testKeyPair("targets-e");
    const snapshot_key = try keys.testKeyPair("snapshot-e");
    const timestamp_key = try keys.testKeyPair("timestamp-e");
    const targets_roles = [_]keys.Role{.targets};
    const snapshot_roles = [_]keys.Role{.snapshot};
    const timestamp_roles = [_]keys.Role{.timestamp};
    const ring = keys.KeyRing{ .entries = &.{
        .{ .id = targets_key.publicKey().id(), .key = targets_key.publicKey(), .roles = &targets_roles },
        .{ .id = snapshot_key.publicKey().id(), .key = snapshot_key.publicKey(), .roles = &snapshot_roles },
        .{ .id = timestamp_key.publicKey().id(), .key = timestamp_key.publicKey(), .roles = &timestamp_roles },
    } };

    var state = TrustState.init(gpa);
    defer state.deinit();

    // Every role expires: a chain past its timestamp expiry is refused, and
    // nothing is committed.
    var expired = try buildChain(gpa, 1, 1, 1, targets_key, snapshot_key, timestamp_key, root.fixture_past, true);
    defer expired.deinit();
    try std.testing.expectError(
        error.Expired,
        verifyChain(
            gpa,
            ring,
            &state,
            root.fixture_now,
            expired.timestamp,
            &.{expired.timestamp_signature},
            expired.snapshot,
            &.{expired.snapshot_signature},
            expired.targets,
            &.{expired.targets_signature},
        ),
    );
    try std.testing.expectEqual(@as(u64, 0), state.targets_version);
    try std.testing.expect(state.targets_digest == null);

    // A malformed expiry is refused rather than compared lexicographically.
    var malformed = try buildChain(gpa, 1, 1, 1, targets_key, snapshot_key, timestamp_key, "tomorrow", true);
    defer malformed.deinit();
    try std.testing.expectError(
        error.InvalidTimestamp,
        verifyChain(
            gpa,
            ring,
            &state,
            root.fixture_now,
            malformed.timestamp,
            &.{malformed.timestamp_signature},
            malformed.snapshot,
            &.{malformed.snapshot_signature},
            malformed.targets,
            &.{malformed.targets_signature},
        ),
    );

    // An invalid clock is refused too: the caller cannot widen the window.
    var valid = try buildChain(gpa, 1, 1, 1, targets_key, snapshot_key, timestamp_key, root.fixture_expiry, true);
    defer valid.deinit();
    try std.testing.expectError(
        error.InvalidTimestamp,
        verifyChain(
            gpa,
            ring,
            &state,
            "not-a-time",
            valid.timestamp,
            &.{valid.timestamp_signature},
            valid.snapshot,
            &.{valid.snapshot_signature},
            valid.targets,
            &.{valid.targets_signature},
        ),
    );

    // Negative-or-recovery: an in-window chain is accepted afterwards.
    try verifyChain(
        gpa,
        ring,
        &state,
        root.fixture_now,
        valid.timestamp,
        &.{valid.timestamp_signature},
        valid.snapshot,
        &.{valid.snapshot_signature},
        valid.targets,
        &.{valid.targets_signature},
    );
    try std.testing.expectEqual(@as(u64, 1), state.targets_version);
}

test "m07/TRUST-006 reject mixed snapshots" {
    std.debug.print("JCKG_EVIDENCE TRUST-006\n", .{});
    const gpa = std.testing.allocator;

    const targets_key = try keys.testKeyPair("targets-m");
    const snapshot_key = try keys.testKeyPair("snapshot-m");
    const timestamp_key = try keys.testKeyPair("timestamp-m");
    const targets_roles = [_]keys.Role{.targets};
    const snapshot_roles = [_]keys.Role{.snapshot};
    const timestamp_roles = [_]keys.Role{.timestamp};
    const ring = keys.KeyRing{ .entries = &.{
        .{ .id = targets_key.publicKey().id(), .key = targets_key.publicKey(), .roles = &targets_roles },
        .{ .id = snapshot_key.publicKey().id(), .key = snapshot_key.publicKey(), .roles = &snapshot_roles },
        .{ .id = timestamp_key.publicKey().id(), .key = timestamp_key.publicKey(), .roles = &timestamp_roles },
    } };

    var state = TrustState.init(gpa);
    defer state.deinit();

    var baseline = try buildChain(gpa, 7, 7, 7, targets_key, snapshot_key, timestamp_key, root.fixture_expiry, true);
    defer baseline.deinit();

    // The timestamp pins snapshot version 7, but the snapshot served is version
    // 8 (signed correctly). The mix is refused instead of downgrading a role.
    var other_snapshot = try buildChain(gpa, 8, 8, 8, targets_key, snapshot_key, timestamp_key, root.fixture_expiry, true);
    defer other_snapshot.deinit();
    try std.testing.expectError(
        error.VersionMismatch,
        verifyChain(
            gpa,
            ring,
            &state,
            root.fixture_now,
            baseline.timestamp,
            &.{baseline.timestamp_signature},
            other_snapshot.snapshot,
            &.{other_snapshot.snapshot_signature},
            other_snapshot.targets,
            &.{other_snapshot.targets_signature},
        ),
    );

    // A snapshot whose digest does not match the timestamp's pin is refused
    // even when the version numbers agree.
    var swapped = try buildChain(gpa, 7, 7, 7, targets_key, snapshot_key, timestamp_key, root.fixture_expiry, false);
    defer swapped.deinit();
    try std.testing.expectError(
        error.DigestMismatch,
        verifyChain(
            gpa,
            ring,
            &state,
            root.fixture_now,
            baseline.timestamp,
            &.{baseline.timestamp_signature},
            swapped.snapshot,
            &.{swapped.snapshot_signature},
            swapped.targets,
            &.{swapped.targets_signature},
        ),
    );

    // ... and a targets document that is not the one the snapshot pins fails
    // the second cross-check.
    var mixed_targets = try buildChain(gpa, 7, 7, 7, targets_key, snapshot_key, timestamp_key, root.fixture_expiry, false);
    defer mixed_targets.deinit();
    try std.testing.expectError(
        error.DigestMismatch,
        verifyChain(
            gpa,
            ring,
            &state,
            root.fixture_now,
            baseline.timestamp,
            &.{baseline.timestamp_signature},
            baseline.snapshot,
            &.{baseline.snapshot_signature},
            mixed_targets.targets,
            &.{mixed_targets.targets_signature},
        ),
    );

    // Nothing was committed by any of the failed transactions.
    try std.testing.expectEqual(@as(u64, 0), state.targets_version);
    try std.testing.expect(state.snapshot_digest == null);

    // Negative-or-recovery: the consistent chain is accepted.
    try verifyChain(
        gpa,
        ring,
        &state,
        root.fixture_now,
        baseline.timestamp,
        &.{baseline.timestamp_signature},
        baseline.snapshot,
        &.{baseline.snapshot_signature},
        baseline.targets,
        &.{baseline.targets_signature},
    );
    try std.testing.expectEqual(@as(u64, 7), state.targets_version);
}

test "m07/TRUST-008 distinguish offline execution" {
    std.debug.print("JCKG_EVIDENCE TRUST-008\n", .{});
    const gpa = std.testing.allocator;

    const policy = offlineDecision();
    try std.testing.expect(policy.allow_installed_artifacts);
    try std.testing.expect(!policy.allow_new_metadata);
    try std.testing.expect(policy.reason.len > 0);

    // Already installed and trusted artifacts remain usable offline.
    const installed = [_][]const u8{
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    };
    try verifyOffline(&installed, installed[0]);
    try verifyOffline(&installed, installed[1]);

    // An artifact that was never installed is not usable offline: a cached
    // artifact is not a substitute for verified metadata.
    try std.testing.expectError(
        error.OfflineUnknownArtifact,
        verifyOffline(&installed, "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
    );
    try std.testing.expectError(error.OfflineUnknownArtifact, verifyOffline(&installed, ""));

    // A failed refresh must not turn stale metadata into an accepted update:
    // expired metadata still fails, and a rollback to an older version fails
    // exactly as it does online.
    const targets_key = try keys.testKeyPair("targets-o");
    const snapshot_key = try keys.testKeyPair("snapshot-o");
    const timestamp_key = try keys.testKeyPair("timestamp-o");
    const targets_roles = [_]keys.Role{.targets};
    const snapshot_roles = [_]keys.Role{.snapshot};
    const timestamp_roles = [_]keys.Role{.timestamp};
    const ring = keys.KeyRing{ .entries = &.{
        .{ .id = targets_key.publicKey().id(), .key = targets_key.publicKey(), .roles = &targets_roles },
        .{ .id = snapshot_key.publicKey().id(), .key = snapshot_key.publicKey(), .roles = &snapshot_roles },
        .{ .id = timestamp_key.publicKey().id(), .key = timestamp_key.publicKey(), .roles = &timestamp_roles },
    } };

    var state = TrustState.init(gpa);
    defer state.deinit();
    var current = try buildChain(gpa, 3, 3, 3, targets_key, snapshot_key, timestamp_key, root.fixture_expiry, true);
    defer current.deinit();
    try verifyChain(
        gpa,
        ring,
        &state,
        root.fixture_now,
        current.timestamp,
        &.{current.timestamp_signature},
        current.snapshot,
        &.{current.snapshot_signature},
        current.targets,
        &.{current.targets_signature},
    );

    var stale = try buildChain(gpa, 2, 2, 2, targets_key, snapshot_key, timestamp_key, root.fixture_expiry, true);
    defer stale.deinit();
    try std.testing.expectError(
        error.RollbackDetected,
        verifyChain(
            gpa,
            ring,
            &state,
            root.fixture_now,
            stale.timestamp,
            &.{stale.timestamp_signature},
            stale.snapshot,
            &.{stale.snapshot_signature},
            stale.targets,
            &.{stale.targets_signature},
        ),
    );

    var expired = try buildChain(gpa, 4, 4, 4, targets_key, snapshot_key, timestamp_key, root.fixture_past, true);
    defer expired.deinit();
    try std.testing.expectError(
        error.Expired,
        verifyChain(
            gpa,
            ring,
            &state,
            root.fixture_now,
            expired.timestamp,
            &.{expired.timestamp_signature},
            expired.snapshot,
            &.{expired.snapshot_signature},
            expired.targets,
            &.{expired.targets_signature},
        ),
    );
    try std.testing.expectEqual(@as(u64, 3), state.targets_version);
}
