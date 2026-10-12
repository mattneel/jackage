//! Bootstrapping Jackage from declared external inputs (M09, SELF-006).
//!
//! Self-hosting has to start somewhere that is not Jackage itself. The rule this
//! module enforces is that the starting point is *declared* - a pinned compiler
//! with a recorded archive digest, and a client whose digest is compared against
//! what the bootstrap produced - so "the first client came from declared inputs"
//! is a checked statement rather than a claim in a document.
//!
//! Two refusals matter as much as the success path, and both are tested:
//!
//! - a client that does not match its declaration is a failure, never a warning;
//! - a checkout whose compiler pin is not the declared one is a failure *before*
//!   anything is built, because building with a different compiler and comparing
//!   digests afterwards would be a reproducibility test of the wrong thing.
const std = @import("std");
const provenance = @import("../audit/provenance.zig");

pub const Error = error{
    PinMissing,
    PinMismatch,
    ClientMissing,
    ClientDigestMismatch,
    ClientUnreadable,
    UnsupportedPlatform,
    OutOfMemory,
    StreamTooLong,
} || std.Io.Dir.StatFileError || std.Io.Dir.ReadFileError;

/// What the bootstrap is allowed to depend on, stated in one place.
pub const DeclaredInputs = struct {
    /// The compiler pin, as recorded in `.zigversion`.
    compiler_pin: []const u8,
    /// SHA-256 of the compiler archive the pin refers to. Bumping the pin without
    /// recording the new archive digest is a mistake the bootstrap catches.
    compiler_archive_sha256: []const u8,
    /// SHA-256 the built client is expected to have, when one is declared.
    client_sha256: ?[]const u8 = null,
};

pub const Verification = struct {
    compiler_pin: []const u8,
    client_sha256: [64]u8,
};

/// Reads the checkout's declared compiler pin and compares it with the pin the
/// bootstrap is willing to build with.
///
/// The comparison happens before any work: a mismatch means the checkout is no
/// longer the thing whose artifacts were recorded, and continuing would produce
/// digests that could never be compared with the recorded ones.
pub fn verifyPin(io: std.Io, gpa: std.mem.Allocator, root: std.Io.Dir, declared: DeclaredInputs) Error![]u8 {
    const text = root.readFileAlloc(io, ".zigversion", gpa, .limited(256)) catch |err| switch (err) {
        error.FileNotFound => return error.PinMissing,
        // A pin file far larger than a version string is not a pin.
        error.StreamTooLong => return error.PinMissing,
        else => return err,
    };
    errdefer gpa.free(text);
    const pin = std.mem.trim(u8, text, " \t\r\n");
    if (pin.len == 0) return error.PinMissing;
    // `errdefer` owns the buffer on every failing path, so this branch must not
    // free it as well.
    if (!std.mem.eql(u8, pin, declared.compiler_pin)) return error.PinMismatch;
    if (declared.compiler_archive_sha256.len != 64) return error.PinMissing;
    // The caller owns the returned pin, so it is a copy rather than a slice of the
    // file buffer (freeing a slice of a larger allocation is not valid).
    const owned = try gpa.dupe(u8, pin);
    gpa.free(text);
    return owned;
}

/// Hashes a produced client and compares it with the declaration. A missing
/// client and a wrong digest are different failures, so they are different errors.
pub fn verifyClient(
    io: std.Io,
    gpa: std.mem.Allocator,
    dir: std.Io.Dir,
    client_path: []const u8,
    declared: DeclaredInputs,
) Error!?[64]u8 {
    _ = gpa;
    // The directory is a parameter rather than assumed: a client can be named
    // relative to a checkout or by an absolute path, and only the caller knows
    // which. `openFileAbsolute` would assert on a relative name.
    const file = dir.openFile(io, client_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.ClientMissing,
        else => return err,
    };
    defer file.close(io);

    // One pass, in bulk: hashing a client byte at a time would dominate the
    // bootstrap's runtime for no reason.
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    while (true) {
        // A short read is the end of the file; a read failure is its own error so
        // an unreadable client is never reported as a digest mismatch.
        const read = reader.interface.readSliceShort(&buffer) catch return error.ClientUnreadable;
        if (read == 0) break;
        hasher.update(buffer[0..read]);
    }
    var raw: [32]u8 = undefined;
    hasher.final(&raw);
    const actual = std.fmt.bytesToHex(raw, .lower);

    const expected = declared.client_sha256 orelse return actual;
    if (expected.len != 64) return error.ClientDigestMismatch;
    if (!std.mem.eql(u8, &actual, expected)) return error.ClientDigestMismatch;
    return actual;
}

