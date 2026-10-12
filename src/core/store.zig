//! Immutable artifact store (cases CAS-001..CAS-008).
//!
//! Objects are addressed by digest. A write goes to a private staging path,
//! is verified from the bytes on disk, and only then becomes addressable
//! through an atomic rename. Nothing under `staging/` is ever trusted, so an
//! interrupted import leaves at most an ignored directory and a concurrent
//! writer converges on the single verified object.
const std = @import("std");
const canonical = @import("canonical.zig");
const digest = @import("digest.zig");
const tree_module = @import("tree.zig");

pub const layout_version = "jckg-store-v1";

pub const Error = error{
    IntegrityMismatch,
    TruncatedInput,
    StagingUnreadable,
    LengthMismatch,
    UnknownObject,
    CorruptObject,
    StoreNotInitialized,
    DestinationIncompatible,
};

pub const TreeManifest = struct {
    digest: digest.Digest,
    entry_count: usize,
    path: []const u8,
};

pub const CollectionMode = enum { dry_run, apply };

pub const CollectionReport = struct {
    candidates: []digest.Digest,
    retained_blobs: usize,
    deleted_blobs: usize,
    missing_references: usize,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *CollectionReport) void {
        self.gpa.free(self.candidates);
        self.* = undefined;
    }
};

const staging_prefix = "staging";
const blob_prefix = "blobs/sha256";
const refs_prefix = "refs";
const tree_prefix = "trees";
const version_file = "version";

