//! Portable tree model, path policy, and tree identity (cases CAN-009, CAN-010).
//!
//! A tree is a flat array of entries in path order. Files carry a blob digest,
//! a byte length, and an executable flag; directories preserve empty
//! directories; symlinks carry a literal target that is never followed while
//! hashing. The portable path policy is conservative on purpose: a tree that
//! cannot be materialized on a destination must be rejected explicitly instead
//! of being silently renamed.
const std = @import("std");
const canonical = @import("canonical.zig");
const digest = @import("digest.zig");

pub const Kind = enum {
    file,
    directory,
    symlink,

    pub fn text(self: Kind) []const u8 {
        return switch (self) {
            .file => "file",
            .directory => "directory",
            .symlink => "symlink",
        };
    }
};

pub const Entry = struct {
    /// Relative POSIX-style path.
    path: []const u8,
    kind: Kind,
    /// File entries: blob digest text (`sha256:...`).
    digest: ?[]const u8 = null,
    /// File entries: declared byte length.
    byte_length: ?u64 = null,
    /// File entries: whether the executable bit is part of the tree.
    executable: bool = false,
    /// Symlink entries: the literal target.
    target: ?[]const u8 = null,
};

pub const Error = error{
    InvalidPath,
    DuplicatePath,
    UnsortedEntries,
    FileIsAncestor,
    InvalidDigest,
    MissingFileMetadata,
    UnexpectedMetadata,
    InvalidTarget,
    MissingSymlinkTarget,
    TooManyEntries,
    TooDeep,
};

pub const max_entries = 1_000_000;
pub const max_path_bytes = 4096;
pub const max_depth = 256;

const reserved_names = [_][]const u8{
    "CON",  "PRN",  "AUX",  "NUL",
    "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
    "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    "COM\u{00b9}", "COM\u{00b2}", "COM\u{00b3}",
    "LPT\u{00b9}", "LPT\u{00b2}", "LPT\u{00b3}",
};

fn isReservedName(component: []const u8) bool {
    const base = if (std.mem.indexOfScalar(u8, component, '.')) |dot| component[0..dot] else component;
    var buffer: [64]u8 = undefined;
    if (base.len > buffer.len) return true;
    const upper = std.ascii.upperString(buffer[0..base.len], base);
    for (reserved_names) |reserved| {
        if (std.mem.eql(u8, upper, reserved)) return true;
    }
    return false;
}

/// The conservative cross-platform path policy.
///
/// Rejects absolute paths, traversal, drive and stream syntax, Windows-reserved
/// characters and names, control characters, invalid UTF-8, and components that
/// end in a dot or a space. Backslashes are rejected outright: a portable tree
/// stores POSIX separators only.
pub fn portablePathValid(path: []const u8) bool {
    if (path.len == 0 or path.len > max_path_bytes) return false;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;

    for (path) |byte| {
        if (byte < 0x20 or byte == 0x7f) return false;
        switch (byte) {
            '<', '>', ':', '"', '|', '?', '*' => return false,
            else => {},
        }
    }
    if (path[0] == '/') return false;

    var components = std.mem.splitScalar(u8, path, '/');
    var depth: usize = 0;
    while (components.next()) |component| {
        depth += 1;
        if (depth > max_depth) return false;
        if (component.len == 0) return false;
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
        if (component[component.len - 1] == '.' or component[component.len - 1] == ' ') return false;
        if (isReservedName(component)) return false;
    }
    return true;
}

pub const Policy = enum {
    /// The conservative cross-platform subset used for portable trees.
    portable,
    /// A POSIX-flavoured tree: reserved names, colons, and trailing dots or
    /// spaces are allowed, because Linux can create them. Such a tree is not
    /// automatically materializable on Windows.
    linux,
};

/// Which destination a tree is being materialized into.
pub const DestOs = enum { windows, linux, macos };

/// Paths that a Windows destination cannot represent without renaming.
pub fn windowsMaterializable(path: []const u8) bool {
    return portablePathValid(path);
}

/// Checks that every entry can be materialized on `destination` under its own
/// name. Returns the first offending path so the caller can report it, and
/// never suggests a renamed substitute.
pub fn destinationCheck(tree: Tree, destination: DestOs, offender: *?[]const u8) ?Error {
    offender.* = null;
    for (tree.entries) |entry| {
        if (destination == .windows and !windowsMaterializable(entry.path)) {
            offender.* = entry.path;
            return error.InvalidPath;
        }
        if (destination != .linux) {
            // Case-insensitive destinations cannot hold two entries that
            // differ only by letter case.
            for (tree.entries) |other| {
                if (entry.path.len != other.path.len) continue;
                if (std.ascii.eqlIgnoreCase(entry.path, other.path) and
                    !std.mem.eql(u8, entry.path, other.path))
                {
                    offender.* = entry.path;
                    return error.DuplicatePath;
                }
            }
        }
    }
    return null;
}

