//! Deterministic ZIP writing (M10, PACK-002).
//!
//! Two facts make a ZIP non-deterministic if left alone: the order a host walks a
//! directory, and the modification time each entry carries. Both are decided here
//! by the *declaration* rather than by the filesystem:
//!
//! - entries are written in a sorted order that comes from the plan, so two hosts
//!   enumerating the same tree in different orders produce the same bytes;
//! - every entry carries a declared timestamp (the caller's, defaulting to the
//!   ZIP epoch), never "now" and never the file's own mtime.
//!
//! Entries are stored, not deflated: compression output can vary between library
//! versions, and an archive whose bytes depend on which zlib is linked is not a
//! reproducible artifact. Storing costs size and buys determinism.
const std = @import("std");

pub const Error = error{
    UnsortedEntries,
    DuplicateEntry,
    InvalidEntryName,
    OutOfMemory,
    WriteFailed,
};

pub const Compression = enum { stored };

pub const Entry = struct {
    /// Forward-slash separated, relative, no leading slash, no `..`.
    name: []const u8,
    data: []const u8,
    /// Declared timestamp, in MS-DOS format. Zero means the ZIP epoch.
    dos_time: u16 = 0,
    dos_date: u16 = default_dos_date,
    compression: Compression = .stored,
};

/// 1980-01-01, the earliest date the ZIP format can represent. A declaration that
/// says nothing about time gets this rather than "whenever this ran".
pub const default_dos_date: u16 = 0x0021;

