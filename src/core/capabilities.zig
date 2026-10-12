//! Capability reporting for backends (case CLI-008).
//!
//! A capability claim must say what is actually enforced. The native process
//! backend in this build has no filesystem or network isolation: that is
//! reported as `unavailable`, it blocks release claims, and no label, container
//! name, or successful smoke test may turn it into support.
const std = @import("std");

pub const Status = enum {
    /// The backend enforces the restriction; adversarial tests must exist.
    enforced,
    /// The operation is implemented and tested, without a security boundary.
    supported,
    /// The property is measured or reported, not enforced.
    observed,
    /// The backend cannot provide the property at all.
    unavailable,

    pub fn text(self: Status) []const u8 {
        return switch (self) {
            .enforced => "enforced",
            .supported => "supported",
            .observed => "observed",
            .unavailable => "unavailable",
        };
    }

    pub fn canBecomeReleaseSupport(self: Status) bool {
        return self == .enforced or self == .supported;
    }
};

pub const Capability = struct {
    /// Stable dotted name, for example `filesystem.isolation`.
    name: []const u8,
    status: Status,
    /// What the claim rests on: a test, a platform property, or the absence of
    /// a mechanism.
    evidence: []const u8,
    /// A release claim that depends on this capability stays open while it is
    /// not enforced or supported.
    blocks_release: bool,
};

pub const Backend = struct {
    /// Backend identity, e.g. `native-process`.
    name: []const u8,
    /// Execution, package, or repository family.
    family: []const u8,
    /// The boundary the backend actually enforces, in plain words.
    isolation_boundary: []const u8,
    capabilities: []const Capability,

    pub fn countOf(self: Backend, status: Status) usize {
        var total: usize = 0;
        for (self.capabilities) |capability| {
            if (capability.status == status) total += 1;
        }
        return total;
    }

    pub fn releaseBlockingCount(self: Backend) usize {
        var total: usize = 0;
        for (self.capabilities) |capability| {
            if (capability.blocks_release and !capability.status.canBecomeReleaseSupport()) total += 1;
        }
        return total;
    }

    pub fn find(self: Backend, name: []const u8) ?Capability {
        for (self.capabilities) |capability| {
            if (std.mem.eql(u8, capability.name, name)) return capability;
        }
        return null;
    }
};

pub const native_backend_name = "native-process";

/// The core's baseline description of the native execution family.
///
/// Deliberately carries **no** capability claims: the core must not invent
/// enforcement on a backend's behalf. A backend supplies its own measured table
/// (see `src/exec/native.zig`), and `jckg doctor` reports that table.
pub fn nativeProcessBackend() Backend {
    return .{
        .name = native_backend_name,
        .family = "execution",
        .isolation_boundary = "same user account, same filesystem view, and same network access as the client process; no sandbox is claimed",
        .capabilities = &.{},
    };
}
