//! Collects declared native outputs without following links. All selected
//! contents and tree metadata are validated before any store publication.
const std = @import("std");
const builtin = @import("builtin");
const tree = @import("../core/tree.zig");
const digest = @import("../core/digest.zig");
const store_module = @import("../core/store.zig");

pub const Collection = struct {
    entries: []tree.Entry,
    undeclared: [][]const u8,
    tree_digest: digest.Digest,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Collection) void {
        var collected_tree: tree.Tree = .{ .entries = self.entries, .gpa = self.gpa };
        collected_tree.deinit();
        for (self.undeclared) |path| self.gpa.free(path);
        self.gpa.free(self.undeclared);
        self.* = undefined;
    }
};

const PendingBlob = struct {
    bytes: []u8,
    object: digest.Digest,
};

const Frame = struct {
    iterator: std.Io.Dir.Iterator,
    path_length: usize,
    included: bool,
};

/// Files are selected only by an exact declaration. A declared directory also
/// selects every descendant, including empty directories. Undeclared files,
/// links, and other non-directory paths are reported, never imported.
///
/// This is a same-user native boundary, not a sandbox against concurrent
/// workspace mutation. Reads use no-follow handles and check their real paths.
/// An invalid declaration, missing output, unreadable file, or escaping link
/// fails before importing any blob or committing the tree.
pub fn collect(
    gpa: std.mem.Allocator,
    io: std.Io,
    workspace: std.Io.Dir,
    declared: []const []const u8,
    store: store_module.Store,
) !Collection {
    for (declared) |path| {
        if (!portablePathValid(path)) return error.OutputEscape;
    }
    const seen = try gpa.alloc(bool, declared.len);
    defer gpa.free(seen);
    @memset(seen, false);

    var workspace_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const workspace_length = try workspace.realPath(io, &workspace_buffer);
    const workspace_real = workspace_buffer[0..workspace_length];
    var real_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;

    var entries: std.ArrayList(tree.Entry) = .empty;
    errdefer {
        for (entries.items) |entry| {
            gpa.free(entry.path);
            if (entry.digest) |text| gpa.free(text);
        }
        entries.deinit(gpa);
    }
    var undeclared: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (undeclared.items) |path| gpa.free(path);
        undeclared.deinit(gpa);
    }
    var blobs: std.ArrayList(PendingBlob) = .empty;
    defer {
        for (blobs.items) |blob| gpa.free(blob.bytes);
        blobs.deinit(gpa);
    }

    // Keep directory handles open while visiting their children. Every open
    // resolves just one component, so no intermediate symlink can be followed.
    var stack: std.ArrayList(Frame) = .empty;
    defer {
        for (stack.items) |frame| frame.iterator.reader.dir.close(io);
        stack.deinit(gpa);
    }
    {
        const root = try workspace.openDir(io, ".", .{ .iterate = true, .follow_symlinks = false });
        errdefer root.close(io);
        const root_length = try root.realPath(io, &real_buffer);
        if (!realPathWithin(workspace_real, real_buffer[0..root_length])) return error.OutputEscape;
        try stack.append(gpa, .{ .iterator = root.iterateAssumeFirstIteration(), .path_length = 0, .included = false });
    }
    var path_buffer: std.ArrayList(u8) = .empty;
    defer path_buffer.deinit(gpa);

    while (stack.items.len != 0) {
        const frame = &stack.items[stack.items.len - 1];
        path_buffer.shrinkRetainingCapacity(frame.path_length);
        const child = (try frame.iterator.next(io)) orelse {
            const finished = stack.pop().?;
            finished.iterator.reader.dir.close(io);
            continue;
        };
        const parent = frame.iterator.reader.dir;
        const parent_included = frame.included;
        if (path_buffer.items.len != 0) try path_buffer.append(gpa, '/');
        try path_buffer.appendSlice(gpa, child.name);
        const path = path_buffer.items;

        var exact = false;
        var declaration_below = false;
        for (declared, seen) |declaration, *found| {
            if (std.mem.eql(u8, path, declaration)) {
                exact = true;
                found.* = true;
            } else if (portableDescendant(path, declaration)) {
                declaration_below = true;
            }
        }
        const included = parent_included or exact;
        if (included and !portablePathValid(path)) return error.OutputEscape;

        if (builtin.os.tag == .windows) {
            @import("windows.zig").rejectReparse(io, parent, child.name) catch |err| switch (err) {
                error.OutputEscape => {
                    if (included or declaration_below) return error.OutputEscape;
                    try appendUndeclared(gpa, &undeclared, path);
                    continue;
                },
                else => return err,
            };
        }
        const stat = try parent.statFile(io, child.name, .{ .follow_symlinks = false });
        switch (stat.kind) {
            .sym_link => {
                if (included or declaration_below) return error.OutputEscape;
                try appendUndeclared(gpa, &undeclared, path);
            },
            .directory => {
                const directory = parent.openDir(io, child.name, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
                    error.SymLinkLoop => return error.OutputEscape,
                    else => return err,
                };
                errdefer directory.close(io);
                const opened_stat = try directory.stat(io);
                if (opened_stat.kind == .sym_link) return error.OutputEscape;
                if (opened_stat.kind != .directory) return error.UnsupportedOutputKind;
                const length = try directory.realPath(io, &real_buffer);
                if (!realPathWithin(workspace_real, real_buffer[0..length])) return error.OutputEscape;
                if (included) try appendDirectory(gpa, &entries, path);
                try stack.append(gpa, .{
                    .iterator = directory.iterateAssumeFirstIteration(),
                    .path_length = path.len,
                    .included = included,
                });
            },
            .file => {
                if (declaration_below) return error.NotDir;
                if (included) {
                    try collectFile(gpa, io, parent, child.name, path, workspace_real, &real_buffer, &entries, &blobs);
                } else {
                    try appendUndeclared(gpa, &undeclared, path);
                }
            },
            else => {
                if (declaration_below) return error.NotDir;
                if (included) return error.UnsupportedOutputKind;
                try appendUndeclared(gpa, &undeclared, path);
            },
        }
    }
    for (seen) |found| {
        if (!found) return error.FileNotFound;
    }

    std.mem.sortUnstable(tree.Entry, entries.items, {}, entryLessThan);
    std.mem.sortUnstable([]const u8, undeclared.items, {}, pathLessThan);
    var collected_tree: tree.Tree = .{ .entries = try entries.toOwnedSlice(gpa), .gpa = gpa };
    errdefer collected_tree.deinit();
    const undeclared_paths = try undeclared.toOwnedSlice(gpa);
    errdefer {
        for (undeclared_paths) |path| gpa.free(path);
        gpa.free(undeclared_paths);
    }
    try collected_tree.validate();

    // Publication starts only after the complete workspace scan, every
    // required declaration, every byte read, and the core tree validate.
    for (blobs.items) |blob| {
        _ = try store.importBytes(blob.bytes, blob.object);
    }
    const tree_digest = try store.commitTree(collected_tree);
    return .{ .entries = collected_tree.entries, .undeclared = undeclared_paths, .tree_digest = tree_digest, .gpa = gpa };
}