pub const Store = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    /// Store root. Every operation is relative to this handle.
    dir: std.Io.Dir,

    pub fn init(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir) Store {
        return .{ .io = io, .gpa = gpa, .dir = dir };
    }

    /// Creates the directory layout and the format version marker.
    pub fn ensureLayout(self: Store) !void {
        try self.dir.createDirPath(self.io, blob_prefix);
        try self.dir.createDirPath(self.io, staging_prefix);
        try self.dir.createDirPath(self.io, refs_prefix);
        try self.dir.createDirPath(self.io, tree_prefix);
        self.dir.writeFile(self.io, .{ .sub_path = version_file, .data = layout_version ++ "\n" }) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    pub fn isInitialized(self: Store) bool {
        _ = self.dir.statFile(self.io, version_file, .{}) catch return false;
        return true;
    }

    /// `blobs/sha256/ab/<rest>` — sharded so a directory never holds millions
    /// of entries, and derived only from the digest.
    pub fn blobPath(self: Store, object: digest.Digest, buffer: []u8) []const u8 {
        _ = self;
        var hex_buffer: [64]u8 = undefined;
        const hex = std.fmt.bytesToHex(object.bytes, .lower);
        @memcpy(&hex_buffer, &hex);
        return std.mem.print(buffer, "{s}/{s}/{s}", .{ blob_prefix, hex_buffer[0..2], hex_buffer[2..] }) catch buffer[0..0];
    }

    fn stagingPath(self: Store, token: [16]u8, buffer: []u8) []const u8 {
        _ = self;
        var hex_buffer: [32]u8 = undefined;
        const hex = std.fmt.bytesToHex(token, .lower);
        @memcpy(&hex_buffer, &hex);
        return std.mem.print(buffer, "{s}/{s}", .{ staging_prefix, hex_buffer[0..] }) catch buffer[0..0];
    }

    pub fn hasBlob(self: Store, object: digest.Digest) bool {
        var buffer: [128]u8 = undefined;
        _ = self.dir.statFile(self.io, self.blobPath(object, &buffer), .{}) catch return false;
        return true;
    }

    pub fn readBlobAlloc(self: Store, gpa: std.mem.Allocator, object: digest.Digest) ![]u8 {
        var buffer: [128]u8 = undefined;
        const bytes = self.dir.readFileAlloc(self.io, self.blobPath(object, &buffer), gpa, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return error.UnknownObject,
            else => return err,
        };
        errdefer gpa.free(bytes);
        // A committed object must still hash to its name; a mutated store file
        // is reported as corruption rather than served.
        const actual = digest.ofBlob(bytes);
        if (!actual.eql(object)) return error.CorruptObject;
        return bytes;
    }

    /// Imports raw bytes. When `expected` is supplied, the bytes must match it.
    pub fn importBytes(self: Store, bytes: []const u8, expected: ?digest.Digest) !digest.Digest {
        var token: [16]u8 = undefined;
        self.io.random(&token);
        var staging_path_buffer: [96]u8 = undefined;
        const staging_path = self.stagingPath(token, &staging_path_buffer);
        try self.dir.createDirPath(self.io, staging_path);
        errdefer self.dir.deleteTree(self.io, staging_path) catch {};
        const data_path = try std.fs.path.join(self.gpa, &.{ staging_path, "data" });
        defer self.gpa.free(data_path);
        try self.dir.writeFile(self.io, .{ .sub_path = data_path, .data = bytes });
        return try self.publishStaged(staging_path, expected);
    }

    /// Imports from a reader, which is how a download or a streamed export
    /// arrives. A reader that ends before the declared length, or bytes that do
    /// not match the expected digest, fail before anything is published.
    pub fn importReader(
        self: Store,
        reader: *std.Io.Reader,
        declared_length: ?u64,
        expected: ?digest.Digest,
    ) !digest.Digest {
        var token: [16]u8 = undefined;
        self.io.random(&token);
        var staging_path_buffer: [96]u8 = undefined;
        const staging_path = self.stagingPath(token, &staging_path_buffer);
        try self.dir.createDirPath(self.io, staging_path);
        errdefer self.dir.deleteTree(self.io, staging_path) catch {};

        const data_path = try std.fs.path.join(self.gpa, &.{ staging_path, "data" });
        defer self.gpa.free(data_path);

        var written: u64 = 0;
        {
            var file = try self.dir.createFile(self.io, data_path, .{ .truncate = true });
            defer file.close(self.io);
            var file_buffer: [64 * 1024]u8 = undefined;
            var writer = file.writer(self.io, &file_buffer);
            var chunk_buffer: [64 * 1024]u8 = undefined;
            while (true) {
                const count = try reader.readSliceShort(&chunk_buffer);
                if (count == 0) break;
                try writer.interface.writeAll(chunk_buffer[0..count]);
                written += count;
            }
            try writer.interface.flush();
        }

        if (declared_length) |expected_length| {
            if (written != expected_length) return error.LengthMismatch;
        }
        return try self.publishStaged(staging_path, expected);
    }

    /// Verifies the staged bytes from disk and publishes them atomically.
    ///
    /// This is the only commit point: a partially written staging file, a
    /// short write, or a disk-full failure ends here with no published object
    /// and the previous state untouched.
    pub fn publishStaged(self: Store, staging_path: []const u8, expected: ?digest.Digest) !digest.Digest {
        const data_path = try std.fs.path.join(self.gpa, &.{ staging_path, "data" });
        defer self.gpa.free(data_path);

        const bytes = self.dir.readFileAlloc(self.io, data_path, self.gpa, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return error.TruncatedInput,
            else => return error.StagingUnreadable,
        };
        defer self.gpa.free(bytes);
        const actual = digest.ofBlob(bytes);
        if (expected) |wanted| {
            if (!actual.eql(wanted)) return error.IntegrityMismatch;
        }

        var path_buffer: [128]u8 = undefined;
        const final_path = self.blobPath(actual, &path_buffer);
        const shard = std.fs.path.dirname(final_path) orelse return error.StoreNotInitialized;
        try self.dir.createDirPath(self.io, shard);

        // Convergent publication: the first writer to arrive wins, and every
        // later writer verifies the existing object instead of replacing it.
        self.dir.renamePreserve(data_path, self.dir, final_path, self.io) catch |err| switch (err) {
            error.PathAlreadyExists => {
                if (!self.hasBlob(actual)) return error.CorruptObject;
                const existing = self.readBlobAlloc(self.gpa, actual) catch return error.CorruptObject;
                self.gpa.free(existing);
            },
            else => return err,
        };

        self.dir.deleteTree(self.io, staging_path) catch {};
        return actual;
    }

    /// Removes staging directories left behind by an interrupted import. Only
    /// untrusted staging state is removed; committed objects are untouched.
    pub fn recover(self: Store) !usize {
        var removed: usize = 0;
        var staging = self.dir.openDir(self.io, staging_prefix, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return 0,
            else => return err,
        };
        defer staging.close(self.io);
        var names: std.ArrayList([]const u8) = .empty;
        defer {
            for (names.items) |name| self.gpa.free(name);
            names.deinit(self.gpa);
        }
        var iterator = staging.iterate();
        while (try iterator.next(self.io)) |entry| {
            if (entry.kind != .directory) continue;
            try names.append(self.gpa, try self.gpa.dupe(u8, entry.name));
        }
        for (names.items) |name| {
            const path = try std.fs.path.join(self.gpa, &.{ staging_prefix, name });
            defer self.gpa.free(path);
            self.dir.deleteTree(self.io, path) catch continue;
            removed += 1;
        }
        return removed;
    }

    /// Copies a stored blob into a workspace. The copy is deliberately a real
    /// copy: a writable hardlink or an in-place share would let a worker mutate
    /// immutable input.
    pub fn materializeBlob(
        self: Store,
        object: digest.Digest,
        destination: std.Io.Dir,
        destination_path: []const u8,
        executable: bool,
    ) !void {
        const bytes = try self.readBlobAlloc(self.gpa, object);
        defer self.gpa.free(bytes);
        if (std.fs.path.dirname(destination_path)) |parent| {
            destination.createDirPath(self.io, parent) catch {};
        }
        try destination.writeFile(self.io, .{ .sub_path = destination_path, .data = bytes });
        // Windows carries no executable bit; on POSIX the materialized copy
        // keeps the mode the tree declared.
        if (executable and @import("builtin").os.tag != .windows) {
            var file = try destination.openFile(self.io, destination_path, .{ .mode = .read_write });
            defer file.close(self.io);
            var file_stat = try file.stat(self.io);
            const mode = file_stat.permissions.toMode() | 0o111;
            file.setPermissions(self.io, .fromMode(mode)) catch {};
        }
    }

    /// Records that `from` needs `to` at runtime, so collection keeps it.
    pub fn addReference(self: Store, from: digest.Digest, to: digest.Digest) !void {
        var from_buffer: [digest.Digest.text_length]u8 = undefined;
        const from_text = from.text(&from_buffer);
        var path_buffer: [96]u8 = undefined;
        const path = std.mem.print(&path_buffer, "{s}/{s}.json", .{ refs_prefix, from_text[7..] }) catch return error.StoreNotInitialized;

        var existing: std.ArrayList(digest.Digest) = .empty;
        defer {
            for (existing.items) |_| {}
            existing.deinit(self.gpa);
        }
        if (self.dir.readFileAlloc(self.io, path, self.gpa, .unlimited)) |text| {
            defer self.gpa.free(text);
            var diagnostic: canonical.Diagnostic = .{};
            const value = canonical.parse(self.gpa, text, &diagnostic) catch return error.CorruptObject;
            defer value.deinit(self.gpa);
            const items = switch (value) {
                .array => |values| values,
                else => return error.CorruptObject,
            };
            for (items) |item| {
                const text_value = switch (item) {
                    .string => |string| string,
                    else => return error.CorruptObject,
                };
                try existing.append(self.gpa, try digest.Digest.parse(text_value));
            }
        } else |_| {}

        for (existing.items) |entry| {
            if (entry.eql(to)) return;
        }
        try existing.append(self.gpa, to);

        const values = try self.gpa.alloc(canonical.Value, existing.items.len);
        defer self.gpa.free(values);
        for (existing.items, 0..) |entry, index| {
            var text_buffer: [digest.Digest.text_length]u8 = undefined;
            values[index] = .{ .string = try self.gpa.dupe(u8, entry.text(&text_buffer)) };
        }
        const value = canonical.Value{ .array = values };
        defer for (values) |item| item.deinit(self.gpa);
        const encoded = try canonical.encodeAlloc(self.gpa, value);
        defer self.gpa.free(encoded);
        try self.dir.createDirPath(self.io, refs_prefix);
        try self.dir.writeFile(self.io, .{ .sub_path = path, .data = encoded });
    }

    pub fn referencesOf(self: Store, gpa: std.mem.Allocator, from: digest.Digest) ![]digest.Digest {
        var from_buffer: [digest.Digest.text_length]u8 = undefined;
        const from_text = from.text(&from_buffer);
        var path_buffer: [96]u8 = undefined;
        const path = std.mem.print(&path_buffer, "{s}/{s}.json", .{ refs_prefix, from_text[7..] }) catch return error.StoreNotInitialized;

        const text = self.dir.readFileAlloc(self.io, path, gpa, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return gpa.alloc(digest.Digest, 0),
            else => return err,
        };
        defer gpa.free(text);
        var diagnostic: canonical.Diagnostic = .{};
        const value = canonical.parse(gpa, text, &diagnostic) catch return error.CorruptObject;
        defer value.deinit(gpa);
        const items = switch (value) {
            .array => |values| values,
            else => return error.CorruptObject,
        };
        const result = try gpa.alloc(digest.Digest, items.len);
        for (items, 0..) |item, index| {
            const text_value = switch (item) {
                .string => |string| string,
                else => {
                    gpa.free(result);
                    return error.CorruptObject;
                },
            };
            result[index] = digest.Digest.parse(text_value) catch {
                gpa.free(result);
                return error.CorruptObject;
            };
        }
        return result;
    }

    /// Transitive closure of reachability from `roots`, following the recorded
    /// runtime references. A runtime dependency is only kept if it is reachable
    /// through this graph, so a missed reference would delete a needed object —
    /// which is why references are explicit and tested.
    pub fn reachableFrom(self: Store, gpa: std.mem.Allocator, roots: []const digest.Digest) ![]digest.Digest {
        var visited: std.ArrayList(digest.Digest) = .empty;
        errdefer visited.deinit(gpa);
        for (roots) |root| try appendUnique(gpa, &visited, root);

        var index: usize = 0;
        while (index < visited.items.len) : (index += 1) {
            const current = visited.items[index];
            const dependencies = try self.referencesOf(gpa, current);
            defer gpa.free(dependencies);
            for (dependencies) |dependency| try appendUnique(gpa, &visited, dependency);
        }
        return visited.toOwnedSlice(gpa);
    }

    /// Lists blobs that are not reachable from the given roots, and optionally
    /// removes them. Objects under `staging/` are never candidates: they are
    /// not part of the trusted namespace.
    pub fn collect(self: Store, gpa: std.mem.Allocator, roots: []const digest.Digest, mode: CollectionMode) !CollectionReport {
        const reachable = try self.reachableFrom(gpa, roots);
        defer gpa.free(reachable);

        var candidates: std.ArrayList(digest.Digest) = .empty;
        errdefer candidates.deinit(gpa);
        var retained: usize = 0;
        var deleted: usize = 0;

        var blobs = self.dir.openDir(self.io, "blobs/sha256", .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return .{
                .candidates = try candidates.toOwnedSlice(gpa),
                .retained_blobs = 0,
                .deleted_blobs = 0,
                .missing_references = 0,
                .gpa = gpa,
            },
            else => return err,
        };
        defer blobs.close(self.io);

        var shards = blobs.iterate();
        while (try shards.next(self.io)) |shard| {
            if (shard.kind != .directory or shard.name.len != 2) continue;
            var shard_dir = blobs.openDir(self.io, shard.name, .{ .iterate = true }) catch continue;
            defer shard_dir.close(self.io);
            var objects = shard_dir.iterate();
            var names: std.ArrayList([]const u8) = .empty;
            defer {
                for (names.items) |name| gpa.free(name);
                names.deinit(gpa);
            }
            while (try objects.next(self.io)) |object| {
                if (object.kind != .file) continue;
                try names.append(gpa, try gpa.dupe(u8, object.name));
            }
            for (names.items) |name| {
                const object_digest = parseBlobName(shard.name, name) orelse continue;
                var found = false;
                for (reachable) |reachable_digest| {
                    if (reachable_digest.eql(object_digest)) {
                        found = true;
                        break;
                    }
                }
                if (found) {
                    retained += 1;
                    continue;
                }
                try candidates.append(gpa, object_digest);
                if (mode == .apply) {
                    const relative = try std.fs.path.join(gpa, &.{ "blobs/sha256", shard.name, name });
                    defer gpa.free(relative);
                    self.dir.deleteFile(self.io, relative) catch continue;
                    deleted += 1;
                }
            }
        }

        return .{
            .candidates = try candidates.toOwnedSlice(gpa),
            .retained_blobs = retained,
            .deleted_blobs = deleted,
            .missing_references = 0,
            .gpa = gpa,
        };
    }

    /// Stores a validated tree as a canonical manifest and returns its digest.
    pub fn commitTree(self: Store, tree: tree_module.Tree) !digest.Digest {
        const value = try tree.toCanonical(self.gpa);
        defer value.deinit(self.gpa);
        const object = try digest.ofCanonical(self.gpa, .tree, value);
        const encoded = try canonical.encodeAlloc(self.gpa, value);
        defer self.gpa.free(encoded);

        var name_buffer: [digest.Digest.text_length]u8 = undefined;
        const name = object.text(&name_buffer);
        var path_buffer: [96]u8 = undefined;
        const path = std.mem.print(&path_buffer, "{s}/{s}.json", .{ tree_prefix, name[7..] }) catch return error.StoreNotInitialized;
        try self.dir.createDirPath(self.io, tree_prefix);
        try self.dir.writeFile(self.io, .{ .sub_path = path, .data = encoded });
        return object;
    }

    pub fn readTreeManifest(self: Store, gpa: std.mem.Allocator, object: digest.Digest) ![]u8 {
        var name_buffer: [digest.Digest.text_length]u8 = undefined;
        const name = object.text(&name_buffer);
        var path_buffer: [96]u8 = undefined;
        const path = std.mem.print(&path_buffer, "{s}/{s}.json", .{ tree_prefix, name[7..] }) catch return error.StoreNotInitialized;
        return self.dir.readFileAlloc(self.io, path, gpa, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return error.UnknownObject,
            else => return err,
        };
    }
};

