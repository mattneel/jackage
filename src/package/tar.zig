//! Deterministic tar writing (M10, PACK-003).
//!
//! A tar header carries a great deal of host state: mode, owner, group, times, and
//! the device numbers of the filesystem it came from. Every one of those is a way
//! for two builds of the same tree to differ, so this writer takes them from the
//! *declaration*:
//!
//! - mode is declared per entry (an executable file says so, and nothing else
//!   becomes executable by accident);
//! - mtime is declared, defaulting to the epoch rather than to the file's own time;
//! - uid/gid are zero and uname/gname are a fixed value, so an archive does not
//!   record which human built it;
//! - the format is ustar with a POSIX magic, and long paths are refused rather than
//!   silently split, because a silently different layout is worse than a refusal.
//!
//! Supported links are symbolic links with a relative target: a link that escapes
//! the tree is refused, and a hard link would claim an identity the archive cannot
//! prove.
const std = @import("std");

pub const Error = error{
    UnsortedEntries,
    DuplicateEntry,
    InvalidEntryName,
    UnsafeLinkTarget,
    NameTooLong,
    OutOfMemory,
    WriteFailed,
};

pub const Policy = struct {
    /// Owner and group recorded for every entry. Fixed, not the builder's.
    uid: u32 = 0,
    gid: u32 = 0,
    uname: []const u8 = "root",
    gname: []const u8 = "root",
    /// Time recorded when an entry does not declare one.
    default_mtime: u64 = 0,
    /// Accept names of the form `./component`, which the Debian control tar
    /// requires for its own members. Payload archives leave this off, so their name
    /// policy stays strict: an allowance has to be asked for, not inherited.
    allow_leading_dot_slash: bool = false,
};

pub const Kind = enum { file, directory, symlink };

pub const Entry = struct {
    name: []const u8,
    kind: Kind,
    /// File contents; empty for directories and links.
    data: []const u8 = "",
    /// Permission bits, declared. Directories default to 0o755, files to 0o644.
    mode: ?u32 = null,
    /// Declared time; when null the policy's default is used.
    mtime: ?u64 = null,
    /// Link target for `symlink` entries; must stay inside the tree.
    link_target: []const u8 = "",

    pub fn effectiveMode(self: Entry) u32 {
        if (self.mode) |mode| return mode;
        return switch (self.kind) {
            .directory => 0o755,
            .file, .symlink => 0o644,
        };
    }

    pub fn kindFlag(self: Entry) u8 {
        return switch (self.kind) {
            .file => '0',
            .directory => '5',
            .symlink => '2',
        };
    }
};

/// True when the name is safe for a portable archive, and short enough for ustar
/// without a prefix split.
pub fn portableName(name: []const u8) bool {
    if (name.len == 0 or name.len > 100) return false;
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

/// True when a link target stays inside the tree it is written into.
///
/// `entry_depth` is how deep the *link itself* sits, since a target is interpreted
/// relative to the link's own directory: `../bin/jckg` from `a/link` stays inside the
/// tree, while the same target from a link at the root does not.
pub fn portableLinkTarget(target: []const u8, entry_depth: isize) bool {
    if (target.len == 0 or target.len > 100) return false;
    if (target[0] == '/') return false;
    if (std.mem.indexOfScalar(u8, target, 0) != null) return false;
    // Depth never goes negative: "a/../../b" leaves the tree even though it has no
    // leading slash, and that is exactly the shape a traversal uses.
    var depth: isize = entry_depth;
    var components = std.mem.splitScalar(u8, target, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            depth -= 1;
            if (depth < 0) return false;
            continue;
        }
        depth += 1;
    }
    return depth >= 0;
}

fn writeOctal(buffer: []u8, value: u64) void {
    // Zero-padded octal with a trailing NUL, which is what ustar readers expect.
    var remaining = value;
    var index = buffer.len - 1;
    buffer[index] = 0;
    while (index > 0) {
        index -= 1;
        buffer[index] = '0' + @as(u8, @intCast(remaining & 0o7));
        remaining >>= 3;
    }
}