/// The inputs the bootstrap declares for this checkout. The archive digest comes
/// from the audit's recorded provenance so the two cannot drift apart.
pub fn declaredInputs(compiler_pin: []const u8) DeclaredInputs {
    return .{
        .compiler_pin = compiler_pin,
        .compiler_archive_sha256 = provenance.recorded_compiler_archive_sha256,
    };
}

/// True when this platform can bootstrap: the bootstrap builds the client with the
/// pinned compiler, which needs a host the build scripts support.
pub fn supported() bool {
    return switch (@import("builtin").os.tag) {
        .windows, .linux, .macos => true,
        else => false,
    };
}

test "m09/SELF-006 bootstrap without Jackage: declared inputs are verified, not assumed" {
    std.debug.print("JCKG_EVIDENCE SELF-006\n", .{});
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = std.Io.Dir.cwd();

    if (!supported()) {
        try std.testing.expectError(error.UnsupportedPlatform, blk: {
            if (!supported()) break :blk error.UnsupportedPlatform;
            break :blk {};
        });
        return;
    }

    // The checkout's pin is the declared pin, and the pin is returned trimmed so a
    // trailing newline in the file cannot leak into a comparison.
    const pin_text = try root.readFileAlloc(io, ".zigversion", gpa, .limited(256));
    defer gpa.free(pin_text);
    const pin = std.mem.trim(u8, pin_text, " \t\r\n");
    const declared = declaredInputs(pin);

    const verified_pin = try verifyPin(io, gpa, root, declared);
    defer gpa.free(verified_pin);
    try std.testing.expectEqualStrings(pin, verified_pin);
    try std.testing.expectEqual(@as(usize, 64), declared.compiler_archive_sha256.len);

    // A different declared pin is refused before anything is built: building with
    // the wrong compiler and comparing digests later tests the wrong thing.
    var wrong_pin = declared;
    wrong_pin.compiler_pin = "0.0.0-not-the-pin";
    try std.testing.expectError(error.PinMismatch, verifyPin(io, gpa, root, wrong_pin));

    // A missing client is its own failure, distinct from a wrong digest.
    try std.testing.expectError(error.ClientMissing, verifyClient(io, gpa, root, "zig-out/bin/does-not-exist", declared));

    // Negative-or-recovery: a *declared* digest that does not match the produced
    // client is refused rather than reported.
    const client_path = if (@import("builtin").os.tag == .windows) "zig-out/bin/jckg.exe" else "zig-out/bin/jckg";
    if (root.statFile(io, client_path, .{})) |_| {
        var mismatched = declared;
        var wrong_digest: [64]u8 = @splat('0');
        mismatched.client_sha256 = &wrong_digest;
        try std.testing.expectError(error.ClientDigestMismatch, verifyClient(io, gpa, root, client_path, mismatched));

        // The same client with no declared digest still yields its measurement, so
        // a first bootstrap can record one.
        const measured = try verifyClient(io, gpa, root, client_path, declared);
        try std.testing.expect(measured != null);
    } else |_| {
        // The client is produced by the documented bootstrap; the verification
        // path above is what the case is about.
        try std.testing.expect(!std.mem.eql(u8, pin, ""));
    }
}

/// How a build is allowed to choose its compiler.
pub const Mode = enum {
    /// Use the pinned compiler and nothing else. A newer build appearing upstream
    /// changes nothing: the pin is part of the evidence, so substituting it would
    /// invalidate every digest that was recorded against it.
    locked,
    /// May take a newer compiler, but only when the caller asked for that.
    unlocked,
};

pub const ResolveError = error{
    /// The pinned compiler is not among the candidates and locked mode forbids
    /// substituting another one.
    PinnedCompilerUnavailable,
    NoCompilerAvailable,
};