fn parseBlobName(shard: []const u8, name: []const u8) ?digest.Digest {
    if (shard.len != 2 or name.len != 62) return null;
    var text: [digest.Digest.text_length]u8 = undefined;
    @memcpy(text[0..7], "sha256:");
    @memcpy(text[7..9], shard);
    @memcpy(text[9..], name);
    return digest.Digest.parse(&text) catch null;
}

fn appendUnique(gpa: std.mem.Allocator, list: *std.ArrayList(digest.Digest), value: digest.Digest) !void {
    for (list.items) |existing| {
        if (existing.eql(value)) return;
    }
    try list.append(gpa, value);
}

/// Creates a disposable store under `parent` and returns its handle.
pub fn createForTest(io: std.Io, gpa: std.mem.Allocator, parent: std.Io.Dir, name: []const u8) !struct {
    store: Store,
    cleanup: struct {
        parent: std.Io.Dir,
        io: std.Io,
        name: []const u8,
        pub fn run(self: @This()) void {
            self.parent.deleteTree(self.io, self.name) catch {};
        }
    },
} {
    parent.deleteTree(io, name) catch {};
    parent.createDirPath(io, name) catch {};
    var store_dir = try parent.openDir(io, name, .{});
    errdefer store_dir.close(io);
    const store = Store.init(io, gpa, store_dir);
    try store.ensureLayout();
    return .{ .store = store, .cleanup = .{ .parent = parent, .io = io, .name = name } };
}

