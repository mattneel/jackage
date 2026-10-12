//! Strict portable ustar extraction (TRUST-010).
//!
//! A deliberately small header reader is used instead of std.tar.Iterator:
//! that iterator interprets PAX/GNU extensions, links and sparse entries before
//! a caller can enforce this format's bounds. Here every 512-byte header has a
//! verified checksum and strict octal fields; only ordinary files/directories
//! are accepted. Links, devices, sparse/extension records and ambiguous padding
//! are refused. This entry point does not decompress; a caller decoding an outer
//! container can supply its verified source length for the expansion bound.
//!
//! All writes use a new private sibling directory. The complete archive, tree,
//! trailer and limits must validate before a non-replacing atomic rename. A
//! rejected archive or failed extraction publishes no destination and does not
//! touch an existing destination. The parent handle must be a trusted directory;
//! the destination is a single portable component, never a path through links.
const std = @import("std");
const digest = @import("../core/digest.zig");
const tree_module = @import("../core/tree.zig");

pub const Error = error{
    InvalidLimits,
    InvalidDestination,
    InvalidHeader,
    InvalidChecksum,
    UnsupportedEntry,
    InvalidPath,
    DuplicateEntry,
    ConflictingEntry,
    TooManyEntries,
    EntryTooLarge,
    TotalSizeLimit,
    ArchiveSizeLimit,
    ExpansionLimit,
    NestingLimit,
    PathTooLong,
    TruncatedArchive,
    InvalidPadding,
    InvalidTrailer,
};

pub const Limits = struct {
    /// Counts both explicit entries and implicit parent directories.
    max_entries: usize = 4096,
    max_entry_bytes: u64 = 64 * 1024 * 1024,
    max_total_bytes: u64 = 256 * 1024 * 1024,
    /// Includes headers/padding/trailer, preventing an endless zero trailer.
    max_archive_bytes: u64 = 512 * 1024 * 1024,
    max_path_bytes: usize = 256,
    max_depth: usize = 32,
    max_expansion_ratio: u32 = 64,
    /// Optional verified outer-container length, not an archive header claim.
    /// The total extracted bytes may not exceed this times the ratio.
    source_byte_length: ?u64 = null,
};

pub const Extraction = struct {
    /// Owned, sorted portable tree, including implicit/empty directories.
    tree: tree_module.Tree,
    tree_digest: digest.Digest,
    total_bytes: u64,
    archive_bytes: u64,

    pub fn deinit(self: *Extraction) void {
        self.tree.deinit();
        self.* = undefined;
    }
};

pub fn extractBytes(gpa: std.mem.Allocator, io: std.Io, bytes: []const u8, parent: std.Io.Dir, destination: []const u8, limits: Limits) !Extraction {
    var reader = std.Io.Reader.fixed(bytes);
    return extractReader(gpa, io, &reader, parent, destination, limits);
}

