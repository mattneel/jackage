//! Resolving a user-style repository URL into a channel (M14, GH-001).
//!
//! The user gives a URL and expects a package. What that URL names is a *discovery
//! descriptor*: a pinned document saying where the channel's metadata and assets
//! live, signed by a key the ring knows. Two facts come out of reading it, and they
//! are deliberately kept apart:
//!
//! - the **revision** the client read, which is what a later resolution compares
//!   against to notice that the channel moved;
//! - the **trust** decision: whether the descriptor's signature verifies.
//!
//! Conflating them is the mistake worth designing against. A descriptor that was
//! fetched successfully has a real revision even when its signature is wrong, and
//! saying so is more useful than collapsing both into "failed": the operator needs to
//! know whether they are looking at the wrong document or at a forgery of the right
//! one. The revision is recorded first, and trust is decided after it, as its own
//! step. A key the ring does not hold is a third answer again - nothing can be
//! decided about such a document, which is not the same as it being wrong.
const std = @import("std");
const keys = @import("../trust/keys.zig");
const download = @import("../trust/download.zig");
const store_module = @import("../core/store.zig");
const digest = @import("../core/digest.zig");

pub const Error = error{
    DescriptorUnavailable,
    InvalidChannelUrl,
    InvalidDescriptor,
    OutOfMemory,
};

pub const Trust = enum {
    /// A key in the ring signed this descriptor and the signature verified.
    verified,
    /// The descriptor's signature did not verify against the signing key.
    signature_invalid,
    /// The descriptor names a key the ring does not hold: nothing can be decided
    /// about it, which is not the same as it being wrong.
    key_unknown,
};

pub const Descriptor = struct {
    /// Where the channel's metadata is served, relative to the repository.
    metadata_path: []const u8,
    /// Where the channel's assets are served.
    assets_path: []const u8,
    /// The document as fetched, which is what the signature covers.
    bytes: []const u8,
    /// The signing key the descriptor claims.
    key_id: keys.KeyId,
    signature: [keys.signature_length]u8,
};

pub fn deinitDescriptor(gpa: std.mem.Allocator, descriptor: Descriptor) void {
    gpa.free(descriptor.metadata_path);
    gpa.free(descriptor.assets_path);
    gpa.free(descriptor.bytes);
}

pub const Resolution = struct {
    /// The revision the client read: the artifact digest plus the validator the
    /// server supplied, recorded whatever the trust outcome turns out to be.
    revision: []u8,
    /// The trust decision, made separately and after the revision is recorded.
    trust: Trust,
    descriptor: Descriptor,

    pub fn deinit(self: Resolution, gpa: std.mem.Allocator) void {
        gpa.free(self.revision);
        deinitDescriptor(gpa, self.descriptor);
    }
};

fn hexToBytes(comptime count: usize, text: []const u8) Error![count]u8 {
    if (text.len != count * 2) return error.InvalidDescriptor;
    var out: [count]u8 = undefined;
    for (0..count) |index| {
        out[index] = std.fmt.parseInt(u8, text[index * 2 .. index * 2 + 2], 16) catch return error.InvalidDescriptor;
    }
    return out;
}

/// Parses the descriptor document. Separated from fetching so a malformed document
/// is a parse failure, not a network one.
pub fn parseDescriptor(gpa: std.mem.Allocator, bytes: []const u8) Error!Descriptor {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch return error.InvalidDescriptor;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidDescriptor;
    const object = parsed.value.object;
    const metadata = object.get("metadata") orelse return error.InvalidDescriptor;
    const assets = object.get("assets") orelse return error.InvalidDescriptor;
    const key_text = object.get("key_id") orelse return error.InvalidDescriptor;
    const signature_text = object.get("signature") orelse return error.InvalidDescriptor;
    if (metadata != .string or assets != .string or key_text != .string or signature_text != .string) {
        return error.InvalidDescriptor;
    }
    if (metadata.string.len == 0 or assets.string.len == 0) return error.InvalidDescriptor;

    const id = try hexToBytes(keys.key_id_length, key_text.string);
    const signature = try hexToBytes(keys.signature_length, signature_text.string);

    return .{
        .metadata_path = try gpa.dupe(u8, metadata.string),
        .assets_path = try gpa.dupe(u8, assets.string),
        .bytes = try gpa.dupe(u8, bytes),
        .key_id = id,
        .signature = signature,
    };
}