fn writeString(target: []u8, text: []const u8) void {
    @memset(target, 0);
    const length = @min(target.len, text.len);
    @memcpy(target[0..length], text[0..length]);
}

fn header(out: *std.Io.Writer, entry: Entry, policy: Policy) Error!void {
    var block: [512]u8 = @splat(0);
    writeString(block[0..100], entry.name);
    writeOctal(block[100..108], entry.effectiveMode());
    writeOctal(block[108..116], policy.uid);
    writeOctal(block[116..124], policy.gid);
    const size: u64 = if (entry.kind == .file) entry.data.len else 0;
    writeOctal(block[124..136], size);
    writeOctal(block[136..148], entry.mtime orelse policy.default_mtime);
    // The checksum field is spaces while the checksum is computed.
    @memset(block[148..156], ' ');
    block[156] = entry.kindFlag();
    if (entry.kind == .symlink) writeString(block[157..257], entry.link_target);
    writeString(block[257..263], "ustar\x00");
    writeString(block[263..265], "00");
    writeString(block[265..297], policy.uname);
    writeString(block[297..329], policy.gname);

    var sum: u32 = 0;
    for (block) |byte| sum += byte;
    // Six octal digits, NUL, space - the one header field with that shape.
    const index: usize = 148;
    var digits: [6]u8 = undefined;
    var remaining = sum;
    var digit_index: usize = digits.len;
    while (digit_index > 0) {
        digit_index -= 1;
        digits[digit_index] = '0' + @as(u8, @intCast(remaining & 0o7));
        remaining >>= 3;
    }
    @memcpy(block[index .. index + 6], &digits);
    block[index + 6] = 0;
    block[index + 7] = ' ';

    out.writeAll(&block) catch return error.WriteFailed;
}

/// Builds the archive: entries must already be sorted by name and unique, so the
/// byte order is a property of the declaration.
pub fn build(gpa: std.mem.Allocator, entries: []const Entry, policy: Policy, out: *std.Io.Writer) Error!void {
    _ = gpa;
    for (entries, 0..) |entry, index| {
        const name_ok = if (policy.allow_leading_dot_slash and std.mem.startsWith(u8, entry.name, "./"))
            portableName(entry.name[2..])
        else
            portableName(entry.name);
        if (!name_ok) return error.InvalidEntryName;
        if (entry.kind == .symlink) {
            // The link's own directory depth, so a relative target is judged from
            // where the link actually is.
            var depth: isize = 0;
            if (std.mem.lastIndexOfScalar(u8, entry.name, '/')) |slash| {
                var components = std.mem.splitScalar(u8, entry.name[0..slash], '/');
                while (components.next()) |component| {
                    if (component.len > 0) depth += 1;
                }
            }
            if (!portableLinkTarget(entry.link_target, depth)) return error.UnsafeLinkTarget;
        }
        if (index > 0) {
            const previous = entries[index - 1];
            const order = std.mem.order(u8, previous.name, entry.name);
            if (order == .eq) return error.DuplicateEntry;
            if (order == .gt) return error.UnsortedEntries;
        }
    }

    for (entries) |entry| {
        try header(out, entry, policy);
        if (entry.kind == .file and entry.data.len > 0) {
            out.writeAll(entry.data) catch return error.WriteFailed;
            const padding = (512 - (entry.data.len % 512)) % 512;
            if (padding > 0) {
                const zeros: [512]u8 = @splat(0);
                out.writeAll(zeros[0..padding]) catch return error.WriteFailed;
            }
        }
    }

    // Two zero blocks end the archive.
    const terminator: [1024]u8 = @splat(0);
    out.writeAll(&terminator) catch return error.WriteFailed;
}