/// Reads one complete, uncompressed POSIX ustar archive into a private staging
/// directory and publishes it atomically. The caller owns Extraction on success.
pub fn extractReader(gpa: std.mem.Allocator, io: std.Io, reader: *std.Io.Reader, parent: std.Io.Dir, destination: []const u8, limits: Limits) !Extraction {
    try validateLimits(limits);
    if (!tree_module.portablePathValid(destination) or !std.unicode.utf8ValidateSlice(destination) or
        std.mem.indexOfScalar(u8, destination, '/') != null) return error.InvalidDestination;
    var token: [16]u8 = undefined;
    io.random(&token);
    var staging_buffer: [64]u8 = undefined;
    const staging = try std.fmt.bufPrint(&staging_buffer, ".jckg-extract-{s}", .{std.fmt.bytesToHex(token, .lower)});
    // Exclusive create, not createDirPath: an existing name is never reused.
    const private_permissions: std.Io.Dir.Permissions = if (std.Io.File.Permissions.has_executable_bit) .fromMode(0o700) else .default_dir;
    try parent.createDir(io, staging, private_permissions);
    errdefer parent.deleteTree(io, staging) catch {};
    var records: std.ArrayList(Record) = .empty;
    defer {
        for (records.items) |record| freeEntry(gpa, record.entry);
        records.deinit(gpa);
    }
    var input = Input{ .reader = reader, .max_bytes = limits.max_archive_bytes };
    var total: u64 = 0;
    var header_count: usize = 0;
    {
        var stage = try parent.openDir(io, staging, .{});
        defer stage.close(io);
        while (true) {
            var block: [512]u8 = undefined;
            if (!try input.block(&block)) return error.TruncatedArchive;
            if (zeroes(&block)) {
                if (!try input.block(&block)) return error.TruncatedArchive;
                if (!zeroes(&block)) return error.InvalidTrailer;
                // Extra blocking-factor padding is permitted only as whole
                // zero blocks, and remains bounded by max_archive_bytes.
                while (try input.block(&block)) {
                    if (!zeroes(&block)) return error.InvalidTrailer;
                }
                break;
            }
            if (header_count >= limits.max_entries) return error.TooManyEntries;
            header_count += 1;
            var path_buffer: [256]u8 = undefined;
            const header = try parseHeader(&block, &path_buffer, limits);
            if (header.size > limits.max_entry_bytes) return error.EntryTooLarge;
            if (header.size > limits.max_total_bytes - total) return error.TotalSizeLimit;
            total += header.size;
            if (limits.source_byte_length) |source_length| {
                if (total > source_length *| limits.max_expansion_ratio) return error.ExpansionLimit;
            }
            try ensureParents(gpa, io, stage, &records, header.path, limits);
            if (findRecord(records.items, header.path)) |index| {
                const previous = &records.items[index];
                if (!std.mem.eql(u8, previous.entry.path, header.path)) return error.DuplicateEntry;
                if (header.kind == .directory and previous.entry.kind == .directory and !previous.explicit) {
                    previous.explicit = true;
                    continue;
                }
                return error.DuplicateEntry;
            }
            if (records.items.len >= limits.max_entries) return error.TooManyEntries;
            const owned_path = try gpa.dupe(u8, header.path);
            errdefer gpa.free(owned_path);
            var entry = tree_module.Entry{ .path = owned_path, .kind = header.kind };
            errdefer if (entry.digest) |text| gpa.free(text);
            if (header.kind == .directory) {
                try stage.createDirPath(io, header.path);
            } else {
                var file = try stage.createFile(io, header.path, .{ .exclusive = true });
                defer file.close(io);
                var write_buffer: [8192]u8 = undefined;
                var writer = file.writer(io, &write_buffer);
                var hasher = digest.Sha256.init(.{});
                var remaining = header.size;
                var body_buffer: [8192]u8 = undefined;
                while (remaining != 0) {
                    const length: usize = @intCast(@min(remaining, body_buffer.len));
                    try input.exact(body_buffer[0..length]);
                    hasher.update(body_buffer[0..length]);
                    try writer.interface.writeAll(body_buffer[0..length]);
                    remaining -= length;
                }
                try writer.interface.flush();
                if (header.executable and std.Io.File.Permissions.has_executable_bit) try file.setPermissions(io, .executable_file);
                var object: digest.Digest = undefined;
                hasher.final(&object.bytes);
                var text_buffer: [digest.Digest.text_length]u8 = undefined;
                entry.digest = try gpa.dupe(u8, object.text(&text_buffer));
                entry.byte_length = header.size;
                entry.executable = header.executable;
                const padding: usize = @intCast((512 - header.size % 512) % 512);
                try input.exact(body_buffer[0..padding]);
                if (!zeroes(body_buffer[0..padding])) {
                    return error.InvalidPadding;
                }
            }
            try records.append(gpa, .{ .entry = entry, .explicit = true });
        }
    }
    const entries = try gpa.alloc(tree_module.Entry, records.items.len);
    for (records.items, 0..) |record, index| entries[index] = record.entry;
    // Ownership is transferred before validation; every failure frees the tree.
    records.clearRetainingCapacity();
    var tree = tree_module.Tree{ .entries = entries, .gpa = gpa };
    errdefer tree.deinit();
    std.mem.sort(tree_module.Entry, entries, {}, entryLessThan);
    try tree.validate();
    var offender: ?[]const u8 = null;
    if (tree_module.destinationCheck(tree, .windows, &offender)) |err| return err;
    if (tree_module.destinationCheck(tree, .macos, &offender)) |err| return err;
    const tree_digest = try tree.digestOf(gpa);
    // No replacement and no fallback copy: a platform unable to perform this
    // atomic publication must report OperationUnsupported, never partially copy.
    try parent.renamePreserve(staging, parent, destination, io);
    return .{ .tree = tree, .tree_digest = tree_digest, .total_bytes = total, .archive_bytes = input.consumed };
}

