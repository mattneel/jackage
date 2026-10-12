//! Dependency and toolchain provenance for the audit (case AUD-007).
//!
//! The audit records how each external input is pinned and what licence state
//! it is in. Unknown inputs stay unknown: the audit never invents a version or
//! a digest for something it did not observe.
const std = @import("std");

pub const Dependency = struct {
    name: []const u8,
    has_url: bool,
    has_hash: bool,
    has_path: bool,
};

pub const Provenance = struct {
    /// Declared package dependencies in `build.zig.zon`.
    dependencies: []Dependency,
    /// Toolchain download template from `scripts/fetch-zig.ps1`.
    toolchain_url: []const u8,
    /// Archive digest pinned by the bootstrap script, when present.
    toolchain_sha256: ?[64]u8,
    /// Licence files found in the checkout, relative POSIX paths.
    license_files: [][]const u8,
    /// Project-level licence, or null when the checkout declares none.
    project_license: ?[]const u8,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Provenance) void {
        for (self.dependencies) |dependency| self.gpa.free(dependency.name);
        self.gpa.free(self.dependencies);
        self.gpa.free(self.toolchain_url);
        for (self.license_files) |file| self.gpa.free(file);
        self.gpa.free(self.license_files);
        if (self.project_license) |license| self.gpa.free(license);
        self.* = undefined;
    }

    pub fn dependencyCount(self: Provenance) usize {
        return self.dependencies.len;
    }
};

pub const Error = error{
    MissingInput,
    UnreadableInput,
    InvalidZon,
};

/// Candidate project-level licence file names, in preference order.
const project_license_candidates = [_][]const u8{
    "LICENSE", "LICENSE.md", "LICENSE.txt", "COPYING", "COPYING.md", "NOTICE",
};

/// Licence files that ship with bootstrap inputs and are recorded separately
/// from the project's own licence.
const bootstrap_license_candidates = [_][]const u8{
    "tools/zig/LICENSE",
};

fn isNameChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.';
}

/// Parses the `.dependencies` table of a `build.zig.zon` source text.
///
/// The scanner is deliberately small: it strips line comments, finds the
/// dependencies block by brace matching, then reads top-level entry names and
/// the `url`/`hash`/`path` keys inside each entry. Anything it does not
/// understand is left out instead of being guessed.
pub fn parseDependencies(
    gpa: std.mem.Allocator,
    zon_source: []const u8,
) (std.mem.Allocator.Error || Error)![]Dependency {
    const stripped = try stripLineComments(gpa, zon_source);
    defer gpa.free(stripped);

    var dependencies: std.ArrayList(Dependency) = .empty;
    errdefer {
        for (dependencies.items) |dependency| gpa.free(dependency.name);
        dependencies.deinit(gpa);
    }

    const marker = ".dependencies";
    const marker_index = std.mem.indexOf(u8, stripped, marker) orelse return try dependencies.toOwnedSlice(gpa);
    const after_marker = stripped[marker_index + marker.len ..];

    const open_relative = std.mem.indexOfScalar(u8, after_marker, '{') orelse return error.InvalidZon;
    var depth: usize = 0;
    var block_end: ?usize = null;
    for (after_marker[open_relative..], open_relative..) |byte, index| {
        if (byte == '{') depth += 1;
        if (byte == '}') {
            depth -= 1;
            if (depth == 0) {
                block_end = index;
                break;
            }
        }
    }
    const end = block_end orelse return error.InvalidZon;
    const block = after_marker[open_relative + 1 .. end];

    // Walk the block line by line, tracking brace depth so that only the
    // top-level entry names become dependencies.
    var entry_depth: usize = 0;
    var current: ?usize = null;
    var lines = std.mem.splitScalar(u8, block, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        if (entry_depth == 0) {
            if (std.mem.indexOf(u8, trimmed, "= .{")) |assign| {
                const raw_name = std.mem.trim(u8, trimmed[0..assign], " \t\r");
                // Package table entries are written `.name = .{ ... }`, while
                // field lines inside an entry (`url`, `hash`, `path`) are plain
                // assignments, so only the `.name = .{` shape starts an entry.
                if (raw_name.len > 0 and (raw_name[0] == '.' or isNameChar(raw_name[0]))) {
                    const without_dot = if (raw_name[0] == '.') raw_name[1..] else raw_name;
                    const name = if (without_dot.len >= 2 and without_dot[0] == '"')
                        without_dot[1 .. without_dot.len - 1]
                    else
                        without_dot;
                    if (name.len == 0) continue;
                    try dependencies.append(gpa, .{
                        .name = try gpa.dupe(u8, name),
                        .has_url = false,
                        .has_hash = false,
                        .has_path = false,
                    });
                    current = dependencies.items.len - 1;
                }
            }
        } // if (entry_depth == 0)

        // Field keys are read on every line that belongs to an entry, including
        // the entry's own line when it is written inline (`.x = .{ .path = "p" }`).
        if (current) |index| {
            if (std.mem.indexOf(u8, trimmed, ".url ") != null) dependencies.items[index].has_url = true;
            if (std.mem.indexOf(u8, trimmed, ".url=") != null) dependencies.items[index].has_url = true;
            if (std.mem.indexOf(u8, trimmed, ".hash ") != null) dependencies.items[index].has_hash = true;
            if (std.mem.indexOf(u8, trimmed, ".hash=") != null) dependencies.items[index].has_hash = true;
            if (std.mem.indexOf(u8, trimmed, ".path ") != null) dependencies.items[index].has_path = true;
            if (std.mem.indexOf(u8, trimmed, ".path=") != null) dependencies.items[index].has_path = true;
        }

        for (trimmed) |byte| {
            if (byte == '{') entry_depth += 1;
            if (byte == '}') {
                if (entry_depth > 0) entry_depth -= 1;
                if (entry_depth == 0) current = null;
            }
        }
    }

    return try dependencies.toOwnedSlice(gpa);
}