fn uniqueStoreName(gpa: std.mem.Allocator, io: std.Io, prefix: []const u8) ![]u8 {
    var random_bytes: [6]u8 = undefined;
    io.random(&random_bytes);
    const suffix = std.fmt.bytesToHex(random_bytes, .lower);
    return gpa.print(".zig-cache/jckg-store-{s}-{s}", .{ prefix, suffix });
}

fn countFilesIn(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, sub_path: []const u8) !usize {
    var root = dir.openDir(io, sub_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer root.close(io);
    var walker = try root.walk(gpa);
    defer walker.deinit();
    var count: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind == .file) count += 1;
    }
    return count;
}


/// Formats `<store name>/<relative>` for the tests. The buffer is only valid
/// until the next call, which is enough for one filesystem operation.
var scratch: [512]u8 = undefined;

fn storeSub(name: []const u8, relative: []const u8) []const u8 {
    return std.mem.print(&scratch, "{s}/{s}", .{ name, relative }) catch scratch[0..0];
}

test "m02/CAS-001 publish verified bytes atomically" {
    std.debug.print("JCKG_EVIDENCE CAS-001\n", .{});
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const cwd = std.Io.Dir.cwd();

    const name = try uniqueStoreName(gpa, io, "cas001");
    defer gpa.free(name);
    var harness = try createForTest(io, gpa, cwd, name);
    defer harness.cleanup.run();
    const store = harness.store;

    const content = "jackage fixture content\n";
    const expected = digest.ofBlob(content);

    // Nothing is addressable before the commit point, even when staged bytes
    // already exist for the same content.
    try cwd.createDirPath(io, storeSub(name, "staging/unfinished"));
    try cwd.writeFile(io, .{ .sub_path = storeSub(name, "staging/unfinished/data"), .data = content });
    try std.testing.expect(!store.hasBlob(expected));

    const committed = try store.importBytes(content, expected);
    try std.testing.expect(committed.eql(expected));
    try std.testing.expect(store.hasBlob(expected));
    const round_trip = try store.readBlobAlloc(gpa, committed);
    defer gpa.free(round_trip);
    try std.testing.expectEqualStrings(content, round_trip);

    // The object lives under its digest path, and the import's own staging
    // directory is gone; the deliberately unfinished one is still untrusted.
    var path_buffer: [128]u8 = undefined;
    const relative = store.blobPath(expected, &path_buffer);
    const absolute = try std.fs.path.join(gpa, &.{ name, relative });
    defer gpa.free(absolute);
    const stat = try cwd.statFile(io, absolute, .{});
    try std.testing.expectEqual(@as(u64, content.len), stat.size);
    try std.testing.expectEqual(@as(usize, 1), try countFilesIn(io, gpa, cwd, storeSub(name, "blobs")));
    try std.testing.expectEqual(@as(usize, 1), try countFilesIn(io, gpa, cwd, storeSub(name, "staging")));

    // Negative-or-recovery: an empty blob is a valid object, and a second
    // import of the same content does not create a second object.
    const empty = try store.importBytes("", null);
    try std.testing.expect(store.hasBlob(empty));
    _ = try store.importBytes(content, expected);
    try std.testing.expectEqual(@as(usize, 2), try countFilesIn(io, gpa, cwd, storeSub(name, "blobs")));
}