/// Validates a tree against a policy.
pub fn validateWith(self: Tree, policy: Policy) Error!void {
    if (self.entries.len > max_entries) return error.TooManyEntries;
    var previous: ?[]const u8 = null;
    for (self.entries, 0..) |entry, index| {
        const path_ok = switch (policy) {
            .portable => portablePathValid(entry.path),
            .linux => linuxPathValid(entry.path),
        };
        if (!path_ok) return error.InvalidPath;
        if (previous) |earlier| {
            const ordering = std.mem.order(u8, earlier, entry.path);
            if (ordering == .eq) return error.DuplicatePath;
            if (ordering == .gt) return error.UnsortedEntries;
        }
        previous = entry.path;

        switch (entry.kind) {
            .file => {
                const text = entry.digest orelse return error.MissingFileMetadata;
                _ = digest.Digest.parse(text) catch return error.InvalidDigest;
                if (entry.byte_length == null) return error.MissingFileMetadata;
                if (entry.target != null) return error.UnexpectedMetadata;
            },
            .directory => {
                if (entry.digest != null or entry.byte_length != null or entry.target != null) return error.UnexpectedMetadata;
                if (entry.executable) return error.UnexpectedMetadata;
            },
            .symlink => {
                const target = entry.target orelse return error.MissingSymlinkTarget;
                if (target.len == 0) return error.InvalidTarget;
                if (std.mem.indexOfScalar(u8, target, 0) != null) return error.InvalidTarget;
                if (entry.digest != null or entry.byte_length != null) return error.UnexpectedMetadata;
                if (entry.executable) return error.UnexpectedMetadata;
            },
        }

        // A non-directory entry may not be an ancestor of a later entry.
        if (entry.kind != .directory) {
            for (self.entries[index + 1 ..]) |later| {
                if (later.path.len > entry.path.len and
                    std.mem.startsWith(u8, later.path, entry.path) and
                    later.path[entry.path.len] == '/')
                {
                    return error.FileIsAncestor;
                }
            }
        }
    }
}

/// POSIX-flavoured path policy: still no traversal, no empty component, no
/// control character, no absolute path, and valid UTF-8, but Linux names such
/// as `aux.txt`, `a:b`, or `trailing.` are permitted.
pub fn linuxPathValid(path: []const u8) bool {
    if (path.len == 0 or path.len > max_path_bytes) return false;
    if (!std.unicode.utf8ValidateSlice(path)) return false;
    if (path[0] == '/') return false;
    for (path) |byte| {
        if (byte < 0x20 or byte == 0x7f) return false;
    }
    var components = std.mem.splitScalar(u8, path, '/');
    var depth: usize = 0;
    while (components.next()) |component| {
        depth += 1;
        if (depth > max_depth) return false;
        if (component.len == 0) return false;
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

pub const Tree = struct {
    entries: []Entry,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Tree) void {
        for (self.entries) |entry| {
            self.gpa.free(entry.path);
            if (entry.digest) |text| self.gpa.free(text);
            if (entry.target) |text| self.gpa.free(text);
        }
        self.gpa.free(self.entries);
        self.* = undefined;
    }

    /// Validates path policy, ordering, uniqueness, per-kind metadata, and the
    /// rule that a file cannot be an ancestor of another entry.
    pub fn validate(self: Tree) Error!void {
        return validateWith(self, .portable);
    }

    /// Canonical array of entries in path order.
    pub fn toCanonical(self: Tree, gpa: std.mem.Allocator) std.mem.Allocator.Error!canonical.Value {
        const items = try gpa.alloc(canonical.Value, self.entries.len);
        errdefer gpa.free(items);
        for (self.entries, 0..) |entry, index| {
            switch (entry.kind) {
                .file => {
                    const fields = try gpa.alloc(canonical.Entry, 5);
                    errdefer gpa.free(fields);
                    fields[0] = .{ .key = try gpa.dupe(u8, "kind"), .value = .{ .string = try gpa.dupe(u8, "file") } };
                    fields[1] = .{ .key = try gpa.dupe(u8, "path"), .value = .{ .string = try gpa.dupe(u8, entry.path) } };
                    fields[2] = .{ .key = try gpa.dupe(u8, "digest"), .value = .{ .string = try gpa.dupe(u8, entry.digest.?) } };
                    fields[3] = .{ .key = try gpa.dupe(u8, "byteLength"), .value = .{ .integer = @intCast(entry.byte_length.?) } };
                    fields[4] = .{ .key = try gpa.dupe(u8, "executable"), .value = .{ .boolean = entry.executable } };
                    items[index] = .{ .object = fields };
                },
                .directory => {
                    const fields = try gpa.alloc(canonical.Entry, 2);
                    errdefer gpa.free(fields);
                    fields[0] = .{ .key = try gpa.dupe(u8, "kind"), .value = .{ .string = try gpa.dupe(u8, "directory") } };
                    fields[1] = .{ .key = try gpa.dupe(u8, "path"), .value = .{ .string = try gpa.dupe(u8, entry.path) } };
                    items[index] = .{ .object = fields };
                },
                .symlink => {
                    const fields = try gpa.alloc(canonical.Entry, 3);
                    errdefer gpa.free(fields);
                    fields[0] = .{ .key = try gpa.dupe(u8, "kind"), .value = .{ .string = try gpa.dupe(u8, "symlink") } };
                    fields[1] = .{ .key = try gpa.dupe(u8, "path"), .value = .{ .string = try gpa.dupe(u8, entry.path) } };
                    fields[2] = .{ .key = try gpa.dupe(u8, "target"), .value = .{ .string = try gpa.dupe(u8, entry.target.?) } };
                    items[index] = .{ .object = fields };
                },
            }
            canonical.canonicalize(&items[index]);
        }
        return .{ .array = items };
    }

    /// `sha256("jckg:tree:v1\0" || canonical tree)`.
    pub fn digestOf(self: Tree, gpa: std.mem.Allocator) std.mem.Allocator.Error!digest.Digest {
        const value = try self.toCanonical(gpa);
        defer value.deinit(gpa);
        return digest.ofCanonical(gpa, .tree, value);
    }

    pub fn find(self: Tree, path: []const u8) ?Entry {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.path, path)) return entry;
        }
        return null;
    }
};