const Record = struct { entry: tree_module.Entry, explicit: bool };
const Header = struct { path: []const u8, kind: tree_module.Kind, size: u64, executable: bool };

const Input = struct {
    reader: *std.Io.Reader,
    max_bytes: u64,
    consumed: u64 = 0,

    fn read(self: *Input, buffer: []u8) !usize {
        const count = try self.reader.readSliceShort(buffer);
        if (count > self.max_bytes - self.consumed) return error.ArchiveSizeLimit;
        self.consumed += count;
        return count;
    }

    fn exact(self: *Input, buffer: []u8) !void {
        if (try self.read(buffer) != buffer.len) return error.TruncatedArchive;
    }

    fn block(self: *Input, buffer: *[512]u8) !bool {
        const count = try self.read(buffer);
        if (count == 0) return false;
        if (count != buffer.len) return error.TruncatedArchive;
        return true;
    }
};

fn validateLimits(limits: Limits) Error!void {
    if (limits.max_entries == 0 or limits.max_entries > tree_module.max_entries or limits.max_depth == 0 or
        limits.max_depth > tree_module.max_depth or limits.max_path_bytes == 0 or limits.max_path_bytes > tree_module.max_path_bytes or
        limits.max_expansion_ratio == 0 or limits.max_total_bytes > 9007199254740991) return error.InvalidLimits;
}

fn parseHeader(block: *const [512]u8, path_buffer: *[256]u8, limits: Limits) Error!Header {
    var sum: u64 = 0;
    for (block, 0..) |byte, index| sum += if (index >= 148 and index < 156) @as(u8, ' ') else byte;
    if (try octal(block[148..156]) != sum) return error.InvalidChecksum;
    if (!std.mem.eql(u8, block[257..265], "ustar\x0000")) return error.InvalidHeader;
    if (!zeroes(block[500..512])) return error.InvalidHeader;
    const kind: tree_module.Kind = switch (block[156]) {
        0, '0' => .file,
        '5' => .directory,
        else => return error.UnsupportedEntry,
    };
    if (!zeroes(block[157..257])) return error.UnsupportedEntry;
    if (try octal(block[329..337]) != 0 or try octal(block[337..345]) != 0) return error.UnsupportedEntry;
    _ = try octal(block[108..116]); // uid is syntactically validated, never applied
    _ = try octal(block[116..124]); // gid
    _ = try octal(block[136..148]); // mtime
    _ = try fieldText(block[265..297]); // uname, never applied
    _ = try fieldText(block[297..329]); // gname
    const mode = try octal(block[100..108]);
    if (mode > 0o777) return error.UnsupportedEntry;
    const size = try octal(block[124..136]);
    if (kind == .directory and size != 0) return error.InvalidHeader;
    const name = try fieldText(block[0..100]);
    const prefix = try fieldText(block[345..500]);
    if (name.len == 0) return error.InvalidPath;
    const path_length = prefix.len + @intFromBool(prefix.len != 0) + name.len;
    if (path_length > path_buffer.len) return error.PathTooLong;
    var path = path_buffer[0..path_length];
    if (prefix.len == 0) {
        @memcpy(path, name);
    } else {
        @memcpy(path[0..prefix.len], prefix);
        path[prefix.len] = '/';
        @memcpy(path[prefix.len + 1 ..], name);
    }
    // A single conventional directory suffix is stripped, not normalized.
    // Every other '.'/'..'/absolute/drive/backslash shape is refused outright.
    if (kind == .directory and path.len != 0 and path[path.len - 1] == '/') path = path[0 .. path.len - 1];
    if (path.len > limits.max_path_bytes) return error.PathTooLong;
    if (!tree_module.portablePathValid(path) or !std.unicode.utf8ValidateSlice(path)) return error.InvalidPath;
    var depth: usize = 1;
    for (path) |byte| if (byte == '/') { depth += 1; };
    if (depth > limits.max_depth) return error.NestingLimit;
    return .{ .path = path, .kind = kind, .size = size, .executable = kind == .file and mode & 0o111 != 0 };
}