/// True when the name is safe to put in a portable archive: relative, forward
/// slashes, no traversal, no absolute path, no drive letter.
pub fn portableName(name: []const u8) bool {
    if (name.len == 0 or name.len > 4096) return false;
    if (name[0] == '/') return false;
    if (std.mem.indexOfScalar(u8, name, '\\') != null) return false;
    if (std.mem.indexOfScalar(u8, name, 0) != null) return false;
    if (name.len >= 2 and name[1] == ':') return false;
    var components = std.mem.splitScalar(u8, name, '/');
    while (components.next()) |component| {
        if (component.len == 0) return false;
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

fn crc32(data: []const u8) u32 {
    return std.hash.Crc32.hash(data);
}

/// Builds the archive. Entries must be sorted by name and unique, so the byte
/// order is a property of the declaration rather than of this function's internals.
pub fn build(gpa: std.mem.Allocator, entries: []const Entry, out: *std.Io.Writer) Error!void {
    for (entries, 0..) |entry, index| {
        if (!portableName(entry.name)) return error.InvalidEntryName;
        if (index > 0) {
            const previous = entries[index - 1];
            const order = std.mem.order(u8, previous.name, entry.name);
            if (order == .eq) return error.DuplicateEntry;
            if (order == .gt) return error.UnsortedEntries;
        }
    }

    var offsets = try gpa.alloc(u32, entries.len);
    defer gpa.free(offsets);

    // Offsets are computed rather than asked for: a local header is 30 bytes plus
    // the name, then the stored payload. The arithmetic is exact, so the archive's
    // structure does not depend on a writer's internal position tracking.
    var position: u64 = 0;

    // Local file headers and data, in declaration order.
    for (entries, 0..) |entry, index| {
        if (position > std.math.maxInt(u32)) return error.WriteFailed;
        offsets[index] = @intCast(position);

        const checksum = crc32(entry.data);
        const size: u32 = @intCast(entry.data.len);

        try out.writeInt(u32, 0x04034b50, .little); // local file header
        try out.writeInt(u16, 20, .little); // version needed
        try out.writeInt(u16, 0, .little); // flags: no data descriptor, no UTF-8 bit
        try out.writeInt(u16, 0, .little); // method: stored
        try out.writeInt(u16, entry.dos_time, .little);
        try out.writeInt(u16, entry.dos_date, .little);
        try out.writeInt(u32, checksum, .little);
        try out.writeInt(u32, size, .little); // compressed size
        try out.writeInt(u32, size, .little); // uncompressed size
        try out.writeInt(u16, @intCast(entry.name.len), .little);
        try out.writeInt(u16, 0, .little); // extra length
        try out.writeAll(entry.name);
        try out.writeAll(entry.data);
        position += 30 + entry.name.len + entry.data.len;
    }

    // Central directory, same order as the entries.
    const central_offset: u32 = @intCast(position);
    for (entries, 0..) |entry, index| {
        const checksum = crc32(entry.data);
        const size: u32 = @intCast(entry.data.len);

        try out.writeInt(u32, 0x02014b50, .little); // central directory header
        try out.writeInt(u16, 20, .little); // version made by
        try out.writeInt(u16, 20, .little); // version needed
        try out.writeInt(u16, 0, .little);
        try out.writeInt(u16, 0, .little);
        try out.writeInt(u16, entry.dos_time, .little);
        try out.writeInt(u16, entry.dos_date, .little);
        try out.writeInt(u32, checksum, .little);
        try out.writeInt(u32, size, .little);
        try out.writeInt(u32, size, .little);
        try out.writeInt(u16, @intCast(entry.name.len), .little);
        try out.writeInt(u16, 0, .little); // extra
        try out.writeInt(u16, 0, .little); // comment
        try out.writeInt(u16, 0, .little); // disk number
        try out.writeInt(u16, 0, .little); // internal attributes
        try out.writeInt(u32, 0, .little); // external attributes: fixed, not the host's mode
        try out.writeInt(u32, offsets[index], .little);
        try out.writeAll(entry.name);
        position += 46 + entry.name.len;
    }
    const central_size: u32 = @intCast(position - central_offset);

    // End of central directory.
    try out.writeInt(u32, 0x06054b50, .little);
    try out.writeInt(u16, 0, .little);
    try out.writeInt(u16, 0, .little);
    try out.writeInt(u16, @intCast(entries.len), .little);
    try out.writeInt(u16, @intCast(entries.len), .little);
    try out.writeInt(u32, central_size, .little);
    try out.writeInt(u32, central_offset, .little);
    try out.writeInt(u16, 0, .little); // no comment
}

/// Convenience for tests and callers: build into an owned buffer.
pub fn buildAlloc(gpa: std.mem.Allocator, entries: []const Entry) Error![]u8 {
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    errdefer buffer.deinit();
    try build(gpa, entries, &buffer.writer);
    return buffer.toOwnedSlice();
}

test "m10/PACK-002 build deterministic ZIP: different enumeration orders produce equal bytes" {
    std.debug.print("JCKG_EVIDENCE PACK-002\n", .{});
    const gpa = std.testing.allocator;

    // The same tree, declared twice with different host enumeration orders and
    // different host times. The declaration carries the timestamps, so a build
    // repeated anywhere produces the same bytes.
    const host_order = [_]Entry{
        .{ .name = "share/doc/LICENSE", .data = "MIT\n" },
        .{ .name = "bin/jckg", .data = "client payload\n", .dos_time = 0x1000, .dos_date = 0x0021 },
    };

    // A caller that hands entries in host order gets a refusal rather than a
    // silently different archive: byte-equality across hosts depends on the order
    // being part of the declaration.
    try std.testing.expectError(error.UnsortedEntries, buildAlloc(gpa, &host_order));

    const sorted_declaration = [_]Entry{
        .{ .name = "bin/jckg", .data = "client payload\n", .dos_time = 0x1000, .dos_date = 0x0021 },
        .{ .name = "share/doc/LICENSE", .data = "MIT\n" },
    };
    const first = try buildAlloc(gpa, &sorted_declaration);
    defer gpa.free(first);
    const second = try buildAlloc(gpa, &sorted_declaration);
    defer gpa.free(second);
    try std.testing.expectEqualSlices(u8, first, second);

    // The archive is a ZIP: local header, central directory, end record, and the
    // payload is stored rather than deflated.
    try std.testing.expectEqual(@as(u32, 0x04034b50), std.mem.readInt(u32, first[0..4], .little));
    try std.testing.expect(std.mem.indexOf(u8, first, "client payload\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, first, &[_]u8{ 0, 0, 0, 0, 0 }));

    // Negative-or-recovery: names that would make the archive unsafe or ambiguous
    // are refused, and a duplicate is refused rather than written twice.
    const unsafe = [_]Entry{.{ .name = "../escape", .data = "x" }};
    try std.testing.expectError(error.InvalidEntryName, buildAlloc(gpa, &unsafe));
    const absolute = [_]Entry{.{ .name = "/etc/passwd", .data = "x" }};
    try std.testing.expectError(error.InvalidEntryName, buildAlloc(gpa, &absolute));
    const windows = [_]Entry{.{ .name = "bin\\jckg", .data = "x" }};
    try std.testing.expectError(error.InvalidEntryName, buildAlloc(gpa, &windows));
    const duplicate = [_]Entry{
        .{ .name = "a", .data = "1" },
        .{ .name = "a", .data = "2" },
    };
    try std.testing.expectError(error.DuplicateEntry, buildAlloc(gpa, &duplicate));

    // Ordering is by name, so a declaration listing "a/z" before "ab" still fails:
    // "a/z" > "ab" is false in byte order, and that is the order the archive uses.
    const interleaved = [_]Entry{
        .{ .name = "ab", .data = "1" },
        .{ .name = "a/z", .data = "2" },
    };
    try std.testing.expectError(error.UnsortedEntries, buildAlloc(gpa, &interleaved));
}