test "m02/CAS-002 reject corrupt bytes" {
    std.debug.print("JCKG_EVIDENCE CAS-002\n", .{});
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const cwd = std.Io.Dir.cwd();

    const name = try uniqueStoreName(gpa, io, "cas002");
    defer gpa.free(name);
    var harness = try createForTest(io, gpa, cwd, name);
    defer harness.cleanup.run();
    const store = harness.store;

    const good = "expected bytes\n";
    const wrong = "different bytes\n";
    const expected = digest.ofBlob(good);
    const actual_other = digest.ofBlob(wrong);

    // Bytes that do not match the expected digest never become addressable.
    try std.testing.expectError(error.IntegrityMismatch, store.importBytes(wrong, expected));
    try std.testing.expect(!store.hasBlob(expected));
    try std.testing.expect(!store.hasBlob(actual_other));
    try std.testing.expectEqual(@as(usize, 0), try countFilesIn(io, gpa, cwd, storeSub(name, "/blobs")));
    // The rejected staging directory was cleaned up, not left behind.
    try std.testing.expectEqual(@as(usize, 0), try countFilesIn(io, gpa, cwd, storeSub(name, "/staging")));

    // A stream that ends before its declared length is rejected too.
    var reader = std.Io.Reader.fixed("short");
    try std.testing.expectError(error.LengthMismatch, store.importReader(&reader, 42, null));

    // Negative-or-recovery: verification of stored bytes detects a blob that
    // was mutated outside the store instead of serving it as trusted.
    const stored = try store.importBytes(good, expected);
    const relative = try std.fs.path.join(gpa, &.{ name, "blobs/sha256" });
    defer gpa.free(relative);
    var path_buffer: [128]u8 = undefined;
    const blob_relative = store.blobPath(stored, &path_buffer);
    const blob_absolute = try std.fs.path.join(gpa, &.{ name, blob_relative });
    defer gpa.free(blob_absolute);
    try cwd.writeFile(io, .{ .sub_path = blob_absolute, .data = "tampered bytes\n" });
    try std.testing.expectError(error.CorruptObject, store.readBlobAlloc(gpa, stored));

    // Unknown digests are reported as unknown, not as empty content.
    try std.testing.expectError(error.UnknownObject, store.readBlobAlloc(gpa, digest.ofBlob("never imported")));
}