fn stripLineComments(gpa: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, source, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(gpa, '\n');
        first = false;
        const comment = std.mem.indexOf(u8, line, "//");
        const kept = if (comment) |index| line[0..index] else line;
        try out.appendSlice(gpa, kept);
    }
    return out.toOwnedSlice(gpa);
}

/// Finds a 64-hex SHA-256 literal assigned to `$<name>` in a PowerShell script.
pub fn parsePowerShellSha256(source: []const u8, name: []const u8) ?[64]u8 {
    var buffer: [96]u8 = undefined;
    const needle = std.mem.print(&buffer, "${s}", .{name}) catch return null;
    const assignment = std.mem.indexOf(u8, source, needle) orelse return null;
    const rest = source[assignment + needle.len ..];
    const quote_index = std.mem.indexOfScalar(u8, rest, '\'') orelse std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    const quote = rest[quote_index];
    const body_start = quote_index + 1;
    if (rest.len < body_start + 64) return null;
    const candidate = rest[body_start .. body_start + 64];
    const closing = rest[body_start + 64];
    if (closing != quote and !std.ascii.isWhitespace(closing)) return null;
    var out: [64]u8 = undefined;
    for (candidate, 0..) |character, index| {
        const lower = std.ascii.toLower(character);
        if (!std.ascii.isHex(lower)) return null;
        out[index] = lower;
    }
    return out;
}

/// Finds the download template assigned to `$<name>` in a PowerShell script.
pub fn parsePowerShellString(
    gpa: std.mem.Allocator,
    source: []const u8,
    name: []const u8,
) std.mem.Allocator.Error!?[]u8 {
    var buffer: [96]u8 = undefined;
    const needle = std.mem.print(&buffer, "${s}", .{name}) catch return null;
    const assignment = std.mem.indexOf(u8, source, needle) orelse return null;
    const rest = source[assignment + needle.len ..];
    const quote_index = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    const body_start = quote_index + 1;
    const end = std.mem.indexOfScalar(u8, rest[body_start..], '"') orelse return null;
    return try gpa.dupe(u8, rest[body_start .. body_start + end]);
}

fn fileExists(io: std.Io, dir: std.Io.Dir, path: []const u8) bool {
    _ = dir.statFile(io, path, .{}) catch return false;
    return true;
}

/// Empty provenance, used when the declared inputs are not present. Unknown
/// inputs stay unknown; nothing is invented.
pub fn empty(gpa: std.mem.Allocator) std.mem.Allocator.Error!Provenance {
    return .{
        .dependencies = try gpa.alloc(Dependency, 0),
        .toolchain_url = try gpa.dupe(u8, ""),
        .toolchain_sha256 = null,
        .license_files = try gpa.alloc([]const u8, 0),
        .project_license = null,
        .gpa = gpa,
    };
}

/// Inspects the checkout's declared inputs.
pub fn inspect(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir) !Provenance {
    const zon_source = dir.readFileAlloc(io, "build.zig.zon", gpa, .unlimited) catch return error.MissingInput;
    defer gpa.free(zon_source);
    const bootstrap_source = dir.readFileAlloc(io, "scripts/fetch-zig.ps1", gpa, .unlimited) catch return error.MissingInput;
    defer gpa.free(bootstrap_source);

    const dependencies = try parseDependencies(gpa, zon_source);
    errdefer {
        for (dependencies) |dependency| gpa.free(dependency.name);
        gpa.free(dependencies);
    }

    const toolchain_url = try parsePowerShellString(gpa, bootstrap_source, "Url") orelse return error.MissingInput;
    errdefer gpa.free(toolchain_url);

    var licenses: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (licenses.items) |file| gpa.free(file);
        licenses.deinit(gpa);
    }
    var project_license: ?[]const u8 = null;
    for (project_license_candidates) |candidate| {
        if (fileExists(io, dir, candidate)) {
            const owned = try gpa.dupe(u8, candidate);
            if (project_license == null) {
                project_license = owned;
            } else {
                try licenses.append(gpa, owned);
            }
        }
    }
    for (bootstrap_license_candidates) |candidate| {
        if (fileExists(io, dir, candidate)) {
            try licenses.append(gpa, try gpa.dupe(u8, candidate));
        }
    }

    return .{
        .dependencies = dependencies,
        .toolchain_url = toolchain_url,
        .toolchain_sha256 = parsePowerShellSha256(bootstrap_source, "Sha256"),
        .license_files = try licenses.toOwnedSlice(gpa),
        .project_license = project_license,
        .gpa = gpa,
    };
}

