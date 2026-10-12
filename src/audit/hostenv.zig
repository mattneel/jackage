//! Legacy host-environment guard (case AUD-008).
//!
//! The user keeps a WSL distribution with a custom kernel. Case zero must
//! observe that environment without changing it. This module therefore only
//! ever runs read-only enumerations, records a stable digest of what it saw,
//! and can prove that two observations agree. Any other use is a bug, so the
//! argument vector is a compile-time constant and a guard test checks it
//! against a list of mutating subcommands.
const std = @import("std");
const host = @import("host.zig");

/// The only WSL invocation this delivery is allowed to make.
pub const list_argv = [_][]const u8{ "wsl.exe", "--list", "--verbose" };

/// Subcommands that would change machine state and therefore must never be
/// part of a Jackage observation.
pub const mutating_flags = [_][]const u8{
    "--terminate",
    "--shutdown",
    "--unregister",
    "--mount",
    "--unmount",
    "--import",
    "--export",
    "--set-version",
    "--set-default",
    "--update",
    "--install",
    "--manage",
    "--move",
};

pub const Error = error{
    WslStateChanged,
    EnumerationFailed,
};

pub const WslState = struct {
    /// Whether a WSL installation answered the read-only enumeration.
    available: bool,
    /// Normalised text of the enumeration, owned.
    text: []const u8,
    /// Digest of `text`; two observations must agree byte for byte.
    digest_hex: [64]u8,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *WslState) void {
        self.gpa.free(self.text);
        self.* = undefined;
    }
};

/// Decodes output that Windows WSL may emit as UTF-16LE when redirected.
/// ASCII-range code units are kept, other units become '?', so the digest is
/// stable across console and pipe capture without pretending to be a full
/// Unicode decoder.
pub fn normaliseEnumeration(gpa: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]u8 {
    const looks_utf16 = raw.len >= 2 and raw.len % 2 == 0 and raw[1] == 0;
    if (!looks_utf16) return gpa.dupe(u8, raw);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var index: usize = 0;
    while (index + 1 < raw.len) : (index += 2) {
        const unit = std.mem.readInt(u16, raw[index..][0..2], .little);
        if (unit == 0) continue;
        try out.append(gpa, if (unit < 0x80) @intCast(unit) else '?');
    }
    return out.toOwnedSlice(gpa);
}

fn digestHex(text: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Observes the WSL environment read-only. A host without WSL is reported as
/// unavailable rather than treated as a failure.
pub fn snapshot(io: std.Io, gpa: std.mem.Allocator, host_facts: host.HostFacts) !WslState {
    if (host_facts.os != .windows) {
        return .{
            .available = false,
            .text = try gpa.dupe(u8, ""),
            .digest_hex = digestHex(""),
            .gpa = gpa,
        };
    }
    const result = std.process.run(gpa, io, .{
        .argv = &list_argv,
        .stderr_limit = .limited(4096),
        .stdout_limit = .limited(64 * 1024),
    }) catch {
        return .{
            .available = false,
            .text = try gpa.dupe(u8, ""),
            .digest_hex = digestHex(""),
            .gpa = gpa,
        };
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    const text = try normaliseEnumeration(gpa, result.stdout);
    errdefer gpa.free(text);
    return .{
        .available = result.term.success(),
        .text = text,
        .digest_hex = digestHex(text),
        .gpa = gpa,
    };
}

/// Fails when two observations disagree: that would mean case-zero work
/// changed the user's legacy environment.
pub fn assertUnchanged(before: WslState, after: WslState) Error!void {
    if (before.available != after.available) return error.WslStateChanged;
    if (!std.mem.eql(u8, &before.digest_hex, &after.digest_hex)) return error.WslStateChanged;
}

test "m00/AUD-008 preserve legacy WSL state" {
    std.debug.print("JCKG_EVIDENCE AUD-008\n", .{});
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // The observation argv is read-only by construction.
    for (list_argv) |argument| {
        for (mutating_flags) |mutating| {
            try std.testing.expect(!std.mem.eql(u8, argument, mutating));
        }
    }
    try std.testing.expectEqualStrings("--list", list_argv[1]);
    try std.testing.expectEqualStrings("--verbose", list_argv[2]);

    // The decoder handles both capture encodings without inventing bytes.
    const utf16 = [_]u8{ 'O', 0, 'K', 0 };
    const decoded = try normaliseEnumeration(gpa, &utf16);
    defer gpa.free(decoded);
    try std.testing.expectEqualStrings("OK", decoded);
    const plain = try normaliseEnumeration(gpa, "plain");
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("plain", plain);

    var facts = try host.detect(io, gpa);
    defer facts.deinit();

    var first = try snapshot(io, gpa, facts);
    defer first.deinit();
    var second = try snapshot(io, gpa, facts);
    defer second.deinit();

    // Case zero runs on a Windows host that has WSL. In the declared Linux
    // execution environment there is no WSL to observe, and the guard must say
    // so instead of pretending it observed something.
    if (facts.os == .windows) {
        try std.testing.expect(first.available);
        try std.testing.expect(first.text.len > 0);
    } else {
        try std.testing.expect(!first.available);
        try std.testing.expectEqual(@as(usize, 0), first.text.len);
    }
    try assertUnchanged(first, second);

    // Negative-or-recovery: a legacy environment that did change is reported.
    var changed = try snapshot(io, gpa, facts);
    defer changed.deinit();
    @memset(&changed.digest_hex, 'f');
    try std.testing.expectError(error.WslStateChanged, assertUnchanged(first, changed));

    // Two unavailable observations are equal observations: there is nothing to
    // compare, so "unchanged" is the honest verdict. A pair that disagrees about
    // availability *is* a change, and that is the negative this test keeps.
    var unavailable = try snapshot(io, gpa, facts);
    defer unavailable.deinit();
    unavailable.available = false;
    if (!first.available) {
        try assertUnchanged(first, unavailable);
    } else {
        try std.testing.expectError(error.WslStateChanged, assertUnchanged(first, unavailable));
    }
}