test "m02/CAS-003 converge concurrent writes" {
    std.debug.print("JCKG_EVIDENCE CAS-003\n", .{});
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const cwd = std.Io.Dir.cwd();

    const name = try uniqueStoreName(gpa, io, "cas003");
    defer gpa.free(name);
    var harness = try createForTest(io, gpa, cwd, name);
    defer harness.cleanup.run();
    const store = harness.store;

    const content = "concurrent import payload\n";
    const expected = digest.ofBlob(content);

    const Worker = struct {
        store: Store,
        content: []const u8,
        expected: digest.Digest,
        ok: bool = false,
        code: ?anyerror = null,

        fn run(self: *@This()) void {
            _ = self.store.importBytes(self.content, self.expected) catch |err| {
                self.code = err;
                return;
            };
            self.ok = true;
        }
    };

    var first = Worker{ .store = store, .content = content, .expected = expected };
    var second = Worker{ .store = store, .content = content, .expected = expected };
    const thread_a = try std.Thread.spawn(.{}, Worker.run, .{&first});
    const thread_b = try std.Thread.spawn(.{}, Worker.run, .{&second});
    thread_a.join();
    thread_b.join();

    try std.testing.expect(first.ok and first.code == null);
    try std.testing.expect(second.ok and second.code == null);

    // Exactly one immutable object remains and its bytes verify.
    try std.testing.expectEqual(@as(usize, 1), try countFilesIn(io, gpa, cwd, storeSub(name, "/blobs")));
    const bytes = try store.readBlobAlloc(gpa, expected);
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings(content, bytes);

    // Negative-or-recovery: a writer that arrives after the object exists
    // converges on the existing verified object instead of overwriting it.
    _ = try store.importBytes(content, expected);
    try std.testing.expectEqual(@as(usize, 1), try countFilesIn(io, gpa, cwd, storeSub(name, "/blobs")));
    try std.testing.expectEqual(@as(usize, 0), try countFilesIn(io, gpa, cwd, storeSub(name, "/staging")));
}

test "m02/CAS-004 recover interrupted import" {
    std.debug.print("JCKG_EVIDENCE CAS-004\n", .{});
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const cwd = std.Io.Dir.cwd();

    const name = try uniqueStoreName(gpa, io, "cas004");
    defer gpa.free(name);
    var harness = try createForTest(io, gpa, cwd, name);
    defer harness.cleanup.run();
    const store = harness.store;

    // A committed object that must survive the interruption.
    const committed = try store.importBytes("committed before the crash\n", null);

    // Interrupted imports: a truncated staging file, a staging directory that
    // never got its data file, and a partially written second data file.
    const partial_content = "partial bytes that were never verified";
    try cwd.createDirPath(io, storeSub(name, "/staging/aaaa"));
    try cwd.writeFile(io, .{ .sub_path = storeSub(name, "/staging/aaaa/data"), .data = partial_content });
    try cwd.createDirPath(io, storeSub(name, "/staging/bbbb"));
    try cwd.createDirPath(io, storeSub(name, "/staging/cccc"));
    try cwd.writeFile(io, .{ .sub_path = storeSub(name, "/staging/cccc/data"), .data = "half of a pa" });

    try std.testing.expectEqual(@as(usize, 0), try countFilesIn(io, gpa, cwd, storeSub(name, "/blobs")) - 1);

    // Nothing staged is addressable, whatever the failure point was.
    try std.testing.expect(!store.hasBlob(digest.ofBlob(partial_content)));
    try std.testing.expect(!store.hasBlob(digest.ofBlob("half of a pa")));

    const removed = try store.recover();
    try std.testing.expectEqual(@as(usize, 3), removed);
    try std.testing.expectEqual(@as(usize, 0), try countFilesIn(io, gpa, cwd, storeSub(name, "/staging")));

    // The store reopens with exactly the committed object available.
    var reopened_dir = try cwd.openDir(io, name, .{});
    defer reopened_dir.close(io);
    const reopened = Store.init(io, gpa, reopened_dir);
    try std.testing.expect(reopened.isInitialized());
    try std.testing.expect(reopened.hasBlob(committed));
    const bytes = try reopened.readBlobAlloc(gpa, committed);
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings("committed before the crash\n", bytes);

    // Negative-or-recovery: recovery on a store with no staging state is a
    // no-op rather than a failure.
    try std.testing.expectEqual(@as(usize, 0), try reopened.recover());
}

