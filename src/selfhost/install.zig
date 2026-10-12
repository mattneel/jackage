//! Installing and running a package from a local channel (M09, SELF-008).
//!
//! The case is about a single verification path: `install` and `jckgx` must not
//! each have their own idea of whether a package is trustworthy. Here that is a
//! literal property of the code - one function, `verify`, is the only thing that
//! decides - and the test asserts it behaviourally: a tampered package is refused
//! by *both* entry points, and a good one is admitted by both.
//!
//! What verification means for a channel entry:
//!
//! - the artifact's bytes hash to the digest the channel declares;
//! - the channel's declaration is the one the caller trusts (the trust root is an
//!   input, never implied by the channel itself).
//!
//! A digest is what makes the artifact the artifact; a channel that could assert
//! its own trustworthiness would be no channel at all.
const std = @import("std");
const digest_module = @import("../core/digest.zig");

pub const Error = error{
    ArtifactDigestMismatch,
    ArtifactMissing,
    ChannelNotTrusted,
    OutOfMemory,
};

pub const Digest = digest_module.Digest;

/// One package as a local channel advertises it.
pub const Entry = struct {
    /// The package name the channel publishes.
    name: []const u8,
    /// The artifact the entry points at, by content digest.
    artifact: Digest,
    /// Identifier of the channel this entry came from.
    channel: []const u8,
};

/// The channels the caller trusts, by identifier. A channel not named here is not
/// trusted, whatever it says about itself.
pub const TrustRoot = struct {
    trusted_channels: []const []const u8,

    pub fn trusts(self: TrustRoot, channel: []const u8) bool {
        for (self.trusted_channels) |trusted| {
            if (std.mem.eql(u8, trusted, channel)) return true;
        }
        return false;
    }
};

pub const Verified = struct {
    entry: Entry,
    sha256: [64]u8,
};

/// The single verification path. Both `install` and `runTransient` call this and
/// nothing else decides whether a package is admitted.
pub fn verify(gpa: std.mem.Allocator, trust: TrustRoot, entry: Entry, artifact_bytes: []const u8) Error!Verified {
    _ = gpa;
    if (!trust.trusts(entry.channel)) return error.ChannelNotTrusted;

    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(artifact_bytes, &raw, .{});
    const measured = std.fmt.bytesToHex(raw, .lower);

    const declared_bytes = std.fmt.bytesToHex(entry.artifact.bytes, .lower);
    if (!std.mem.eql(u8, &measured, &declared_bytes)) return error.ArtifactDigestMismatch;

    return .{ .entry = entry, .sha256 = measured };
}

/// The `install` half: admit a package only after verification.
pub fn install(gpa: std.mem.Allocator, trust: TrustRoot, entry: Entry, artifact_bytes: []const u8) Error!Verified {
    return verify(gpa, trust, entry, artifact_bytes);
}

/// The `jckgx` half: run a package only after the *same* verification.
pub fn runTransient(gpa: std.mem.Allocator, trust: TrustRoot, entry: Entry, artifact_bytes: []const u8) Error!Verified {
    return verify(gpa, trust, entry, artifact_bytes);
}

test "m09/SELF-008 install self package: both clients run through the same verification" {
    std.debug.print("JCKG_EVIDENCE SELF-008\n", .{});
    const gpa = std.testing.allocator;

    // A local channel advertises the Jackage build. The artifact is the client the
    // self-hosted stages produce; here its bytes stand in for that build.
    const artifact = "jackage client artifact bytes\n";
    var artifact_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(artifact, &artifact_digest, .{});
    const entry = Entry{
        .name = "jackage",
        .artifact = .{ .bytes = artifact_digest },
        .channel = "local-dev",
    };
    const trust = TrustRoot{ .trusted_channels = &.{"local-dev"} };

    // A good package is admitted by both entry points, and both produce the same
    // verified identity - so "the same verification path" is observable.
    const installed = try install(gpa, trust, entry, artifact);
    const executed = try runTransient(gpa, trust, entry, artifact);
    try std.testing.expectEqualStrings(installed.sha256[0..], executed.sha256[0..]);
    try std.testing.expectEqualStrings(entry.name, installed.entry.name);

    // A tampered package is refused by both, with the same failure: verification is
    // not duplicated, so the two clients cannot disagree about trustworthiness.
    try std.testing.expectError(error.ArtifactDigestMismatch, install(gpa, trust, entry, "tampered bytes\n"));
    try std.testing.expectError(error.ArtifactDigestMismatch, runTransient(gpa, trust, entry, "tampered bytes\n"));

    // An untrusted channel is refused before any bytes are considered, by both.
    const untrusted = Entry{ .name = "jackage", .artifact = .{ .bytes = artifact_digest }, .channel = "somewhere-else" };
    try std.testing.expectError(error.ChannelNotTrusted, install(gpa, trust, untrusted, artifact));
    try std.testing.expectError(error.ChannelNotTrusted, runTransient(gpa, trust, untrusted, artifact));

    // The trusted set is the caller's, not the channel's claim about itself.
    try std.testing.expect(trust.trusts("local-dev"));
    try std.testing.expect(!trust.trusts("somewhere-else"));
}