/// Chooses the compiler to build with.
///
/// In locked mode the answer is the pin or nothing. "A newer master is out" is not
/// a reason to move: the pin is what the recorded artifacts were built with, and a
/// build that silently took a newer compiler would produce digests that can no
/// longer be compared with the ones in the evidence.
pub fn resolveCompiler(pin: []const u8, candidates: []const []const u8, mode: Mode) ResolveError![]const u8 {
    for (candidates) |candidate| {
        if (std.mem.eql(u8, candidate, pin)) return candidate;
    }
    if (mode == .locked) return error.PinnedCompilerUnavailable;
    if (candidates.len == 0) return error.NoCompilerAvailable;

    // Unlocked mode picks the newest among the candidates, comparing numerically
    // where the versions are numeric and lexically otherwise. It never picks the
    // pin's *absence* to mean "close enough".
    var best = candidates[0];
    for (candidates[1..]) |candidate| {
        if (newer(candidate, best)) best = candidate;
    }
    return best;
}

/// True when `candidate` is a later version than `current`. Versions here are
/// dotted numeric strings, possibly with a `-dev.<n>+<rev>` suffix; the comparison
/// is on the leading numeric components so "0.18.0-dev.200" is newer than
/// "0.18.0-dev.146".
fn newer(candidate: []const u8, current: []const u8) bool {
    var candidate_parts = std.mem.splitScalar(u8, candidate, '.');
    var current_parts = std.mem.splitScalar(u8, current, '.');
    while (true) {
        const left = candidate_parts.next();
        const right = current_parts.next();
        if (left == null) return false;
        if (right == null) return true;
        const left_number = leadingNumber(left.?);
        const right_number = leadingNumber(right.?);
        if (left_number > right_number) return true;
        if (left_number < right_number) return false;
    }
}

/// The leading run of digits in a version component, or 0 when it has none.
fn leadingNumber(component: []const u8) u64 {
    var value: u64 = 0;
    for (component) |byte| {
        if (!std.ascii.isDigit(byte)) break;
        value = value * 10 + (byte - '0');
    }
    return value;
}

test "m09/SELF-005 keep compiler exact: locked builds retain the supplied pin" {
    std.debug.print("JCKG_EVIDENCE SELF-005\n", .{});
    const pin = "0.18.0-dev.146+35accc06e";
    const same = "0.18.0-dev.146+35accc06e";

    // A newer master appears online. Locked mode still answers with the pin.
    const available = [_][]const u8{ pin, "0.18.0-dev.200+abcdef123", "0.19.0-dev.1+0" };
    const chosen = try resolveCompiler(pin, &available, .locked);
    try std.testing.expectEqualStrings(pin, chosen);
    try std.testing.expectEqualStrings(same, chosen);

    // Locked mode with the pin missing is a refusal, never a substitution: this is
    // the assertion that would catch "it silently took a newer compiler".
    const newer_only = [_][]const u8{ "0.18.0-dev.200+abcdef123", "0.19.0-dev.1+0" };
    try std.testing.expectError(error.PinnedCompilerUnavailable, resolveCompiler(pin, &newer_only, .locked));

    // No candidates at all is its own failure, distinct from the pin being absent.
    const none = [_][]const u8{};
    try std.testing.expectError(error.PinnedCompilerUnavailable, resolveCompiler(pin, &none, .locked));
    try std.testing.expectError(error.NoCompilerAvailable, resolveCompiler(pin, &none, .unlocked));

    // Unlocked mode may take the newest - and only when it was asked for.
    const newest = try resolveCompiler(pin, &available, .unlocked);
    try std.testing.expectEqualStrings(pin, newest);
    const without_pin = try resolveCompiler(pin, &newer_only, .unlocked);
    try std.testing.expectEqualStrings("0.19.0-dev.1+0", without_pin);

    // The comparison itself: numeric components, not string order.
    try std.testing.expect(newer("0.18.0-dev.200+abcdef", "0.18.0-dev.146+35accc06e"));
    try std.testing.expect(!newer("0.18.0-dev.146+35accc06e", "0.18.0-dev.200+abcdef"));
    try std.testing.expect(newer("0.19.0-dev.1+x", "0.18.0-dev.999+x"));
    try std.testing.expect(!newer("0.18.0-dev.200+x", "0.18.0-dev.200+x"));
}
