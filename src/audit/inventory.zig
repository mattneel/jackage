//! Inventory of the existing source tree (audit case AUD-004).
//!
//! The audit must list what already exists before any edit, including the
//! digest of each file, so a later change to an unrelated file is detectable
//! and so "no replacement scaffold appeared" is a checkable statement.
const std = @import("std");

pub const SourceFile = struct {
    /// Checkout-relative POSIX path, for example `src/main.zig`.
    path: []const u8,
    size_bytes: u64,
    sha256_hex: [64]u8,
    test_blocks: u32,
};

pub const Inventory = struct {
    files: []SourceFile,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Inventory) void {
        for (self.files) |file| self.gpa.free(file.path);
        self.gpa.free(self.files);
        self.* = undefined;
    }

    pub fn totalBytes(self: Inventory) u64 {
        var total: u64 = 0;
        for (self.files) |file| total += file.size_bytes;
        return total;
    }

    pub fn totalTestBlocks(self: Inventory) u32 {
        var total: u32 = 0;
        for (self.files) |file| total += file.test_blocks;
        return total;
    }

    pub fn find(self: Inventory, path: []const u8) ?SourceFile {
        for (self.files) |file| {
            if (std.mem.eql(u8, file.path, path)) return file;
        }
        return null;
    }
};

/// An empty inventory, used when the source root is absent.
pub fn empty(gpa: std.mem.Allocator) std.mem.Allocator.Error!Inventory {
    return .{ .files = try gpa.alloc(SourceFile, 0), .gpa = gpa };
}

/// Lowercase hex SHA-256 of `bytes`.
pub fn digestHex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Counts Zig `test` declarations in a source file.
///
/// A line counts when, after leading whitespace, it opens with `test "` or
/// `test {`. Text inside strings or comments is not treated as a declaration.
pub fn countTestBlocks(source: []const u8) u32 {
    var count: u32 = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "test \"") or std.mem.startsWith(u8, trimmed, "test{")) {
            count += 1;
        } else if (std.mem.startsWith(u8, trimmed, "test {")) {
            count += 1;
        }
    }
    return count;
}

/// Scans `sub_path` under `dir` for Zig sources and reports each one.
pub fn scan(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, sub_path: []const u8) !Inventory {
    var sub = try dir.openDir(io, sub_path, .{ .iterate = true });
    defer sub.close(io);

    var files: std.ArrayList(SourceFile) = .empty;
    errdefer {
        for (files.items) |file| gpa.free(file.path);
        files.deinit(gpa);
    }

    var walker = try sub.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, std.fs.path.extension(entry.path), ".zig")) continue;

        const bytes = try sub.readFileAlloc(io, entry.path, gpa, .unlimited);
        defer gpa.free(bytes);

        const joined = try std.fs.path.join(gpa, &.{ sub_path, entry.path });
        defer gpa.free(joined);
        const portable = try gpa.dupe(u8, joined);
        for (portable) |*character| {
            if (character.* == '\\') character.* = '/';
        }

        try files.append(gpa, .{
            .path = portable,
            .size_bytes = bytes.len,
            .sha256_hex = digestHex(bytes),
            .test_blocks = countTestBlocks(bytes),
        });
    }

    std.mem.sortUnstable(SourceFile, files.items, {}, lessByPath);
    return .{ .files = try files.toOwnedSlice(gpa), .gpa = gpa };
}

fn lessByPath(_: void, a: SourceFile, b: SourceFile) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

test "AUD-004 map the existing implementation" {
    std.debug.print("JCKG_EVIDENCE AUD-004\n", .{});
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    var inv = try scan(io, gpa, cwd, "src");
    defer inv.deinit();

    // The scaffold's two modules must still be present, byte for byte.
    const main = inv.find("src/main.zig") orelse return error.MissingScaffoldModule;
    const root = inv.find("src/root.zig") orelse return error.MissingScaffoldModule;
    try std.testing.expectEqual(@as(u64, 2615), main.size_bytes);
    try std.testing.expectEqual(@as(u64, 571), root.size_bytes);
    try std.testing.expectEqualStrings(
        "3c351e69d0c382bcf1c3f2c65a4881d8e856fb72466c536f5c9966832d181cbb",
        main.sha256_hex[0..],
    );
    try std.testing.expectEqualStrings(
        "29b924059d2cf4b3f3740a4313266aba82da9412aa57655cf7219848a4712bd3",
        root.sha256_hex[0..],
    );

    // The inventory agrees with an independent read of the same file.
    const text = try cwd.readFileAlloc(io, "src/main.zig", gpa, .unlimited);
    defer gpa.free(text);
    try std.testing.expectEqual(countTestBlocks(text), main.test_blocks);

    // The delivered scaffold carries exactly the three known test blocks.
    try std.testing.expectEqual(@as(u32, 2), main.test_blocks);
    try std.testing.expectEqual(@as(u32, 1), root.test_blocks);
    try std.testing.expect(inv.files.len >= 2);
    try std.testing.expect(inv.totalBytes() >= main.size_bytes + root.size_bytes);
    try std.testing.expect(inv.totalTestBlocks() >= 3);

    // Entries are reported in path order so the report is stable.
    var previous: ?[]const u8 = null;
    for (inv.files) |file| {
        if (previous) |prev| try std.testing.expect(std.mem.lessThan(u8, prev, file.path));
        previous = file.path;
        try std.testing.expect(file.size_bytes > 0);
        try std.testing.expect(std.mem.indexOf(u8, file.path, "\\") == null);
    }

    // Negative-or-recovery: counting must not see test names inside strings or
    // comments, and an absent module must be reported as absent.
    try std.testing.expectEqual(@as(u32, 0), countTestBlocks("const s = \"test \\\"x\\\"\";\n"));
    try std.testing.expectEqual(@as(u32, 0), countTestBlocks("// test \"commented\"\nconst x = 1;\n"));
    try std.testing.expectEqual(@as(u32, 1), countTestBlocks("test \"real\" {}\n"));
    try std.testing.expectEqual(@as(u32, 1), countTestBlocks("test {\n}\n"));
    try std.testing.expect(inv.find("src/does-not-exist.zig") == null);
}