fn portablePathValid(path: []const u8) bool {
    return tree.portablePathValid(path) and std.unicode.utf8ValidateSlice(path);
}

fn portableDescendant(parent: []const u8, child: []const u8) bool {
    return child.len > parent.len and std.mem.startsWith(u8, child, parent) and child[parent.len] == '/';
}

fn realPathWithin(workspace: []const u8, candidate: []const u8) bool {
    var workspace_components = std.fs.path.componentIterator(workspace);
    var candidate_components = std.fs.path.componentIterator(candidate);
    const workspace_root = workspace_components.root() orelse return false;
    const candidate_root = candidate_components.root() orelse return false;
    if (builtin.os.tag == .windows) {
        if (!std.os.windows.eqlIgnoreCaseWtf8(workspace_root, candidate_root)) return false;
    } else if (!std.mem.eql(u8, workspace_root, candidate_root)) {
        return false;
    }
    while (workspace_components.next()) |component| {
        const candidate_component = candidate_components.next() orelse return false;
        if (builtin.os.tag == .windows) {
            if (!std.os.windows.eqlIgnoreCaseWtf8(component.name, candidate_component.name)) return false;
        } else if (!std.mem.eql(u8, component.name, candidate_component.name)) {
            return false;
        }
    }
    return true;
}

fn appendDirectory(gpa: std.mem.Allocator, entries: *std.ArrayList(tree.Entry), path: []const u8) !void {
    if (entries.items.len == tree.max_entries) return error.TooManyEntries;
    const owned_path = try gpa.dupe(u8, path);
    errdefer gpa.free(owned_path);
    try entries.append(gpa, .{ .path = owned_path, .kind = .directory });
}

fn appendUndeclared(gpa: std.mem.Allocator, undeclared: *std.ArrayList([]const u8), path: []const u8) !void {
    const owned_path = try gpa.dupe(u8, path);
    errdefer gpa.free(owned_path);
    try undeclared.append(gpa, owned_path);
}

fn collectFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    name: []const u8,
    path: []const u8,
    workspace_real: []const u8,
    real_buffer: []u8,
    entries: *std.ArrayList(tree.Entry),
    blobs: *std.ArrayList(PendingBlob),
) !void {
    if (entries.items.len == tree.max_entries) return error.TooManyEntries;
    try entries.ensureUnusedCapacity(gpa, 1);
    try blobs.ensureUnusedCapacity(gpa, 1);
    const file = directory.openFile(io, name, .{ .follow_symlinks = false, .allow_directory = false }) catch |err| switch (err) {
        error.SymLinkLoop => return error.OutputEscape,
        else => return err,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind == .sym_link) return error.OutputEscape;
    if (stat.kind != .file) return error.UnsupportedOutputKind;
    var length = try file.realPath(io, real_buffer);
    if (!realPathWithin(workspace_real, real_buffer[0..length])) return error.OutputEscape;

    var reader = std.Io.File.Reader.initSize(file, io, &.{}, stat.size);
    const bytes = reader.interface.allocRemaining(gpa, .unlimited) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.OutOfMemory, error.StreamTooLong => return err,
    };
    errdefer gpa.free(bytes);
    length = try file.realPath(io, real_buffer);
    if (!realPathWithin(workspace_real, real_buffer[0..length])) return error.OutputEscape;
    const object = digest.ofBlob(bytes);
    const owned_path = try gpa.dupe(u8, path);
    errdefer gpa.free(owned_path);
    var digest_buffer: [digest.Digest.text_length]u8 = undefined;
    const digest_text = try gpa.dupe(u8, object.text(&digest_buffer));
    errdefer gpa.free(digest_text);
    entries.appendAssumeCapacity(.{
        .path = owned_path,
        .kind = .file,
        .digest = digest_text,
        .byte_length = bytes.len,
        .executable = if (std.Io.File.Permissions.has_executable_bit) stat.permissions.toMode() & 0o111 != 0 else false,
    });
    blobs.appendAssumeCapacity(.{ .bytes = bytes, .object = object });
}

fn entryLessThan(_: void, a: tree.Entry, b: tree.Entry) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

fn pathLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