/// The bytes a descriptor's signature covers.
///
/// The signature cannot cover the whole document, because the document contains the
/// signature. It covers a canonical rendering of the fields instead, so the signed
/// bytes are a function of the descriptor and nothing else - which is what makes it
/// possible to verify a document that arrived over an untrusted transport.
pub fn signedPayload(gpa: std.mem.Allocator, descriptor: Descriptor) Error![]u8 {
    var id_buffer: [keys.key_id_length * 2]u8 = undefined;
    return std.fmt.allocPrint(gpa, "jackage-discovery-v1\n{s}\n{s}\n{s}", .{
        descriptor.metadata_path,
        descriptor.assets_path,
        keys.keyIdText(descriptor.key_id, &id_buffer),
    });
}

/// Decides trust for a descriptor against a ring, as its own step.
pub fn decideTrust(gpa: std.mem.Allocator, ring: keys.KeyRing, descriptor: Descriptor) Error!Trust {
    const entry = ring.find(descriptor.key_id) orelse return .key_unknown;
    const payload = try signedPayload(gpa, descriptor);
    defer gpa.free(payload);
    entry.key.verify(payload, descriptor.signature) catch return .signature_invalid;
    return .verified;
}

/// Resolves a channel: fetch the pinned descriptor, record its revision, then decide
/// its trust.
///
/// The revision is recorded before the trust decision and returned alongside it
/// rather than replaced by it: a caller that only looks at the revision still learns
/// the channel moved, and a caller that only looks at trust still learns which
/// revision was judged.
pub fn resolve(
    io: std.Io,
    gpa: std.mem.Allocator,
    request: download.Request,
    ring: keys.KeyRing,
    store: store_module.Store,
) Error!Resolution {
    var client = download.Client.init(io, gpa, store);
    defer client.deinit();
    var result = client.download(request) catch return error.DescriptorUnavailable;
    defer result.deinit();

    // The bytes are read back from the store rather than from the response, so what
    // is parsed is exactly what the verified digest covers.
    const bytes = store.readBlobAlloc(gpa, result.artifact.digest) catch return error.DescriptorUnavailable;
    defer gpa.free(bytes);

    const descriptor = try parseDescriptor(gpa, bytes);
    errdefer deinitDescriptor(gpa, descriptor);

    var digest_text: [digest.Digest.text_length]u8 = undefined;
    const revision = if (result.etag) |etag|
        std.fmt.allocPrint(gpa, "{s}@{s}", .{ result.artifact.digest.text(&digest_text), etag })
    else
        gpa.dupe(u8, result.artifact.digest.text(&digest_text));

    return .{
        .revision = try revision,
        .trust = try decideTrust(gpa, ring, descriptor),
        .descriptor = descriptor,
    };
}

