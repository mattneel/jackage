//! Domain-separated content identities (cases CAN-007, CAN-008).
//!
//! A digest proves integrity, not publisher identity, and the domain prefix
//! keeps a tree, an action, and a plan with equal canonical bytes from
//! colliding. The prefix contains a real NUL byte, so no valid UTF-8 document
//! can accidentally reproduce it.
const std = @import("std");
const canonical = @import("canonical.zig");

pub const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Domain = enum {
    tree,
    action,
    plan,

    /// `jckg:<domain>:v1\0`
    pub fn prefix(self: Domain) []const u8 {
        return switch (self) {
            .tree => "jckg:tree:v1\x00",
            .action => "jckg:action:v1\x00",
            .plan => "jckg:plan:v1\x00",
        };
    }
};

/// A SHA-256 content digest, displayed as `sha256:` plus 64 lowercase hex digits.
pub const Digest = struct {
    bytes: [32]u8,

    pub const text_length = 71;

    pub fn text(self: Digest, buffer: *[text_length]u8) []const u8 {
        const hex = std.fmt.bytesToHex(self.bytes, .lower);
        @memcpy(buffer[0..7], "sha256:");
        @memcpy(buffer[7..], &hex);
        return buffer[0..text_length];
    }

    pub fn eql(a: Digest, b: Digest) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }

    pub const ParseError = error{InvalidDigest};

    /// Parses the displayed form. Uppercase hex is accepted and normalized;
    /// any other shape is rejected.
    pub fn parse(text_value: []const u8) ParseError!Digest {
        const prefix = "sha256:";
        if (!std.mem.startsWith(u8, text_value, prefix)) return error.InvalidDigest;
        const hex = text_value[prefix.len..];
        if (hex.len != 64) return error.InvalidDigest;
        var digest: Digest = undefined;
        for (hex, 0..) |character, index| {
            const lower = std.ascii.toLower(character);
            if (!std.ascii.isHex(lower)) return error.InvalidDigest;
            digest.bytes[index / 2] = if (index % 2 == 0) (nibble(lower) << 4) else digest.bytes[index / 2] | nibble(lower);
        }
        return digest;
    }
};

fn nibble(character: u8) u8 {
    return std.fmt.charToDigit(character, 16) catch unreachable;
}

/// SHA-256 of raw bytes: the blob identity. No domain prefix, because a blob
/// digest names the exact file bytes a caller supplied.
pub fn ofBlob(content: []const u8) Digest {
    var digest: Digest = undefined;
    Sha256.hash(content, &digest.bytes, .{});
    return digest;
}

/// SHA-256 of `prefix || canonical bytes`.
pub fn ofCanonicalBytes(domain: Domain, bytes: []const u8) Digest {
    var hasher = Sha256.init(.{});
    hasher.update(domain.prefix());
    hasher.update(bytes);
    var digest: Digest = undefined;
    hasher.final(&digest.bytes);
    return digest;
}

/// Encodes `value` canonically and hashes it in the requested domain.
pub fn ofCanonical(
    gpa: std.mem.Allocator,
    domain: Domain,
    value: canonical.Value,
) std.mem.Allocator.Error!Digest {
    const bytes = try canonical.encodeAlloc(gpa, value);
    defer gpa.free(bytes);
    return ofCanonicalBytes(domain, bytes);
}

pub const blob_fixture_path = ".jackage-delivery/fixtures/blob-vectors.json";
pub const canonical_fixture_path = ".jackage-delivery/fixtures/canonical-vectors.json";