/// The digest pinned by the bootstrap script for the supplied compiler build.
/// Recorded here for the audit record only; it is not a fresh observation.
pub const recorded_compiler_archive_sha256 = "ec5d64aae44b54ce8425ecd7b40f1fa5c8061d1dc80939b02ed036513d69ae67";

test "m00/AUD-007 inspect dependency provenance" {
    std.debug.print("JCKG_EVIDENCE AUD-007\n", .{});
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    var provenance = try inspect(io, gpa, cwd);
    defer provenance.deinit();

    // The checkout declares no package dependencies at all.
    try std.testing.expectEqual(@as(usize, 0), provenance.dependencyCount());
    try std.testing.expect(std.mem.indexOf(u8, provenance.toolchain_url, "ziglang.org/builds") != null);
    const pinned = provenance.toolchain_sha256 orelse return error.MissingToolchainPin;
    try std.testing.expectEqualStrings(recorded_compiler_archive_sha256, pinned[0..]);

    // No project licence exists yet: a gap is recorded, not invented.
    try std.testing.expect(provenance.project_license == null);

    // The Windows bootstrap toolchain ships its own licence inside the
    // checkout; the declared Linux environment keeps its toolchain outside the
    // checkout, so the expectation follows the directory rather than the
    // platform - and the absence is asserted just as explicitly.
    const toolchain_license_present = if (std.Io.Dir.cwd().statFile(io, "tools/zig/LICENSE", .{})) |_| true else |_| false;
    var saw_bootstrap_license = false;
    for (provenance.license_files) |file| {
        if (std.mem.eql(u8, file, "tools/zig/LICENSE")) saw_bootstrap_license = true;
    }
    if (toolchain_license_present) {
        try std.testing.expect(saw_bootstrap_license);
    } else {
        try std.testing.expect(!saw_bootstrap_license);
    }

    // The table parser is exercised against a fixture that does declare
    // dependencies, so an empty result cannot pass by accident.
    const fixture =
        \\.{
        \\    .name = .probe,
        \\    .dependencies = .{
        \\        // .commented = .{ .url = "https://example.invalid/old.tar.gz", .hash = "old" },
        \\        .remote = .{
        \\            .url = "https://example.invalid/real.tar.gz",
        \\            .hash = "sha256-AAAA",
        \\        },
        \\        .vendored = .{ .path = "vendor/local" },
        \\    },
        \\}
    ;
    const fixture_deps = try parseDependencies(gpa, fixture);
    defer {
        for (fixture_deps) |dependency| gpa.free(dependency.name);
        gpa.free(fixture_deps);
    }
    try std.testing.expectEqual(@as(usize, 2), fixture_deps.len);
    try std.testing.expectEqualStrings("remote", fixture_deps[0].name);
    try std.testing.expect(fixture_deps[0].has_url);
    try std.testing.expect(fixture_deps[0].has_hash);
    try std.testing.expect(!fixture_deps[0].has_path);
    try std.testing.expectEqualStrings("vendored", fixture_deps[1].name);
    try std.testing.expect(fixture_deps[1].has_path);
    try std.testing.expect(!fixture_deps[1].has_url);

    // Negative-or-recovery: an unverifiable or malformed pin yields no digest.
    try std.testing.expect(parsePowerShellSha256(fixture, "Sha256") == null);
    try std.testing.expect(parsePowerShellSha256("$Sha256 = '1234'", "Sha256") == null);
    try std.testing.expect(parsePowerShellSha256("$Sha256 = 'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz'", "Sha256") == null);
    try std.testing.expect(parsePowerShellSha256("$Other = 'ec5d64aae44b54ce8425ecd7b40f1fa5c8061d1dc80939b02ed036513d69ae67'", "Sha256") == null);

    // A missing input file is an error, not an empty success.
    try std.testing.expectError(error.MissingInput, inspect(io, gpa, std.Io.Dir.cwd().openDir(io, "src", .{}) catch return error.MissingInput));
}
