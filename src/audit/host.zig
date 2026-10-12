//! Host platform discovery for the audit and for `jckg doctor` (case AUD-006).
//!
//! The audit must report what the machine actually is and must label every
//! target it cannot exercise as unavailable. A cross-compiled binary, a
//! container, or an emulated host is not native evidence.
const std = @import("std");
const builtin = @import("builtin");

pub const Os = enum {
    windows,
    linux,
    macos,
    other,

    pub fn text(self: Os) []const u8 {
        return switch (self) {
            .windows => "windows",
            .linux => "linux",
            .macos => "macos",
            .other => "other",
        };
    }
};

pub const Arch = enum {
    x86_64,
    aarch64,
    other,

    pub fn text(self: Arch) []const u8 {
        return switch (self) {
            .x86_64 => "x86_64",
            .aarch64 => "aarch64",
            .other => "other",
        };
    }
};

/// A client platform tuple, restricted to the fields the audit can observe.
pub const Target = struct {
    os: Os,
    arch: Arch,

    pub fn format(self: Target, buffer: []u8) []const u8 {
        return std.mem.print(buffer, "{s}-{s}", .{ self.os.text(), self.arch.text() }) catch "invalid-target";
    }

    pub fn eql(a: Target, b: Target) bool {
        return a.os == b.os and a.arch == b.arch;
    }
};

/// Delivery targets from `PLATFORMS_PACKAGING.md`.
pub const DeliveryTarget = enum {
    windows_x86_64,
    windows_aarch64,
    linux_x86_64,
    linux_aarch64,
    macos_x86_64,
    macos_aarch64,

    pub fn target(self: DeliveryTarget) Target {
        return switch (self) {
            .windows_x86_64 => .{ .os = .windows, .arch = .x86_64 },
            .windows_aarch64 => .{ .os = .windows, .arch = .aarch64 },
            .linux_x86_64 => .{ .os = .linux, .arch = .x86_64 },
            .linux_aarch64 => .{ .os = .linux, .arch = .aarch64 },
            .macos_x86_64 => .{ .os = .macos, .arch = .x86_64 },
            .macos_aarch64 => .{ .os = .macos, .arch = .aarch64 },
        };
    }
};

pub const delivery_target_count = 6;

pub const Availability = enum {
    /// The delivery target equals the host this evidence runs on.
    native,
    /// No native host for the target was available for this session.
    unavailable,
};

pub const Support = struct {
    target: DeliveryTarget,
    availability: Availability,
    reason: []const u8,
};

pub const HostFacts = struct {
    os: Os,
    arch: Arch,
    logical_cpus: usize,
    page_size_min: usize,
    page_size_max: usize,
    executable_path: []const u8,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *HostFacts) void {
        self.gpa.free(self.executable_path);
        self.* = undefined;
    }

    pub fn target(self: HostFacts) Target {
        return .{ .os = self.os, .arch = self.arch };
    }

    /// The delivery target matching this host, when the host is one of them.
    pub fn nativeTarget(self: HostFacts) ?DeliveryTarget {
        for (std.enums.values(DeliveryTarget)) |candidate| {
            if (candidate.target().eql(self.target())) return candidate;
        }
        return null;
    }

    /// Fills `out` with a native/unavailable label for every delivery target.
    pub fn supportMatrix(self: HostFacts, out: *[delivery_target_count]Support) void {
        const native = self.nativeTarget();
        for (std.enums.values(DeliveryTarget), 0..) |candidate, index| {
            if (native != null and candidate == native.?) {
                out[index] = .{
                    .target = candidate,
                    .availability = .native,
                    .reason = "native host",
                };
            } else {
                out[index] = .{
                    .target = candidate,
                    .availability = .unavailable,
                    .reason = unavailableReason(candidate),
                };
            }
        }
    }
};

fn unavailableReason(candidate: DeliveryTarget) []const u8 {
    return switch (candidate) {
        .windows_x86_64 => "no native windows-x86_64 host was available for this session",
        .windows_aarch64 => "no native windows-aarch64 host was available for this session",
        .linux_x86_64 => "no native linux-x86_64 host was available for this session",
        .linux_aarch64 => "no native linux-aarch64 host was available for this session",
        .macos_x86_64 => "no native macos-x86_64 host was available for this session",
        .macos_aarch64 => "no native macos-aarch64 host was available for this session",
    };
}

