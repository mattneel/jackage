//! Signing as a separate action, with an explicit envelope policy (M10, PACK-008).
//!
//! Two identities must stay distinct, and this module is built so they cannot be
//! confused:
//!
//! - the **payload** identity: the digest of the package's bytes, which does not
//!   change when someone signs it;
//! - the **signed** identity: the digest of the envelope, which is a different
//!   artifact from the package and is what a channel publishes.
//!
//! The envelope carries an explicit *policy* - what the signature is asserting,
//! and by whom - and the signature covers that policy. An envelope whose policy
//! could be swapped without invalidating the signature would be asserting whatever
//! the reader happened to want, which is not an assertion at all.
//!
//! Signing uses the pinned standard library's Ed25519 through `trust/keys.zig`, so
//! the envelope is verified by the same key material and the same code path the
//! rest of the product trusts.
const std = @import("std");
const digest_module = @import("../core/digest.zig");
const canonical = @import("../core/canonical.zig");
const keys = @import("../trust/keys.zig");

pub const Error = error{
    InvalidPolicy,
    InvalidEnvelope,
    SignatureRejected,
    OutOfMemory,
    WriteFailed,
};

pub const Digest = digest_module.Digest;

pub const Envelope = struct {
    /// The digest of the bytes that were signed. Signing does not change it.
    payload_digest: Digest,
    /// What the signature asserts, named. Empty is refused: an unnamed policy is
    /// not a policy.
    policy: []const u8,
    /// Who signed, as the channel names them.
    signer: []const u8,
    /// The signing key's fingerprint, so a verifier knows which key to use.
    key_id: keys.KeyId,
    signature: [keys.signature_length]u8,
};

pub fn digestOf(bytes: []const u8) Digest {
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &raw, .{});
    return .{ .bytes = raw };
}

/// The exact bytes a signature covers: the payload digest, the policy, and the
/// signer - canonically encoded, so two verifiers cannot disagree about what was
/// signed.
fn coveredBytes(gpa: std.mem.Allocator, payload_digest: Digest, policy: []const u8, signer: []const u8) Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var text_buffer: [Digest.text_length]u8 = undefined;
    var fields = try arena.alloc(canonical.Entry, 3);
    fields[0] = .{ .key = "payload", .value = .{ .string = try arena.dupe(u8, payload_digest.text(&text_buffer)) } };
    fields[1] = .{ .key = "policy", .value = .{ .string = try arena.dupe(u8, policy) } };
    fields[2] = .{ .key = "signer", .value = .{ .string = try arena.dupe(u8, signer) } };
    var document = canonical.Value{ .object = fields };
    canonical.canonicalize(&document);
    return canonical.encodeAlloc(gpa, document);
}

/// Signs a payload. The unsigned payload's identity is an input, not something this
/// function recomputes from a possibly different byte string.
pub fn sign(
    gpa: std.mem.Allocator,
    authority: keys.KeyPair,
    signer: []const u8,
    policy: []const u8,
    payload: []const u8,
) Error!Envelope {
    if (policy.len == 0 or signer.len == 0) return error.InvalidPolicy;
    const payload_digest = digestOf(payload);
    const covered = try coveredBytes(gpa, payload_digest, policy, signer);
    defer gpa.free(covered);
    const entry = authority.sign(covered) catch return error.SignatureRejected;
    return .{
        .payload_digest = payload_digest,
        .policy = policy,
        .signer = signer,
        .key_id = entry.key_id,
        .signature = entry.signature,
    };
}

/// Verifies an envelope with a public key: the covered bytes are recomputed from
/// the envelope's own claims, so an edited policy or payload digest is a rejection.
pub fn verify(gpa: std.mem.Allocator, public_key: keys.PublicKey, envelope: Envelope) Error!void {
    const covered = try coveredBytes(gpa, envelope.payload_digest, envelope.policy, envelope.signer);
    defer gpa.free(covered);
    public_key.verify(covered, envelope.signature) catch return error.SignatureRejected;
}