test "m14/GH-001 discover repository channel: revision recorded, trust decided separately" {
    std.debug.print("JCKG_EVIDENCE GH-001\n", .{});
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const pair = try keys.testKeyPair("gh-001");
    const public = pair.publicKey();
    const ring_entry = keys.RingEntry{ .id = public.id(), .key = public, .roles = &.{.root} };
    const ring = keys.KeyRing{ .entries = &.{ring_entry} };

    const store_path = "zig-out/jckg-gh-001-store";
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, store_path) catch {};
    defer cwd.deleteTree(io, store_path) catch {};
    var store_root = try cwd.createDirPathOpen(io, store_path, .{});
    defer store_root.close(io);
    // The store handle is a directory: every blob path is relative to it.
    const store = store_module.Store.init(io, gpa, store_root);
    try store.ensureLayout();

    var id_buffer: [keys.key_id_length * 2]u8 = undefined;
    const key_text = keys.keyIdText(public.id(), &id_buffer);

    // The payload the signature covers, rendered canonically. The document below
    // carries the signature; the signature covers this.
    const payload = try std.fmt.allocPrint(gpa, "jackage-discovery-v1\n/meta\n/assets\n{s}", .{key_text});
    defer gpa.free(payload);
    const signature = try pair.sign(payload);

    const good_document = try std.fmt.allocPrint(
        gpa,
        "{{\"metadata\":\"/meta\",\"assets\":\"/assets\",\"key_id\":\"{s}\",\"signature\":\"{s}\"}}",
        .{ key_text, std.fmt.bytesToHex(signature.signature, .lower) },
    );
    defer gpa.free(good_document);

    // A document that claims the trusted key but was signed by another one.
    const other_pair = try keys.testKeyPair("gh-001-forger");
    const forged_signature = try other_pair.sign(payload);
    const forged_document = try std.fmt.allocPrint(
        gpa,
        "{{\"metadata\":\"/meta\",\"assets\":\"/assets\",\"key_id\":\"{s}\",\"signature\":\"{s}\"}}",
        .{ key_text, std.fmt.bytesToHex(forged_signature.signature, .lower) },
    );
    defer gpa.free(forged_document);

    // A document naming a key the ring does not hold.
    const unknown_pair = try keys.testKeyPair("gh-001-unknown");
    var unknown_buffer: [keys.key_id_length * 2]u8 = undefined;
    const unknown_text = keys.keyIdText(unknown_pair.publicKey().id(), &unknown_buffer);
    const unknown_document = try std.fmt.allocPrint(
        gpa,
        "{{\"metadata\":\"/meta\",\"assets\":\"/assets\",\"key_id\":\"{s}\",\"signature\":\"{s}\"}}",
        .{ unknown_text, std.fmt.bytesToHex(signature.signature, .lower) },
    );
    defer gpa.free(unknown_document);

    // A real fixture serves the discovery endpoint with a validator.
    const good_routes = [_]download.FixtureRoute{
        .{
            .path = "/.well-known/jackage.json",
            .responses = &.{.{
                .body = good_document,
                .etag = "\"rev-7\"",
            }},
        },
        // The same endpoint serving a document signed by somebody else: a real
        // fixture, so the forgery travels the same transport as the honest document.
        .{
            .path = "/forged.json",
            .responses = &.{.{
                .body = forged_document,
                .etag = "\"rev-7\"",
            }},
        },
    };
    var server = try download.FixtureServer.init(io, gpa, &good_routes);
    try server.start();
    defer server.deinit();

    const url = try server.urlAlloc(gpa, "/.well-known/jackage.json");
    defer gpa.free(url);
    const body_digest = try store.importBytes(good_document, null);

    const resolution = try resolve(io, gpa, .{
        .url = url,
        .expected = .{ .digest = body_digest, .byte_length = good_document.len },
    }, ring, store);
    defer resolution.deinit(gpa);

    // Both facts are present: the revision that was read, and the trust decision.
    try std.testing.expectEqual(Trust.verified, resolution.trust);
    try std.testing.expect(std.mem.endsWith(u8, resolution.revision, "@\"rev-7\""));
    try std.testing.expectEqualStrings("/meta", resolution.descriptor.metadata_path);
    try std.testing.expectEqualStrings("/assets", resolution.descriptor.assets_path);

    // A forged signature: trust fails, and the revision is still recorded. This is
    // the separation the case is about - the two facts do not collapse into "failed".
    const forged = try parseDescriptor(gpa, forged_document);
    defer deinitDescriptor(gpa, forged);
    try std.testing.expectEqual(Trust.signature_invalid, try decideTrust(gpa, ring, forged));
    const forged_url = try server.urlAlloc(gpa, "/forged.json");
    defer gpa.free(forged_url);
    const forged_resolution = try resolve(io, gpa, .{
        .url = forged_url,
        .expected = .{ .digest = try store.importBytes(forged_document, null), .byte_length = forged_document.len },
    }, ring, store);
    defer forged_resolution.deinit(gpa);
    try std.testing.expectEqual(Trust.signature_invalid, forged_resolution.trust);
    try std.testing.expect(std.mem.endsWith(u8, forged_resolution.revision, "@\"rev-7\""));
    try std.testing.expect(std.mem.startsWith(u8, forged_resolution.revision, "sha256:"));

    // An unknown key is a third answer, not a synonym for an invalid signature.
    const unknown = try parseDescriptor(gpa, unknown_document);
    defer deinitDescriptor(gpa, unknown);
    try std.testing.expectEqual(Trust.key_unknown, try decideTrust(gpa, ring, unknown));

    // The signed payload is a function of the descriptor alone, so the same document
    // verifies however it was transported.
    const good = try parseDescriptor(gpa, good_document);
    defer deinitDescriptor(gpa, good);
    const payload_again = try signedPayload(gpa, good);
    defer gpa.free(payload_again);
    try std.testing.expectEqualStrings(payload, payload_again);

    // The tampered-on-the-wire case is caught by the digest, before any of this: the
    // document that arrives must be the document the digest names.
    try std.testing.expectError(error.DescriptorUnavailable, resolve(io, gpa, .{
        .url = url,
        .expected = .{ .digest = try store.importBytes("{\"different\":true}", null), .byte_length = forged_document.len },
        .retry = .{ .max_attempts = 1 },
    }, ring, store));

    // A malformed descriptor is a parse failure rather than a trust failure, so the
    // caller can tell a broken channel from a hostile one.
    try std.testing.expectError(error.InvalidDescriptor, parseDescriptor(gpa, "not a document"));
    try std.testing.expectError(error.InvalidDescriptor, parseDescriptor(gpa, "{\"metadata\":\"/meta\"}"));
    try std.testing.expectError(error.InvalidDescriptor, parseDescriptor(gpa, "{\"metadata\":\"/meta\",\"assets\":\"/assets\",\"key_id\":\"zz\",\"signature\":\"aa\"}"));
}