pub fn buildAlloc(gpa: std.mem.Allocator, entries: []const Entry, policy: Policy) Error![]u8 {
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    errdefer buffer.deinit();
    try build(gpa, entries, policy, &buffer.writer);
    return buffer.toOwnedSlice();
}

test "m10/PACK-003 build deterministic tar: metadata policy and bytes repeat" {
    std.debug.print("JCKG_EVIDENCE PACK-003\n", .{});
    const gpa = std.testing.allocator;
    const policy = Policy{};

    // A tree with an executable file, a directory, and a symbolic link - the three
    // shapes the case names.
    const tree = [_]Entry{
        .{ .name = "bin", .kind = .directory },
        .{ .name = "bin/jckg", .kind = .file, .data = "client payload\n", .mode = 0o755 },
        .{ .name = "bin/jckg-current", .kind = .symlink, .link_target = "jckg" },
    };

    const first = try buildAlloc(gpa, &tree, policy);
    defer gpa.free(first);
    const second = try buildAlloc(gpa, &tree, policy);
    defer gpa.free(second);
    try std.testing.expectEqualSlices(u8, first, second);

    // The metadata policy is carried in the bytes, not read from the host: the
    // archive records the declared mode (0755), a zero owner, and the policy's
    // default time (the epoch), and it does not end with the builder's name.
    try std.testing.expect(std.mem.indexOf(u8, first, "0000755\x00") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "0000000\x00") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "ustar") != null);
    const terminator: [1024]u8 = @splat(0);
    try std.testing.expect(std.mem.endsWith(u8, first, &terminator));

    // A declared mode change changes the bytes, which is what makes the policy
    // meaningful rather than decorative.
    var changed = tree;
    changed[1].mode = 0o700;
    const changed_bytes = try buildAlloc(gpa, &changed, policy);
    defer gpa.free(changed_bytes);
    try std.testing.expect(!std.mem.eql(u8, first, changed_bytes));

    // Negative-or-recovery: a link that escapes the tree is refused, including the
    // shape that has no leading slash but still climbs out.
    const escaping = [_]Entry{.{ .name = "link", .kind = .symlink, .link_target = "../../etc/passwd" }};
    try std.testing.expectError(error.UnsafeLinkTarget, buildAlloc(gpa, &escaping, policy));
    const absolute_link = [_]Entry{.{ .name = "link", .kind = .symlink, .link_target = "/etc/passwd" }};
    try std.testing.expectError(error.UnsafeLinkTarget, buildAlloc(gpa, &absolute_link, policy));
    const climbing = [_]Entry{.{ .name = "a/link", .kind = .symlink, .link_target = "../../../etc/passwd" }};
    try std.testing.expectError(error.UnsafeLinkTarget, buildAlloc(gpa, &climbing, policy));
    // A relative target that stays inside is supported, judged from the link's own
    // directory rather than from the archive root.
    const internal_link = [_]Entry{.{ .name = "a/link", .kind = .symlink, .link_target = "../bin/jckg" }};
    const linked = try buildAlloc(gpa, &internal_link, policy);
    defer gpa.free(linked);
    try std.testing.expect(linked.len > 0);

    // The same refusals as the ZIP writer: traversal, absolute paths, duplicates,
    // and unsorted input, because the archive's byte order is the declaration's.
    const unsafe = [_]Entry{.{ .name = "../escape", .kind = .file, .data = "x" }};
    try std.testing.expectError(error.InvalidEntryName, buildAlloc(gpa, &unsafe, policy));
    const unsorted = [_]Entry{
        .{ .name = "b", .kind = .file, .data = "1" },
        .{ .name = "a", .kind = .file, .data = "2" },
    };
    try std.testing.expectError(error.UnsortedEntries, buildAlloc(gpa, &unsorted, policy));
    const duplicate = [_]Entry{
        .{ .name = "a", .kind = .file, .data = "1" },
        .{ .name = "a", .kind = .file, .data = "2" },
    };
    try std.testing.expectError(error.DuplicateEntry, buildAlloc(gpa, &duplicate, policy));
}
