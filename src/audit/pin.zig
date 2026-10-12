//! Bootstrap compiler pin identity (audit cases AUD-002 and AUD-003).
//!
//! The checkout pins exactly one Zig build in `.zigversion` and reaches it only
//! through `scripts/zig.ps1`. A mismatch must stop the caller: silently falling
//! back to another compiler would invalidate every recorded identity, so the
//! pin check returns an explicit error instead of selecting anything else.
const std = @import("std");

pub const PinError = error{PinMismatch};

/// Trims the surrounding whitespace that a wrapper adds around its output.
pub fn trimReport(raw: []const u8) []const u8 {
    return std.mem.trim(u8, raw, " \t\r\n");
}

pub const Pin = struct {
    /// Pin text as recorded, without surrounding whitespace.
    expected: []const u8,

    pub fn init(raw: []const u8) Pin {
        return .{ .expected = trimReport(raw) };
    }

    /// Verifies a version report produced by the pinned wrapper.
    ///
    /// The comparison is exact after trimming: a report that merely contains
    /// the pinned text somewhere (a banner plus a different version, a build
    /// suffix, a vendored copy) is still a mismatch.
    pub fn verify(self: Pin, reported: []const u8) PinError!void {
        if (!std.mem.eql(u8, self.expected, trimReport(reported))) return error.PinMismatch;
    }
};

/// Describes a mismatch for humans. Names both identities and states that no
/// fallback compiler was selected.
pub fn describeMismatch(
    gpa: std.mem.Allocator,
    pin: Pin,
    reported: []const u8,
) std.mem.Allocator.Error![]u8 {
    return gpa.print(
        "compiler pin mismatch: the checkout pins '{s}' but the wrapper reported '{s}'; refusing to fall back to a different Zig compiler. Run scripts/fetch-zig.ps1 to restore the pinned toolchain.",
        .{ pin.expected, trimReport(reported) },
    );
}

test "AUD-002 honor the compiler pin" {
    std.debug.print("JCKG_EVIDENCE AUD-002\n", .{});
    const gpa = std.testing.allocator;

    const pin = Pin.init("0.18.0-dev.146+35accc06e\n");
    try std.testing.expectEqualStrings("0.18.0-dev.146+35accc06e", pin.expected);

    // The wrapper's real output ends with a newline; PowerShell adds CRLF.
    try pin.verify("0.18.0-dev.146+35accc06e\n");
    try pin.verify("0.18.0-dev.146+35accc06e\r\n");
    try pin.verify("  0.18.0-dev.146+35accc06e  ");

    // A different pin text is a different pin identity.
    try std.testing.expectError(error.PinMismatch, Pin.init("0.15.1").verify("0.18.0-dev.146+35accc06e"));

    // Negative-or-recovery: an empty report cannot satisfy a real pin.
    try std.testing.expectError(error.PinMismatch, pin.verify(""));
    try std.testing.expectError(error.PinMismatch, pin.verify("\r\n"));
    try std.testing.expectError(error.PinMismatch, pin.verify("zig 0.18.0-dev.146+35accc06e"));

    const message = try describeMismatch(gpa, pin, "0.15.1\n");
    defer gpa.free(message);
    try std.testing.expect(std.mem.indexOf(u8, message, "0.18.0-dev.146+35accc06e") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "0.15.1") != null);
}

test "AUD-003 reject pin mismatch" {
    std.debug.print("JCKG_EVIDENCE AUD-003\n", .{});
    const gpa = std.testing.allocator;
    const pin = Pin.init("0.18.0-dev.146+35accc06e");

    // A fixture wrapper that reports a different compiler must fail explicitly.
    try std.testing.expectError(error.PinMismatch, pin.verify("0.15.1"));
    try std.testing.expectError(error.PinMismatch, pin.verify("0.18.0-dev.146+35accc06f"));
    try std.testing.expectError(error.PinMismatch, pin.verify("0.18.0-dev.146"));
    try std.testing.expectError(error.PinMismatch, pin.verify("0.18.0-dev.146+35accc06e\nnot a compiler"));

    // The failure must say which compiler was pinned and which one appeared,
    // so an operator can fix the environment instead of guessing.
    const message = try describeMismatch(gpa, pin, "0.20.0");
    defer gpa.free(message);
    try std.testing.expect(message.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, message, "0.20.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "refus") != null);
}