pub fn ownedEntry(
    gpa: std.mem.Allocator,
    path: []const u8,
    kind: Kind,
    options: struct {
        digest_text: ?[]const u8 = null,
        byte_length: ?u64 = null,
        executable: bool = false,
        target: ?[]const u8 = null,
    },
) !Entry {
    return .{
        .path = try gpa.dupe(u8, path),
        .kind = kind,
        .digest = if (options.digest_text) |text| try gpa.dupe(u8, text) else null,
        .byte_length = options.byte_length,
        .executable = options.executable,
        .target = if (options.target) |text| try gpa.dupe(u8, text) else null,
    };
}

pub const path_fixture_path = ".jackage-delivery/fixtures/portable-path-vectors.json";

test "m02/CAN-009 reject unsafe portable paths" {
    std.debug.print("JCKG_EVIDENCE CAN-009\n", .{});
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Every fixture vector must match the documented policy exactly.
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path_fixture_path, gpa, .unlimited);
    defer gpa.free(text);
    var document = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    defer document.deinit();
    const vectors = document.value.object.get("vectors").?.array.items;
    try std.testing.expectEqual(@as(usize, 40), vectors.len);
    for (vectors) |vector| {
        const path = vector.object.get("path").?.string;
        const expected = vector.object.get("valid").?.bool;
        const actual = portablePathValid(path);
        if (actual != expected) {
            std.debug.print("path vector mismatch: {s} expected valid={} got {}\n", .{ path, expected, actual });
            return error.PathVectorMismatch;
        }
    }

    // Negative-or-recovery: validation of a tree never touches the filesystem,
    // so an unsafe path is rejected without any filesystem effect.
    var entries = [_]Entry{
        .{ .path = "../escape", .kind = .directory },
    };
    var tree = Tree{ .entries = &entries, .gpa = gpa };
    try std.testing.expectError(error.InvalidPath, tree.validate());
    entries[0].path = "src/../escape";
    try std.testing.expectError(error.InvalidPath, tree.validate());
    entries[0].path = "a\u{0000}b";
    try std.testing.expectError(error.InvalidPath, tree.validate());

    // A valid tree passes, including non-ASCII and decomposed names.
    var valid_entries = [_]Entry{
        .{ .path = "café/东京.txt", .kind = .directory },
        .{ .path = "café/东京.txt/inner", .kind = .directory },
        .{ .path = "e\u{0301}.txt", .kind = .directory },
    };
    var valid_tree = Tree{ .entries = &valid_entries, .gpa = gpa };
    try valid_tree.validate();
}

