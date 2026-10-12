//! Signing keys, key identifiers, and threshold verification for repository
//! trust (cases TRUST-002, TRUST-003, TRUST-007).
//!
//! The implementation uses the pinned standard library's Ed25519 instead of a
//! hand-written primitive. A key identifier is the SHA-256 of a versioned,
//! domain-separated encoding of the public key, so a key id can be compared,
//! logged, and reasoned about without being the key. Threshold verification
//! counts *distinct* authorized keys: one key signing twice never satisfies a
//! threshold of two, and an unknown key id never contributes.
const std = @import("std");

pub const Error = error{
    InvalidKeyMaterial,
    InvalidSignature,
    UnknownKey,
    ThresholdNotMet,
    DuplicateKeyId,
    RoleNotAuthorized,
    UnsupportedAlgorithm,
};

/// Domain prefix for key identifiers. Like every other identity in the project
/// it is versioned and separated by a real NUL byte.
pub const key_id_prefix = "jckg:key:v1\x00";

pub const Algorithm = enum(u8) {
    ed25519 = 1,

    pub fn text(self: Algorithm) []const u8 {
        return switch (self) {
            .ed25519 => "ed25519",
        };
    }
};

pub const signature_length = 64;
pub const public_key_length = 32;
pub const key_id_length = 32;

pub const KeyId = [key_id_length]u8;

pub fn keyIdOf(algorithm: Algorithm, public_key: [public_key_length]u8) KeyId {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(key_id_prefix);
    hasher.update(&[_]u8{@intFromEnum(algorithm)});
    hasher.update(&public_key);
    var digest: KeyId = undefined;
    hasher.final(&digest);
    return digest;
}

/// Renders a key id as lowercase hex, for fingerprints shown to a human.
pub fn keyIdText(id: KeyId, buffer: *[key_id_length * 2]u8) []const u8 {
    const hex = std.fmt.bytesToHex(id, .lower);
    @memcpy(buffer, &hex);
    return buffer[0..];
}

pub const PublicKey = struct {
    algorithm: Algorithm = .ed25519,
    bytes: [public_key_length]u8,

    pub const ParseError = error{ InvalidKeyMaterial, UnsupportedAlgorithm };

    pub const text_length = 8 + public_key_length * 2; // "ed25519:" plus hex

    pub fn parse(text_value: []const u8) ParseError!PublicKey {
        const separator = std.mem.indexOfScalar(u8, text_value, ':') orelse return error.InvalidKeyMaterial;
        const algorithm_text = text_value[0..separator];
        const hex = text_value[separator + 1 ..];
        const algorithm: Algorithm = if (std.mem.eql(u8, algorithm_text, "ed25519"))
            .ed25519
        else
            return error.UnsupportedAlgorithm;
        if (hex.len != public_key_length * 2) return error.InvalidKeyMaterial;
        var bytes: [public_key_length]u8 = undefined;
        _ = std.fmt.hexToBytes(&bytes, hex) catch return error.InvalidKeyMaterial;
        return .{ .algorithm = algorithm, .bytes = bytes };
    }

    pub fn format(self: PublicKey, buffer: *[text_length]u8) []const u8 {
        const hex = std.fmt.bytesToHex(self.bytes, .lower);
        return std.mem.print(buffer, "{s}:{s}", .{ self.algorithm.text(), hex }) catch buffer[0..0];
    }

    pub fn id(self: PublicKey) KeyId {
        return keyIdOf(self.algorithm, self.bytes);
    }

    pub fn verify(self: PublicKey, message: []const u8, signature: [signature_length]u8) Error!void {
        if (self.algorithm != .ed25519) return error.UnsupportedAlgorithm;
        const public = std.crypto.sign.Ed25519.PublicKey.fromBytes(self.bytes) catch return error.InvalidKeyMaterial;
        const parsed = std.crypto.sign.Ed25519.Signature.fromBytes(signature);
        parsed.verifyStrict(message, public) catch return error.InvalidSignature;
    }
};

pub const SignatureEntry = struct {
    key_id: KeyId,
    signature: [signature_length]u8,
};

/// A role a key may authorize. Thresholds are per role.
pub const Role = enum {
    root,
    targets,
    snapshot,
    timestamp,

    pub fn text(self: Role) []const u8 {
        return @tagName(self);
    }
};

pub const RingEntry = struct {
    id: KeyId,
    key: PublicKey,
    roles: []const Role,
};

pub const KeyRing = struct {
    entries: []const RingEntry,

    pub fn find(self: KeyRing, id: KeyId) ?RingEntry {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, &entry.id, &id)) return entry;
        }
        return null;
    }

    pub fn isAuthorized(self: KeyRing, id: KeyId, role: Role) bool {
        const entry = self.find(id) orelse return false;
        for (entry.roles) |authorized| {
            if (authorized == role) return true;
        }
        return false;
    }

    /// Verifies that at least `threshold` *distinct* authorized keys signed
    /// `message` for `role`.
    ///
    /// Every supplied signature is checked against the message; a valid
    /// signature from an unauthorized key, a duplicate signer, or an unknown
    /// key id does not count toward the threshold.
    pub fn verifyThreshold(
        self: KeyRing,
        role: Role,
        threshold: usize,
        message: []const u8,
        signatures: []const SignatureEntry,
    ) Error!void {
        if (threshold == 0) return error.ThresholdNotMet;
        var counted: usize = 0;
        for (signatures, 0..) |signature, index| {
            const entry = self.find(signature.key_id) orelse return error.UnknownKey;
            if (!self.isAuthorized(signature.key_id, role)) return error.RoleNotAuthorized;
            try entry.key.verify(message, signature.signature);

            // Only the first occurrence of a key counts toward the threshold.
            var already_counted = false;
            for (signatures[0..index]) |previous| {
                if (std.mem.eql(u8, &previous.key_id, &signature.key_id)) already_counted = true;
            }
            if (!already_counted) counted += 1;
        }
        if (counted < threshold) return error.ThresholdNotMet;
    }
};

