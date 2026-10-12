//! Documented process exit codes (CLI proposal `CLI_UX.md`).
//!
//! Zero means success. Every other class of failure has its own stable number
//! so a caller can branch without parsing human text, and so a launched
//! program's own status stays distinguishable from a Jackage failure.
const std = @import("std");

pub const Code = enum(u8) {
    /// The command completed; every requested effect committed.
    success = 0,
    /// Invalid syntax, unknown command, unknown flag, or missing argument.
    usage = 2,
    /// A policy denied the request: missing authorization, missing trust, or
    /// an unsupported isolation requirement.
    policy = 3,
    /// Resolution failed: no selection satisfies the request.
    resolution = 4,
    /// Integrity failed: digest, length, signature, or identity mismatch.
    integrity = 5,
    /// An action ran and failed, or produced invalid declared outputs.
    action = 6,
    /// Infrastructure failed: unreadable input, unavailable backend, transport
    /// failure, or an internal error.
    infrastructure = 7,
    /// The operation was canceled before committing; 130 is the conventional
    /// 128 + SIGINT value, kept stable on every platform.
    canceled = 130,

    pub fn number(self: Code) u8 {
        return @intFromEnum(self);
    }

    pub fn text(self: Code) []const u8 {
        return switch (self) {
            .success => "success",
            .usage => "usage",
            .policy => "policy-denied",
            .resolution => "resolution",
            .integrity => "integrity",
            .action => "action-failed",
            .infrastructure => "infrastructure",
            .canceled => "canceled",
        };
    }

    /// Stable machine-readable identifier used in structured errors.
    pub fn stableId(self: Code) []const u8 {
        return switch (self) {
            .success => "OK",
            .usage => "USAGE",
            .policy => "POLICY_DENIED",
            .resolution => "RESOLUTION_FAILED",
            .integrity => "INTEGRITY_FAILED",
            .action => "ACTION_FAILED",
            .infrastructure => "INFRASTRUCTURE_FAILED",
            .canceled => "CANCELED",
        };
    }
};

test "m01/exit codes are distinct and documented" {
    std.debug.print("JCKG_EVIDENCE CLI-004\n", .{});
    const all = [_]Code{ .success, .usage, .policy, .resolution, .integrity, .action, .infrastructure, .canceled };
    var seen: [256]bool = @splat(false);
    for (all) |code| {
        try std.testing.expect(!seen[code.number()]);
        seen[code.number()] = true;
        try std.testing.expect(code.text().len > 0);
        try std.testing.expect(code.stableId().len > 0);
    }
    try std.testing.expectEqual(@as(u8, 0), Code.success.number());
    // Non-success codes stay below 128 except the conventional cancellation
    // value, so a future signal translation has a free range.
    for (all) |code| {
        if (code == .canceled or code == .success) continue;
        try std.testing.expect(code.number() > 0 and code.number() < 128);
    }
    try std.testing.expectEqual(@as(u8, 130), Code.canceled.number());
}