fn octal(field: []const u8) Error!u64 {
    // Only ASCII octal with space/NUL padding. GNU base-256, negatives and
    // interior terminators are not part of the portable format.
    var index: usize = 0;
    while (index < field.len and field[index] == ' ') : (index += 1) {}
    var number: u64 = 0;
    var saw_digit = false;
    while (index < field.len and field[index] >= '0' and field[index] <= '7') : (index += 1) {
        saw_digit = true;
        number = std.math.mul(u64, number, 8) catch return error.InvalidHeader;
        number = std.math.add(u64, number, field[index] - '0') catch return error.InvalidHeader;
    }
    while (index < field.len) : (index += 1) if (field[index] != 0 and field[index] != ' ') return error.InvalidHeader;
    if (!saw_digit and !zeroes(field)) return error.InvalidHeader;
    return number;
}

fn fieldText(field: []const u8) Error![]const u8 {
    const end = std.mem.indexOfScalar(u8, field, 0) orelse field.len;
    if (!zeroes(field[end..])) return error.InvalidHeader;
    const value = field[0..end];
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidHeader;
    return value;
}

fn zeroes(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn findRecord(records: []const Record, path: []const u8) ?usize {
    for (records, 0..) |record, index| if (std.ascii.eqlIgnoreCase(record.entry.path, path)) return index;
    return null;
}

fn ensureParents(gpa: std.mem.Allocator, io: std.Io, stage: std.Io.Dir, records: *std.ArrayList(Record), path: []const u8, limits: Limits) !void {
    for (path, 0..) |byte, index| {
        if (byte != '/') continue;
        const parent = path[0..index];
        if (findRecord(records.items, parent)) |previous| {
            if (!std.mem.eql(u8, records.items[previous].entry.path, parent)) return error.DuplicateEntry;
            if (records.items[previous].entry.kind != .directory) return error.ConflictingEntry;
            continue;
        }
        if (records.items.len >= limits.max_entries) return error.TooManyEntries;
        const owned = try gpa.dupe(u8, parent);
        errdefer gpa.free(owned);
        try stage.createDirPath(io, parent);
        try records.append(gpa, .{ .entry = .{ .path = owned, .kind = .directory }, .explicit = false });
    }
}

fn freeEntry(gpa: std.mem.Allocator, entry: tree_module.Entry) void {
    gpa.free(entry.path);
    if (entry.digest) |text| gpa.free(text);
}

fn entryLessThan(_: void, a: tree_module.Entry, b: tree_module.Entry) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

// Test-only ustar builder: bodies are real serialized headers and data consumed
// by the public reader. Malicious type/path/size fields are not mocked away.
const TestEntry = struct {
    path: []const u8,
    body: []const u8 = "",
    typeflag: u8 = '0',
    target: []const u8 = "",
    mode: u64 = 0o644,
    declared_size: ?u64 = null,
};

fn tarForTest(gpa: std.mem.Allocator, entries: []const TestEntry) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);
    for (entries) |entry| {
        var header: [512]u8 = @splat(0);
        if (entry.path.len > 100 or entry.target.len > 100) return error.PathTooLong;
        @memcpy(header[0..entry.path.len], entry.path);
        try putOctal(header[100..108], entry.mode);
        try putOctal(header[108..116], 0);
        try putOctal(header[116..124], 0);
        try putOctal(header[124..136], entry.declared_size orelse entry.body.len);
        try putOctal(header[136..148], 0);
        header[156] = entry.typeflag;
        @memcpy(header[157..][0..entry.target.len], entry.target);
        @memcpy(header[257..265], "ustar\x0000");
        try putOctal(header[329..337], 0);
        try putOctal(header[337..345], 0);
        try fixChecksum(&header);
        try bytes.appendSlice(gpa, &header);
        try bytes.appendSlice(gpa, entry.body);
        const padding = (512 - entry.body.len % 512) % 512;
        try bytes.appendNTimes(gpa, 0, padding);
    }
    try bytes.appendNTimes(gpa, 0, 1024);
    return bytes.toOwnedSlice(gpa);
}