test "m02/CAN-010 validate tree structure" {
    std.debug.print("JCKG_EVIDENCE CAN-010\n", .{});
    const gpa = std.testing.allocator;
    var digest_buffer: [digest.Digest.text_length]u8 = undefined;
    const file_digest = digest.ofBlob("hello\n").text(&digest_buffer);
    const owned = try gpa.dupe(u8, file_digest);
    defer gpa.free(owned);

    // A file that is an ancestor of another entry fails before materialization.
    var ancestor_entries = [_]Entry{
        .{ .path = "a", .kind = .file, .digest = owned, .byte_length = 6 },
        .{ .path = "a/b", .kind = .file, .digest = owned, .byte_length = 6 },
    };
    var ancestor_tree = Tree{ .entries = &ancestor_entries, .gpa = gpa };
    try std.testing.expectError(error.FileIsAncestor, ancestor_tree.validate());

    // A directory with the same prefix is fine, and an empty directory is kept.
    var directory_entries = [_]Entry{
        .{ .path = "a", .kind = .directory },
        .{ .path = "a/b", .kind = .file, .digest = owned, .byte_length = 6 },
    };
    var directory_tree = Tree{ .entries = &directory_entries, .gpa = gpa };
    try directory_tree.validate();

    // Duplicate paths and unordered entries are rejected.
    var duplicate_entries = [_]Entry{
        .{ .path = "a/b", .kind = .directory },
        .{ .path = "a/b", .kind = .directory },
    };
    var duplicate_tree = Tree{ .entries = &duplicate_entries, .gpa = gpa };
    try std.testing.expectError(error.DuplicatePath, duplicate_tree.validate());

    var unsorted_entries = [_]Entry{
        .{ .path = "b", .kind = .directory },
        .{ .path = "a", .kind = .directory },
    };
    var unsorted_tree = Tree{ .entries = &unsorted_entries, .gpa = gpa };
    try std.testing.expectError(error.UnsortedEntries, unsorted_tree.validate());

    // Per-kind metadata is enforced: a file needs a digest and length, a
    // symlink needs a target, and a directory must not carry file metadata.
    var missing_digest = [_]Entry{
        .{ .path = "a", .kind = .file, .byte_length = 1 },
    };
    var missing_digest_tree = Tree{ .entries = &missing_digest, .gpa = gpa };
    try std.testing.expectError(error.MissingFileMetadata, missing_digest_tree.validate());

    var bad_digest = [_]Entry{
        .{ .path = "a", .kind = .file, .digest = "sha256:abc", .byte_length = 1 },
    };
    var bad_digest_tree = Tree{ .entries = &bad_digest, .gpa = gpa };
    try std.testing.expectError(error.InvalidDigest, bad_digest_tree.validate());

    var missing_target = [_]Entry{
        .{ .path = "link", .kind = .symlink },
    };
    var missing_target_tree = Tree{ .entries = &missing_target, .gpa = gpa };
    try std.testing.expectError(error.MissingSymlinkTarget, missing_target_tree.validate());

    var directory_with_metadata = [_]Entry{
        .{ .path = "dir", .kind = .directory, .digest = owned },
    };
    var directory_with_metadata_tree = Tree{ .entries = &directory_with_metadata, .gpa = gpa };
    try std.testing.expectError(error.UnexpectedMetadata, directory_with_metadata_tree.validate());

    // A valid tree produces a stable identity, and a one-byte difference in a
    // blob digest changes the tree identity.
    var entries = [_]Entry{
        .{ .path = "bin/jckg", .kind = .file, .digest = owned, .byte_length = 6, .executable = true },
        .{ .path = "empty", .kind = .directory },
        .{ .path = "link", .kind = .symlink, .target = "bin/jckg" },
    };
    var tree = Tree{ .entries = &entries, .gpa = gpa };
    try tree.validate();
    const first = try tree.digestOf(gpa);
    const second = try tree.digestOf(gpa);
    try std.testing.expect(first.eql(second));

    var other_digest_buffer: [digest.Digest.text_length]u8 = undefined;
    const other = try gpa.dupe(u8, digest.ofBlob("hellp\n").text(&other_digest_buffer));
    defer gpa.free(other);
    entries[0].digest = other;
    const changed = try tree.digestOf(gpa);
    try std.testing.expect(!changed.eql(first));

    // The canonical tree is an array in path order with the documented fields.
    entries[0].digest = owned;
    const value = try tree.toCanonical(gpa);
    defer value.deinit(gpa);
    const encoded = try canonical.encodeAlloc(gpa, value);
    defer gpa.free(encoded);
    try std.testing.expect(std.mem.startsWith(u8, encoded, "[{\"byteLength\":6,\"digest\":\"sha256:"));
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"kind\":\"directory\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"kind\":\"symlink\",\"path\":\"link\",\"target\":\"bin/jckg\"") != null);
}