pub const KeyPair = struct {
    secret: std.crypto.sign.Ed25519.SecretKey,
    public: PublicKey,

    pub fn generateDeterministic(seed: [32]u8) !KeyPair {
        const pair = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);
        return .{
            .secret = pair.secret_key,
            .public = .{ .bytes = pair.public_key.toBytes() },
        };
    }

    pub fn sign(self: KeyPair, message: []const u8) Error!SignatureEntry {
        const pair = std.crypto.sign.Ed25519.KeyPair.fromSecretKey(self.secret) catch return error.InvalidKeyMaterial;
        const signature = pair.sign(message, null) catch return error.InvalidKeyMaterial;
        return .{ .key_id = self.public.id(), .signature = signature.toBytes() };
    }

    pub fn publicKey(self: KeyPair) PublicKey {
        return self.public;
    }
};

/// A reproducible test key derived from a label, so fixtures are stable without
/// shipping private key material.
pub fn testKeyPair(label: []const u8) !KeyPair {
    var seed: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("jckg:test-key:v1\x00");
    hasher.update(label);
    hasher.final(&seed);
    return KeyPair.generateDeterministic(seed);
}

test "m07/TRUST-003 reject bad signatures" {
    std.debug.print("JCKG_EVIDENCE TRUST-003\n", .{});
    const gpa = std.testing.allocator;
    _ = gpa;

    const root_pair = try testKeyPair("root-a");
    const other_pair = try testKeyPair("root-b");
    const backup_pair = try testKeyPair("backup-a");

    const roles = [_]Role{.root};
    const backup_roles = [_]Role{ .root, .targets };
    const ring = KeyRing{ .entries = &.{
        .{ .id = root_pair.publicKey().id(), .key = root_pair.publicKey(), .roles = &roles },
        .{ .id = backup_pair.publicKey().id(), .key = backup_pair.publicKey(), .roles = &backup_roles },
    } };

    const message = "{\"signed\":\"metadata\"}";
    const good = try root_pair.sign(message);
    const backup_signature = try backup_pair.sign(message);

    // One authorized signature meets a threshold of one.
    try ring.verifyThreshold(.root, 1, message, &.{good});
    // Two distinct authorized keys meet a threshold of two.
    try ring.verifyThreshold(.root, 2, message, &.{ good, backup_signature });

    // A signature over different content is rejected.
    const tampered = "{\"signed\":\"tampered\"}";
    try std.testing.expectError(error.InvalidSignature, ring.verifyThreshold(.root, 1, tampered, &.{good}));

    // A valid signature from a key that is not in the ring is rejected.
    const stranger = try other_pair.sign(message);
    try std.testing.expectError(error.UnknownKey, ring.verifyThreshold(.root, 1, message, &.{stranger}));

    // Corrupted signature bytes are rejected.
    var corrupted = good;
    corrupted.signature[0] ^= 0xff;
    try std.testing.expectError(error.InvalidSignature, ring.verifyThreshold(.root, 1, message, &.{corrupted}));

    // A key that is authorized for another role cannot sign this role.
    try std.testing.expectError(error.RoleNotAuthorized, ring.verifyThreshold(.timestamp, 1, message, &.{good}));

    // The same key twice is one signature, not two: a threshold of two is not
    // met by repeating a single signer.
    try std.testing.expectError(error.ThresholdNotMet, ring.verifyThreshold(.root, 2, message, &.{ good, good }));
    // An empty signature set never meets a threshold.
    try std.testing.expectError(error.ThresholdNotMet, ring.verifyThreshold(.root, 1, message, &.{}));
    try std.testing.expectError(error.ThresholdNotMet, ring.verifyThreshold(.root, 0, message, &.{good}));

    // Key identifiers are stable, distinct, and derived from the public key.
    const first_id = root_pair.publicKey().id();
    const second_id = root_pair.publicKey().id();
    try std.testing.expectEqualSlices(u8, &first_id, &second_id);
    try std.testing.expect(!std.mem.eql(u8, &first_id, &other_pair.publicKey().id()));

    // The textual public key form round-trips, and a malformed one is refused.
    var buffer: [PublicKey.text_length]u8 = undefined;
    const text_value = root_pair.publicKey().format(&buffer);
    const parsed = try PublicKey.parse(text_value);
    try std.testing.expectEqualSlices(u8, &root_pair.publicKey().bytes, &parsed.bytes);
    try std.testing.expectError(error.InvalidKeyMaterial, PublicKey.parse("ed25519:zz"));
    try std.testing.expectError(error.UnsupportedAlgorithm, PublicKey.parse("rsa:00"));

    // A key id is a fingerprint, not key material: different algorithms with
    // the same bytes produce different identifiers.
    try std.testing.expect(!std.mem.eql(
        u8,
        &keyIdOf(.ed25519, root_pair.publicKey().bytes),
        &keyIdOf(.ed25519, other_pair.publicKey().bytes),
    ));
}