test "m02/CAN-007 apply digest domains" {
    std.debug.print("JCKG_EVIDENCE CAN-007\n", .{});
    var buffer: [Digest.text_length]u8 = undefined;

    // The three prefixes are distinct and NUL-terminated.
    try std.testing.expectEqual(@as(usize, 13), Domain.tree.prefix().len);
    try std.testing.expectEqual(@as(usize, 15), Domain.action.prefix().len);
    try std.testing.expectEqual(@as(usize, 13), Domain.plan.prefix().len);
    try std.testing.expectEqualStrings("jckg:tree:v1", Domain.tree.prefix()[0..12]);
    try std.testing.expectEqual(@as(u8, 0), Domain.tree.prefix()[12]);
    try std.testing.expectEqual(@as(u8, 0), Domain.action.prefix()[14]);
    try std.testing.expectEqual(@as(u8, 0), Domain.plan.prefix()[12]);
    try std.testing.expect(!std.mem.eql(u8, Domain.tree.prefix(), Domain.plan.prefix()));

    // Identical canonical bytes produce different identities per domain.
    const bytes = "{\"a\":1}";
    const tree = ofCanonicalBytes(.tree, bytes);
    const action = ofCanonicalBytes(.action, bytes);
    const plan = ofCanonicalBytes(.plan, bytes);
    try std.testing.expect(!tree.eql(action));
    try std.testing.expect(!action.eql(plan));
    try std.testing.expect(!tree.eql(plan));

    // The same domain and bytes are stable.
    try std.testing.expect(tree.eql(ofCanonicalBytes(.tree, bytes)));

    // Displayed form is stable, parseable, and round-trips.
    const text_value = tree.text(&buffer);
    try std.testing.expectEqual(@as(usize, 71), text_value.len);
    try std.testing.expectEqualStrings("sha256:", text_value[0..7]);
    for (text_value[7..]) |character| try std.testing.expect(std.ascii.isHex(character) and !std.ascii.isUpper(character));
    const parsed = try Digest.parse(text_value);
    try std.testing.expect(parsed.eql(tree));
    // Uppercase input normalizes to the same digest.
    var upper: [71]u8 = undefined;
    @memcpy(upper[0..7], "sha256:");
    const uppercase_hex = std.fmt.bytesToHex(tree.bytes, .upper);
    @memcpy(upper[7..], &uppercase_hex);
    try std.testing.expect((try Digest.parse(&upper)).eql(tree));

    // Negative-or-recovery: malformed digests are rejected rather than
    // truncated into a plausible identity.
    try std.testing.expectError(error.InvalidDigest, Digest.parse("sha256:abc"));
    try std.testing.expectError(error.InvalidDigest, Digest.parse("sha256:"));
    try std.testing.expectError(error.InvalidDigest, Digest.parse("md5:aa"));
    var bad_hex: [Digest.text_length]u8 = undefined;
    @memcpy(bad_hex[0..7], "sha256:");
    @memset(bad_hex[7..], '0');
    bad_hex[Digest.text_length - 1] = 'z';
    try std.testing.expectError(error.InvalidDigest, Digest.parse(&bad_hex));

    // A blob digest has no domain prefix: the same bytes hashed as a blob and
    // as a tree value differ.
    try std.testing.expect(!ofBlob(bytes).eql(ofCanonicalBytes(.tree, bytes)));
}

test "m02/CAN-008 verify raw blob bytes" {
    std.debug.print("JCKG_EVIDENCE CAN-008\n", .{});
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var buffer: [Digest.text_length]u8 = undefined;

    const text = try std.Io.Dir.cwd().readFileAlloc(io, blob_fixture_path, gpa, .unlimited);
    defer gpa.free(text);
    var document = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    defer document.deinit();

    const vectors = document.value.object.get("vectors").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), vectors.len);
    for (vectors) |vector| {
        const id = vector.object.get("id").?.string;
        const hex = vector.object.get("bytesHex").?.string;
        const expected = vector.object.get("digest").?.string;
        const size = vector.object.get("size").?.integer;

        const bytes = try gpa.alloc(u8, hex.len / 2);
        defer gpa.free(bytes);
        _ = try std.fmt.hexToBytes(bytes, hex);
        try std.testing.expectEqual(@as(i64, @intCast(bytes.len)), size);

        const digest = ofBlob(bytes);
        if (!std.mem.eql(u8, digest.text(&buffer), expected)) {
            std.debug.print("blob {s}: computed {s}, fixture {s}\n", .{ id, digest.text(&buffer), expected });
            return error.BlobDigestMismatch;
        }
    }

    // The empty blob is the canonical SHA-256 of zero bytes.
    try std.testing.expectEqualStrings(
        "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ofBlob("").text(&buffer),
    );

    // Negative-or-recovery: a single changed byte changes the identity, and
    // verification of mismatched bytes fails instead of passing.
    try std.testing.expect(!ofBlob("Jackage fixture\n").eql(ofBlob("Jackage fixture\r\n")));
    const sample = ofBlob("abc");
    try std.testing.expect(!sample.eql(ofBlob("abd")));
    var mutated: [32]u8 = sample.bytes;
    mutated[31] ^= 0x01;
    try std.testing.expect(!(Digest{ .bytes = mutated }).eql(sample));
}

test "m02/digests match every canonical fixture vector" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var buffer: [Digest.text_length]u8 = undefined;

    const text = try std.Io.Dir.cwd().readFileAlloc(io, canonical_fixture_path, gpa, .unlimited);
    defer gpa.free(text);
    var document = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    defer document.deinit();

    for (document.value.object.get("vectors").?.array.items) |vector| {
        const id = vector.object.get("id").?.string;
        const expected_bytes = vector.object.get("canonicalUtf8Hex").?.string;
        const expected_tree = vector.object.get("treeDigest").?.string;
        const expected_action = vector.object.get("actionDigest").?.string;
        const expected_plan = vector.object.get("planDigest").?.string;

        const bytes = try gpa.alloc(u8, expected_bytes.len / 2);
        defer gpa.free(bytes);
        _ = try std.fmt.hexToBytes(bytes, expected_bytes);

        const computed_tree = ofCanonicalBytes(.tree, bytes);
        const computed_action = ofCanonicalBytes(.action, bytes);
        const computed_plan = ofCanonicalBytes(.plan, bytes);
        if (!std.mem.eql(u8, computed_tree.text(&buffer), expected_tree) or
            !std.mem.eql(u8, computed_action.text(&buffer), expected_action) or
            !std.mem.eql(u8, computed_plan.text(&buffer), expected_plan))
        {
            std.debug.print("vector {s}: digest mismatch against the fixture\n", .{id});
            return error.DigestVectorMismatch;
        }
    }
}
