//! Console interrupt handling (case CLI-009).
//!
//! A console Ctrl+C must stop a long client operation cleanly instead of
//! killing the process mid-write. The handler only sets a flag: the operation
//! stops at its next defined boundary. `SetConsoleCtrlHandler` has no binding
//! in the pinned standard library, so it is declared here directly with the
//! documented Win32 signature.
const std = @import("std");
const builtin = @import("builtin");
const cancel = @import("../core/cancel.zig");

const is_windows = builtin.os.tag == .windows;

const HandlerRoutine = *const fn (ctrl_type: u32) callconv(.winapi) i32;

extern "kernel32" fn SetConsoleCtrlHandler(handler: ?HandlerRoutine, add: i32) callconv(.winapi) i32;

var active_token: ?*cancel.Token = null;

fn onConsoleEvent(ctrl_type: u32) callconv(.winapi) i32 {
    _ = ctrl_type;
    // Request cancellation and keep the process alive so the operation can
    // emit its final result and release what it holds.
    if (active_token) |token| token.request();
    return 1;
}

/// Installs the interrupt handler for this process.
///
/// Returns false when the platform has no console handler or the call failed;
/// the caller must then report cancellation support honestly instead of
/// assuming an interrupt will be handled.
pub fn install(token: *cancel.Token) bool {
    if (!is_windows) return false;
    active_token = token;
    return SetConsoleCtrlHandler(onConsoleEvent, 1) != 0;
}

/// Removes the handler. Any later interrupt uses the platform default.
pub fn uninstall() void {
    if (!is_windows) return;
    active_token = null;
    _ = SetConsoleCtrlHandler(onConsoleEvent, 0);
}

/// Whether this process has a console interrupt handler installed.
pub fn isInstalled() bool {
    return active_token != null;
}

test "m01/console handler reports availability honestly" {
    var token: cancel.Token = .{};
    const installed = install(&token);
    // On this host the call must succeed; elsewhere the caller is told so
    // rather than being promised a handler that does not exist.
    if (is_windows) {
        try std.testing.expect(installed);
        try std.testing.expect(isInstalled());
        uninstall();
        try std.testing.expect(!isInstalled());
    } else {
        try std.testing.expect(!installed);
    }
}