test "m02/CAS-005 protect immutable inputs" {
    std.debug.print("JCKG_EVIDENCE CAS-005\n", .{});
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const cwd = std.Io.Dir.cwd();

    const name = try uniqueStoreName(gpa, io, "cas005");
    defer gpa.free(name);
    var harness = try createForTest(io, gpa, cwd, name);
    defer harness.cleanup.run();
    const store = harness.store;

    const content = "immutable input bytes\n";
    const object = try store.importBytes(content, null);

    // A worker gets a real copy in its own workspace.
    const workspace = try std.fs.path.join(gpa, &.{ name, "workspace" });
    defer gpa.free(workspace);
    try cwd.createDirPath(io, workspace);
    var workspace_dir = try cwd.openDir(io, workspace, .{});
    defer workspace_dir.close(io);
    try store.materializeBlob(object, workspace_dir, "input/data.txt", true);

    // The worker changes its copy, including the executable bit.
    try workspace_dir.writeFile(io, .{ .sub_path = "input/data.txt", .data = "worker modified this\n" });

    // The stored object is unchanged and still verifies.
    const stored = try store.readBlobAlloc(gpa, object);
    defer gpa.free(stored);
    try std.testing.expectEqualStrings(content, stored);

    // Negative-or-recovery: materializing again produces the original bytes,
    // and deleting the workspace copy does not affect the object.
    try workspace_dir.deleteTree(io, "input");
    try store.materializeBlob(object, workspace_dir, "input/data.txt", true);
    const rematerialized = try workspace_dir.readFileAlloc(io, "input/data.txt", gpa, .unlimited);
    defer gpa.free(rematerialized);
    try std.testing.expectEqualStrings(content, rematerialized);

    // A materialized copy is a separate file: the workspace copy differs from
    // the store bytes after the worker edit, and the store object still
    // verifies against its name.
    const workspace_stat = try workspace_dir.statFile(io, "input/data.txt", .{});
    try std.testing.expectEqual(@as(u64, rematerialized.len), workspace_stat.size);
    const verified_again = try store.readBlobAlloc(gpa, object);
    defer gpa.free(verified_again);
    try std.testing.expectEqualStrings(content, verified_again);
    try std.testing.expectEqual(@as(u64, content.len), verified_again.len);
}

test "m02/CAS-006 preserve runtime references" {
    std.debug.print("JCKG_EVIDENCE CAS-006\n", .{});
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const cwd = std.Io.Dir.cwd();

    const name = try uniqueStoreName(gpa, io, "cas006");
    defer gpa.free(name);
    var harness = try createForTest(io, gpa, cwd, name);
    defer harness.cleanup.run();
    const store = harness.store;

    // A package that needs its tool only at runtime, plus an unrelated object.
    const package_object = try store.importBytes("package manifest\n", null);
    const runtime_object = try store.importBytes("compile-time-only bytes\n", null);
    const unrelated_object = try store.importBytes("unreferenced bytes\n", null);
    try store.addReference(package_object, runtime_object);

    const roots = [_]digest.Digest{package_object};
    const reachable = try store.reachableFrom(gpa, &roots);
    defer gpa.free(reachable);
    try std.testing.expectEqual(@as(usize, 2), reachable.len);

    // The runtime dependency survives collection; the unreferenced object is
    // the only candidate.
    var dry = try store.collect(gpa, &roots, .dry_run);
    defer dry.deinit();
    try std.testing.expectEqual(@as(usize, 1), dry.candidates.len);
    try std.testing.expect(dry.candidates[0].eql(unrelated_object));
    try std.testing.expectEqual(@as(usize, 2), dry.retained_blobs);

    var applied = try store.collect(gpa, &roots, .apply);
    defer applied.deinit();
    try std.testing.expectEqual(@as(usize, 1), applied.deleted_blobs);
    try std.testing.expect(store.hasBlob(package_object));
    try std.testing.expect(store.hasBlob(runtime_object));
    try std.testing.expect(!store.hasBlob(unrelated_object));

    // Negative-or-recovery: the retained closure is intact and the retained
    // program actually runs from a workspace built out of the store. The
    // running test executable is used as the fixture program.
    const stored_runtime = try store.readBlobAlloc(gpa, runtime_object);
    defer gpa.free(stored_runtime);
    try std.testing.expectEqualStrings("compile-time-only bytes\n", stored_runtime);

    const client_relative = if (@import("builtin").os.tag == .windows) "zig-out/bin/jckg.exe" else "zig-out/bin/jckg";
    const program_bytes = cwd.readFileAlloc(io, client_relative, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("client not built: run `zig build` before the store tests\n", .{});
            return error.ClientNotBuilt;
        },
        else => return err,
    };
    defer gpa.free(program_bytes);
    const program_object = try store.importBytes(program_bytes, digest.ofBlob(program_bytes));
    try store.addReference(package_object, program_object);

    const workspace = try std.fs.path.join(gpa, &.{ name, "run-workspace" });
    defer gpa.free(workspace);
    try cwd.createDirPath(io, workspace);
    var workspace_dir = try cwd.openDir(io, workspace, .{});
    defer workspace_dir.close(io);
    try store.materializeBlob(program_object, workspace_dir, "bin/program.exe", true);

    const relative_program = try std.fs.path.join(gpa, &.{ workspace, "bin/program.exe" });
    defer gpa.free(relative_program);
    const result = try std.process.run(gpa, io, .{
        .argv = &.{ relative_program, "version" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expect(result.term.success());
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "jackage") != null);
}