/// The signed form's bytes, so the envelope has its own identity distinct from the
/// payload it signs.
pub fn serialize(gpa: std.mem.Allocator, envelope: Envelope) Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var text_buffer: [Digest.text_length]u8 = undefined;
    var signature_hex: [keys.signature_length * 2]u8 = undefined;
    const signature_text = std.fmt.bytesToHex(envelope.signature, .lower);
    @memcpy(&signature_hex, &signature_text);
    var key_text: [keys.key_id_length * 2]u8 = undefined;
    const key_hex = std.fmt.bytesToHex(envelope.key_id, .lower);
    @memcpy(&key_text, &key_hex);

    var fields = try arena.alloc(canonical.Entry, 5);
    fields[0] = .{ .key = "keyId", .value = .{ .string = try arena.dupe(u8, &key_text) } };
    fields[1] = .{ .key = "payload", .value = .{ .string = try arena.dupe(u8, envelope.payload_digest.text(&text_buffer)) } };
    fields[2] = .{ .key = "policy", .value = .{ .string = try arena.dupe(u8, envelope.policy) } };
    fields[3] = .{ .key = "signature", .value = .{ .string = try arena.dupe(u8, &signature_hex) } };
    fields[4] = .{ .key = "signer", .value = .{ .string = try arena.dupe(u8, envelope.signer) } };
    var document = canonical.Value{ .object = fields };
    canonical.canonicalize(&document);
    return canonical.encodeAlloc(gpa, document);
}

test "m10/PACK-008 separate signing: signed and unsigned identities stay distinct" {
    std.debug.print("JCKG_EVIDENCE PACK-008\n", .{});
    const gpa = std.testing.allocator;

    // A reproducible unsigned package: the same bytes give the same identity, which
    // is what lets the payload identity survive signing unchanged.
    const payload = "package payload bytes\n";
    const unsigned_digest = digestOf(payload);
    try std.testing.expect(Digest.eql(unsigned_digest, digestOf(payload)));

    // Test authority: a deterministic key derived from a label, so the fixture is
    // stable without shipping private key material.
    const authority = try keys.testKeyPair("release-authority");
    const other_authority = try keys.testKeyPair("someone-else");
    const policy = "release";

    // The envelope borrows the policy and signer strings it is given; the caller
    // owns them, so there is nothing to free here.
    const envelope = try sign(gpa, authority, "jackage-release", policy, payload);

    // Signing is an action with an explicit envelope policy: the policy is named,
    // the signer is named, and the key is identified.
    try std.testing.expectEqualStrings("release", envelope.policy);
    try std.testing.expectEqualStrings("jackage-release", envelope.signer);
    try std.testing.expect(Digest.eql(unsigned_digest, envelope.payload_digest));
    try std.testing.expectEqual(keys.key_id_length, envelope.key_id.len);

    // The envelope verifies with the authority's public key.
    try verify(gpa, authority.publicKey(), envelope);
    try std.testing.expectError(error.SignatureRejected, verify(gpa, other_authority.publicKey(), envelope));

    // The signed identity is distinct from the unsigned one, and it is *about* it:
    // the envelope names the payload digest, so the pair cannot be confused.
    const envelope_bytes = try serialize(gpa, envelope);
    defer gpa.free(envelope_bytes);
    const signed_digest = digestOf(envelope_bytes);
    try std.testing.expect(!Digest.eql(unsigned_digest, signed_digest));
    try std.testing.expect(std.mem.indexOf(u8, envelope_bytes, "payload") != null);
    var digest_buffer: [Digest.text_length]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, envelope_bytes, unsigned_digest.text(&digest_buffer)) != null);

    // Negative-or-recovery: the signature covers the policy, so swapping it
    // invalidates the envelope instead of re-asserting something else.
    var swapped = envelope;
    swapped.policy = "development";
    try std.testing.expectError(error.SignatureRejected, verify(gpa, authority.publicKey(), swapped));

    // And an envelope for a different payload does not verify against this one's
    // signature.
    var different_payload = envelope;
    different_payload.payload_digest = digestOf("other bytes\n");
    try std.testing.expectError(error.SignatureRejected, verify(gpa, authority.publicKey(), different_payload));

    // An unnamed policy is not a policy: signing refuses before producing anything.
    try std.testing.expectError(error.InvalidPolicy, sign(gpa, authority, "jackage-release", "", payload));
    try std.testing.expectError(error.InvalidPolicy, sign(gpa, authority, "", policy, payload));
}
