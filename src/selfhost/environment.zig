//! Realizing the environment a self-hosted build runs in (M09, SELF-001).
//!
//! A locked recipe declares the tools a build needs. "Realizing" the environment
//! means making those tools present *and* proving that what is present is what was
//! declared: a tool is realized only when its bytes match the digest recorded for
//! it, and the two failure shapes are reported separately because they call for
//! different responses.
//!
//! - **Missing** - the tool is not there. Fetch or build it; the environment is not
//!   usable yet.
//! - **Mismatch** - something is there and it is not the declared tool. This is the
//!   serious one: it is either a substituted toolchain or a corrupted artifact, and
//!   a build that proceeds will produce digests nobody can compare with anything.
//!
//! Nothing here invents a tool: a source that is not declared cannot be realized,
//! and an undeclared tool found in place is reported rather than blessed.
const std = @import("std");

pub const Error = error{
    UndeclaredTool,
    OutOfMemory,
    WriteFailed,
};

/// Where a declared tool comes from. Both variants are external inputs; neither is
/// "whatever happened to be installed".
pub const Origin = enum {
    /// Fetched from a recorded URL and verified against a recorded digest.
    fetched,
    /// Shipped with the checkout (vendored sources the build compiles directly).
    vendored,
};

pub const Tool = struct {
    /// How the recipe names it, and the relative path it must exist at.
    name: []const u8,
    origin: Origin,
    /// Lowercase hex SHA-256 of the tool's payload.
    sha256: []const u8,
};

pub const Status = enum {
    /// Present and byte-identical to the declaration.
    realized,
    /// Absent.
    missing,
    /// Present, but not the declared bytes.
    mismatch,
};

pub const Finding = struct {
    tool: Tool,
    status: Status,
    /// The digest actually measured, when something was there.
    measured: ?[64]u8 = null,
};

pub const Report = struct {
    findings: []Finding,

    pub fn deinit(self: Report, gpa: std.mem.Allocator) void {
        gpa.free(self.findings);
    }

    /// True when every declared tool is present and matches.
    pub fn realized(self: Report) bool {
        for (self.findings) |finding| {
            if (finding.status != .realized) return false;
        }
        return true;
    }

    pub fn countOf(self: Report, status: Status) usize {
        var total: usize = 0;
        for (self.findings) |finding| {
            if (finding.status == status) total += 1;
        }
        return total;
    }
};

fn digestOfPath(io: std.Io, dir: std.Io.Dir, path: []const u8) !?[64]u8 {
    const file = dir.openFile(io, path, .{}) catch return null;
    defer file.close(io);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    while (true) {
        const read = reader.interface.readSliceShort(&buffer) catch return null;
        if (read == 0) break;
        hasher.update(buffer[0..read]);
    }
    var raw: [32]u8 = undefined;
    hasher.final(&raw);
    return std.fmt.bytesToHex(raw, .lower);
}

/// Checks every declared tool against what is actually present under `root`.
///
/// The report is exhaustive rather than fail-fast: a caller fixing an environment
/// wants the whole list, not the first problem.
pub fn realize(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    tools: []const Tool,
) !Report {
    const findings = try gpa.alloc(Finding, tools.len);
    errdefer gpa.free(findings);

    for (tools, 0..) |tool, index| {
        const measured = try digestOfPath(io, root, tool.name);
        if (measured == null) {
            findings[index] = .{ .tool = tool, .status = .missing };
            continue;
        }
        const status: Status = if (std.mem.eql(u8, &measured.?, tool.sha256)) .realized else .mismatch;
        findings[index] = .{ .tool = tool, .status = status, .measured = measured };
    }
    return .{ .findings = findings };
}

/// Refuses a tool that the recipe did not declare.
///
/// An environment is realized from a declaration; accepting an undeclared tool
/// would make the environment depend on something the lock does not describe, and
/// the build would be reproducible only by accident.
pub fn requireDeclared(tools: []const Tool, name: []const u8) Error!Tool {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool;
    }
    return error.UndeclaredTool;
}

test "m09/SELF-001 realize own environment: every tool comes from a declared verified input" {
    std.debug.print("JCKG_EVIDENCE SELF-001\n", .{});
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const root_path = "zig-out/jckg-env";
    cwd.deleteTree(io, root_path) catch {};
    defer cwd.deleteTree(io, root_path) catch {};
    var root = try cwd.createDirPathOpen(io, root_path, .{ .open_options = .{ .iterate = true } });
    defer root.close(io);

    // The declared environment: a fetched compiler and a vendored source tree,
    // each with the digest the recipe records.
    const compiler_bytes = "compiler payload\n";
    const vendor_bytes = "vendored source payload\n";
    const compiler_digest = comptimeHash(compiler_bytes);
    const vendor_digest = comptimeHash(vendor_bytes);

    try root.createDirPath(io, "tools");
    try root.writeFile(io, .{ .sub_path = "tools/zig", .data = compiler_bytes });
    try root.createDirPath(io, "vendor");
    try root.writeFile(io, .{ .sub_path = "vendor/quickjs-ng", .data = vendor_bytes });

    const tools = [_]Tool{
        .{ .name = "tools/zig", .origin = .fetched, .sha256 = &compiler_digest },
        .{ .name = "vendor/quickjs-ng", .origin = .vendored, .sha256 = &vendor_digest },
    };

    // Everything declared is present and matches: the environment is realized.
    const report = try realize(io, gpa, root, &tools);
    defer report.deinit(gpa);
    try std.testing.expect(report.realized());
    try std.testing.expectEqual(@as(usize, 2), report.countOf(.realized));

    // A missing tool is reported as missing, and the environment is not realized.
    try root.deleteFile(io, "tools/zig");
    const absent = try realize(io, gpa, root, &tools);
    defer absent.deinit(gpa);
    try std.testing.expect(!absent.realized());
    try std.testing.expectEqual(@as(usize, 1), absent.countOf(.missing));

    // A tool that is present but is not the declared bytes is a *mismatch*, kept
    // distinct from missing: one says "fetch it", the other says "something is not
    // what the recipe says it is", and a build must not proceed on the second.
    try root.writeFile(io, .{ .sub_path = "tools/zig", .data = "substituted compiler\n" });
    const wrong = try realize(io, gpa, root, &tools);
    defer wrong.deinit(gpa);
    try std.testing.expect(!wrong.realized());
    try std.testing.expectEqual(@as(usize, 1), wrong.countOf(.mismatch));
    try std.testing.expectEqual(@as(usize, 1), wrong.countOf(.realized));
    const mismatch = wrong.findings[0];
    try std.testing.expect(mismatch.measured != null);
    try std.testing.expect(!std.mem.eql(u8, &mismatch.measured.?, &compiler_digest));

    // An undeclared tool is refused rather than accepted into the environment.
    try std.testing.expectError(error.UndeclaredTool, requireDeclared(&tools, "tools/some-other-zig"));
    _ = try requireDeclared(&tools, "tools/zig");
}

/// SHA-256 of a comptime-known string, so the test's declarations are derived
/// rather than pasted (a pasted digest can be wrong and still look authoritative).
fn comptimeHash(comptime text: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}