fn putOctal(field: []u8, number: u64) !void {
    @memset(field, '0');
    field[field.len - 1] = 0;
    var buffer: [24]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{o}", .{number});
    if (text.len >= field.len) return error.InvalidHeader;
    @memcpy(field[field.len - 1 - text.len .. field.len - 1], text);
}

fn fixChecksum(header: *[512]u8) !void {
    @memset(header[148..156], ' ');
    var sum: u64 = 0;
    for (header) |byte| sum += byte;
    try putOctal(header[148..155], sum);
    header[155] = ' ';
}

fn rejectArchive(parent: std.Io.Dir, bytes: []const u8, limits: Limits, expected_error: anyerror) !void {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    if (extractBytes(gpa, io, bytes, parent, "rejected", limits)) |unexpected| {
        var owned = unexpected;
        owned.deinit();
        try std.testing.expect(false);
    } else |err| try std.testing.expectEqual(expected_error, err);
    try std.testing.expectError(error.FileNotFound, parent.statFile(io, "rejected", .{}));
    var iterator = parent.iterate();
    while (try iterator.next(io)) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".jckg-extract-"));
    }
}

test "m07/TRUST-010 reject portable archive attacks atomically" {
    std.debug.print("JCKG_EVIDENCE TRUST-010\n", .{});
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const valid_entries = [_]TestEntry{
        .{ .path = "lib/data", .body = "payload" },
        .{ .path = "lib/", .typeflag = '5', .mode = 0o755 },
        .{ .path = "empty/", .typeflag = '5', .mode = 0o755 },
        .{ .path = "bin/run", .body = "#!/bin/sh\n", .mode = 0o755 },
    };
    const valid = try tarForTest(gpa, &valid_entries);
    defer gpa.free(valid);
    var extracted = extractBytes(gpa, io, valid, temp.dir, "published", .{}) catch |err| {
        try std.testing.expectEqual(@as(?anyerror, null), @as(?anyerror, err));
        return err;
    };
    defer extracted.deinit();
    const expected_paths = [_][]const u8{ "bin", "bin/run", "empty", "lib", "lib/data" };
    try std.testing.expectEqual(expected_paths.len, extracted.tree.entries.len);
    for (expected_paths, extracted.tree.entries) |path, entry| try std.testing.expectEqualStrings(path, entry.path);
    try std.testing.expectEqual(@as(u64, 17), extracted.total_bytes);
    try std.testing.expectEqual(@as(u64, valid.len), extracted.archive_bytes);
    try std.testing.expect(extracted.tree_digest.eql(try extracted.tree.digestOf(gpa)));
    const empty_entry = extracted.tree.find("empty") orelse return error.TestExpectedEqual;
    const executable_entry = extracted.tree.find("bin/run") orelse return error.TestExpectedEqual;
    try std.testing.expect(empty_entry.kind == .directory);
    try std.testing.expect(executable_entry.executable);
    const content = try temp.dir.readFileAlloc(io, "published/lib/data", gpa, .limited(32));
    defer gpa.free(content);
    try std.testing.expectEqualStrings("payload", content);
    // Existing destinations are neither replaced nor traversed. The platform
    // may spell an existing-directory rename error AccessDenied on Windows.
    if (extractBytes(gpa, io, valid, temp.dir, "published", .{})) |unexpected| {
        var owned = unexpected;
        owned.deinit();
        return error.TestUnexpectedSuccess;
    } else |err| try std.testing.expect(err == error.PathAlreadyExists or err == error.AccessDenied);
    const unchanged = try temp.dir.readFileAlloc(io, "published/lib/data", gpa, .limited(32));
    defer gpa.free(unchanged);
    try std.testing.expectEqualStrings("payload", unchanged);

    const malicious_paths = [_][]const u8{
        "../escape", "a/../../escape", "/absolute", "C:/escape", "a\\..\\escape", "//host/share",
        "./relative", "a//b", "aux.txt", "file:stream", "bad. ", "a\xff",
    };
    for (malicious_paths) |path| {
        const attack = try tarForTest(gpa, &.{ .{ .path = "first-safe", .body = "private until commit" }, .{ .path = path, .body = "attack" } });
        defer gpa.free(attack);
        try rejectArchive(temp.dir, attack, .{}, error.InvalidPath);
    }
    // No host symlink privileges are needed: both link types are rejected from
    // serialized headers, including escape targets and links within the tree.
    for ([_]u8{ '1', '2', '3', '4', '6', 'S', 'x', 'g', 'L', 'K', '7' }) |flag| {
        const attack = try tarForTest(gpa, &.{ .{ .path = "first-safe", .body = "private" }, .{ .path = "escape", .typeflag = flag, .target = "../../outside" } });
        defer gpa.free(attack);
        try rejectArchive(temp.dir, attack, .{}, error.UnsupportedEntry);
    }
    const duplicate = try tarForTest(gpa, &.{ .{ .path = "same", .body = "first" }, .{ .path = "same", .body = "second" } });
    defer gpa.free(duplicate);
    try rejectArchive(temp.dir, duplicate, .{}, error.DuplicateEntry);
    const case_duplicate = try tarForTest(gpa, &.{ .{ .path = "Dir/a", .body = "first" }, .{ .path = "dir/b", .body = "second" } });
    defer gpa.free(case_duplicate);
    try rejectArchive(temp.dir, case_duplicate, .{}, error.DuplicateEntry);
    const ancestor = try tarForTest(gpa, &.{ .{ .path = "file", .body = "first" }, .{ .path = "file/child", .body = "second" } });
    defer gpa.free(ancestor);
    try rejectArchive(temp.dir, ancestor, .{}, error.ConflictingEntry);
    const count = try tarForTest(gpa, &.{ .{ .path = "one", .body = "1" }, .{ .path = "two", .body = "2" } });
    defer gpa.free(count);
    try rejectArchive(temp.dir, count, .{ .max_entries = 1 }, error.TooManyEntries);
    try rejectArchive(temp.dir, valid, .{ .max_entry_bytes = 2 }, error.EntryTooLarge);
    try rejectArchive(temp.dir, valid, .{ .max_total_bytes = 8 }, error.TotalSizeLimit);
    try rejectArchive(temp.dir, valid, .{ .max_archive_bytes = 512 }, error.ArchiveSizeLimit);
    try rejectArchive(temp.dir, valid, .{ .max_depth = 1 }, error.NestingLimit);
    try rejectArchive(temp.dir, valid, .{ .max_path_bytes = 4 }, error.PathTooLong);
    try rejectArchive(temp.dir, valid, .{ .source_byte_length = 1, .max_expansion_ratio = 2 }, error.ExpansionLimit);
    try rejectArchive(temp.dir, valid[0..700], .{}, error.TruncatedArchive);
    try rejectArchive(temp.dir, valid[0 .. valid.len - 512], .{}, error.TruncatedArchive);
    const mutated = try gpa.dupe(u8, valid);
    defer gpa.free(mutated);
    mutated[0] ^= 1;
    try rejectArchive(temp.dir, mutated, .{}, error.InvalidChecksum);
    @memcpy(mutated, valid);
    mutated[124] = 0x80; // GNU base-256 size is not portable octal.
    try fixChecksum(mutated[0..512]);
    try rejectArchive(temp.dir, mutated, .{}, error.InvalidHeader);
    @memcpy(mutated, valid);
    mutated[512 + valid_entries[0].body.len] = 1;
    try rejectArchive(temp.dir, mutated, .{}, error.InvalidPadding);
    @memcpy(mutated, valid);
    mutated[mutated.len - 1] = 1;
    try rejectArchive(temp.dir, mutated, .{}, error.InvalidTrailer);
    try std.testing.expectError(error.InvalidDestination, extractBytes(gpa, io, valid, temp.dir, "../outside", .{}));
    try std.testing.expectError(error.InvalidLimits, extractBytes(gpa, io, valid, temp.dir, "bad-limits", .{ .max_depth = 0 }));
    // Empty archives preserve an empty directory/tree, not a fabricated file.
    const empty: [1024]u8 = @splat(0);
    var empty_result = try extractBytes(gpa, io, &empty, temp.dir, "empty-archive", .{});
    defer empty_result.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty_result.tree.entries.len);
}