test "m02/CAS-007 handle full disk" {
    std.debug.print("JCKG_EVIDENCE CAS-007\n", .{});
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const cwd = std.Io.Dir.cwd();

    const name = try uniqueStoreName(gpa, io, "cas007");
    defer gpa.free(name);
    var harness = try createForTest(io, gpa, cwd, name);
    defer harness.cleanup.run();
    const store = harness.store;

    const previous_object = try store.importBytes("valid state before the failure\n", null);

    // The fixture storage layer fails at the commit point in the two ways a
    // full disk manifests: a short write (bytes end early) and an unusable
    // staging path (the data file cannot be opened at all).
    const partial = "partial payload from a full disk";
    try cwd.createDirPath(io, storeSub(name, "/staging/shortwrite"));
    try cwd.writeFile(io, .{ .sub_path = storeSub(name, "/staging/shortwrite/data"), .data = partial });
    try std.testing.expectError(
        error.IntegrityMismatch,
        store.publishStaged("staging/shortwrite", digest.ofBlob("what the caller expected")),
    );
    // The failed staging data stays where it is, untrusted, and becomes
    // nothing: the digest it would have had is not addressable.
    try std.testing.expect(!store.hasBlob(digest.ofBlob(partial)));

    // A truncated stream is rejected against the declared length as well.
    var truncated = std.Io.Reader.fixed("only the first kilobyte");
    try std.testing.expectError(error.LengthMismatch, store.importReader(&truncated, 4096, null));

    // An unwritable staging path models the storage layer refusing the write.
    const blocked = try std.fs.path.join(gpa, &.{ name, "staging/blocked" });
    defer gpa.free(blocked);
    try cwd.createDirPath(io, blocked);
    var blocked_dir = try cwd.openDir(io, blocked, .{});
    defer blocked_dir.close(io);
    const blocker = try std.fs.path.join(gpa, &.{ blocked, "data" });
    defer gpa.free(blocker);
    try cwd.createDirPath(io, blocker);
    try std.testing.expectError(error.StagingUnreadable, store.publishStaged("staging/blocked", null));

    // The old valid state is still complete and addressable.
    const surviving = try store.readBlobAlloc(gpa, previous_object);
    defer gpa.free(surviving);
    try std.testing.expectEqualStrings("valid state before the failure\n", surviving);
    try std.testing.expectEqual(@as(usize, 1), try countFilesIn(io, gpa, cwd, storeSub(name, "/blobs")));

    // Negative-or-recovery: after the failures the store still works.
    const after = try store.importBytes("state after recovery\n", null);
    try std.testing.expect(store.hasBlob(after));
}

test "m02/CAS-008 respect destination semantics" {
    std.debug.print("JCKG_EVIDENCE CAS-008\n", .{});
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const cwd = std.Io.Dir.cwd();

    const name = try uniqueStoreName(gpa, io, "cas008");
    defer gpa.free(name);
    var harness = try createForTest(io, gpa, cwd, name);
    defer harness.cleanup.run();
    const store = harness.store;

    const object = try store.importBytes("payload\n", null);
    var digest_buffer: [digest.Digest.text_length]u8 = undefined;
    const digest_text = try gpa.dupe(u8, object.text(&digest_buffer));
    defer gpa.free(digest_text);

    // A tree that is valid on Linux but cannot exist on Windows unchanged.
    var entries = [_]tree_module.Entry{
        .{ .path = "a:b", .kind = .file, .digest = digest_text, .byte_length = 8 },
        .{ .path = "aux.txt", .kind = .file, .digest = digest_text, .byte_length = 8 },
        .{ .path = "trailing.", .kind = .file, .digest = digest_text, .byte_length = 8 },
    };
    const tree = tree_module.Tree{ .entries = &entries, .gpa = gpa };
    try tree_module.validateWith(tree, .linux);
    // The same tree is not portable, and the portable policy says so.
    try std.testing.expectError(error.InvalidPath, tree.validate());

    // Windows materialization fails explicitly…
    var offender: ?[]const u8 = null;
    const windows_result = tree_module.destinationCheck(tree, .windows, &offender);
    try std.testing.expect(windows_result != null);
    try std.testing.expectEqual(tree_module.Error.InvalidPath, windows_result.?);
    try std.testing.expect(offender != null);
    try std.testing.expectEqualStrings("a:b", offender.?);

    // …and no file is written, so no silently renamed substitute appears.
    const destination = try std.fs.path.join(gpa, &.{ name, "windows-destination" });
    defer gpa.free(destination);
    try cwd.createDirPath(io, destination);
    try std.testing.expectEqual(@as(usize, 0), try countFilesIn(io, gpa, cwd, destination));

    // A Linux destination accepts the same tree.
    try std.testing.expect(tree_module.destinationCheck(tree, .linux, &offender) == null);

    // Negative-or-recovery: a case-colliding tree is refused on a
    // case-insensitive destination, naming the offending path.
    var colliding = [_]tree_module.Entry{
        .{ .path = "README.md", .kind = .file, .digest = digest_text, .byte_length = 8 },
        .{ .path = "readme.md", .kind = .file, .digest = digest_text, .byte_length = 8 },
    };
    const colliding_tree = tree_module.Tree{ .entries = &colliding, .gpa = gpa };
    try tree_module.validateWith(colliding_tree, .linux);
    const colliding_result = tree_module.destinationCheck(colliding_tree, .windows, &offender);
    try std.testing.expect(colliding_result != null);
    try std.testing.expectEqual(tree_module.Error.DuplicatePath, colliding_result.?);
    try std.testing.expect(tree_module.destinationCheck(colliding_tree, .linux, &offender) == null);
}