/// Maps the compiler's build target onto the audit's platform vocabulary.
pub fn osFromBuiltin(tag: std.Target.Os.Tag) Os {
    return switch (tag) {
        .windows => .windows,
        .linux => .linux,
        .macos => .macos,
        else => .other,
    };
}

pub fn archFromBuiltin(arch: std.Target.Cpu.Arch) Arch {
    return switch (arch) {
        .x86_64 => .x86_64,
        .aarch64 => .aarch64,
        else => .other,
    };
}

/// Observes this process's host: target, capacity, and own executable path.
pub fn detect(io: std.Io, gpa: std.mem.Allocator) !HostFacts {
    // A sentinel-terminated allocation from `executablePathAlloc` cannot be
    // freed through a plain slice, so the path is copied into an ordinary one.
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_length = try std.process.executablePath(io, &path_buffer);
    const executable_path = try gpa.dupe(u8, path_buffer[0..path_length]);
    errdefer gpa.free(executable_path);
    const logical_cpus = std.Thread.getCpuCount() catch 1;
    return .{
        .os = osFromBuiltin(builtin.os.tag),
        .arch = archFromBuiltin(builtin.cpu.arch),
        .logical_cpus = if (logical_cpus == 0) 1 else logical_cpus,
        .page_size_min = std.heap.page_size_min,
        .page_size_max = std.heap.page_size_max,
        .executable_path = executable_path,
        .gpa = gpa,
    };
}

test "AUD-006 discover host capabilities" {
    std.debug.print("JCKG_EVIDENCE AUD-006\n", .{});
    const gpa = std.testing.allocator;

    var facts = try detect(std.testing.io, gpa);
    defer facts.deinit();

    // The observed platform must be the platform this binary was built for.
    // On the recorded case-zero host that is Windows x86_64; in the declared
    // Linux execution environment it must honestly report Linux instead.
    try std.testing.expectEqual(osFromBuiltin(builtin.os.tag), facts.os);
    try std.testing.expectEqual(archFromBuiltin(builtin.cpu.arch), facts.arch);
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqual(Os.windows, facts.os);
        try std.testing.expectEqual(Arch.x86_64, facts.arch);
    } else {
        try std.testing.expectEqual(Os.linux, facts.os);
        try std.testing.expectEqual(Arch.x86_64, facts.arch);
    }
    try std.testing.expect(facts.logical_cpus >= 1);
    try std.testing.expect(facts.page_size_min >= 4096);
    try std.testing.expect(facts.page_size_max >= facts.page_size_min);
    try std.testing.expect(facts.executable_path.len > 0);
    try std.testing.expect(std.fs.path.isAbsolute(facts.executable_path));
    // Windows executables carry an extension; POSIX executables normally do not,
    // and requiring one would fail on every Linux run for the wrong reason.
    if (builtin.os.tag == .windows) {
        try std.testing.expect(std.fs.path.extension(facts.executable_path).len > 0);
    } else {
        try std.testing.expect(std.fs.path.extension(facts.executable_path).len == 0);
    }

    var buffer: [32]u8 = undefined;
    var expected_target_buffer: [32]u8 = undefined;
    const expected_target = try std.mem.print(&expected_target_buffer, "{s}-{s}", .{
        @tagName(builtin.os.tag),
        @tagName(builtin.cpu.arch),
    });
    try std.testing.expectEqualStrings(expected_target, facts.target().format(&buffer));
    const native_target = facts.nativeTarget() orelse return error.NoNativeTarget;

    // Every delivery target is labelled, and only the host target is native.
    var matrix: [delivery_target_count]Support = undefined;
    facts.supportMatrix(&matrix);
    var native_seen: usize = 0;
    for (matrix) |entry| {
        try std.testing.expect(entry.reason.len > 0);
        if (entry.availability == .native) {
            native_seen += 1;
            try std.testing.expectEqual(native_target, entry.target);
        } else {
            // Unavailable targets must say why; a bare "unsupported" is not a
            // usable honest label.
            try std.testing.expect(std.mem.indexOf(u8, entry.reason, "host") != null);
            try std.testing.expect(entry.target != native_target);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), native_seen);
}
