//! Protected-file record for the pre-existing checkout (audit case AUD-001).
//!
//! Recorded before the first product edit. `preserved` files must remain
//! byte-identical; `extended` files (the build graph) may grow, but the
//! recorded anchor lines must survive so a rewrite cannot pass unnoticed.
const std = @import("std");

pub const Class = enum { preserved, extended };

pub const Record = struct {
    path: []const u8,
    class: Class,
    digest_hex: [64]u8,
    size_bytes: u64,
    anchors: [][]const u8,
};

pub const Manifest = struct {
    recorded_utc: []const u8,
    files: []Record,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Manifest) void {
        self.gpa.free(self.recorded_utc);
        for (self.files) |file| {
            self.gpa.free(file.path);
            for (file.anchors) |anchor| self.gpa.free(anchor);
            self.gpa.free(file.anchors);
        }
        self.gpa.free(self.files);
        self.* = undefined;
    }

    pub fn find(self: Manifest, path: []const u8) ?*Record {
        for (self.files) |*file| {
            if (std.mem.eql(u8, file.path, path)) return file;
        }
        return null;
    }
};

pub const VerifyError = error{
    InvalidManifest,
    InvalidDigest,
    MissingFile,
    UnreadableFile,
    ContentChanged,
    SizeChanged,
    MissingAnchor,
};

fn parseDigest(raw: []const u8) VerifyError![64]u8 {
    const prefix = "sha256:";
    if (!std.mem.startsWith(u8, raw, prefix)) return error.InvalidDigest;
    const hex = raw[prefix.len..];
    if (hex.len != 64) return error.InvalidDigest;
    var out: [64]u8 = undefined;
    for (hex, 0..) |character, index| {
        const lower = std.ascii.toLower(character);
        if (!std.ascii.isHex(lower)) return error.InvalidDigest;
        out[index] = lower;
    }
    return out;
}

pub fn parse(gpa: std.mem.Allocator, text: []const u8) (VerifyError || std.mem.Allocator.Error)!Manifest {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidManifest,
    };
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidManifest;

    const recorded = root.object.get("recordedUtc") orelse return error.InvalidManifest;
    if (recorded != .string) return error.InvalidManifest;
    const recorded_utc = try gpa.dupe(u8, recorded.string);
    errdefer gpa.free(recorded_utc);

    const files_value = root.object.get("files") orelse return error.InvalidManifest;
    if (files_value != .array) return error.InvalidManifest;

    var files: std.ArrayList(Record) = .empty;
    errdefer {
        for (files.items) |file| {
            gpa.free(file.path);
            for (file.anchors) |anchor| gpa.free(anchor);
            gpa.free(file.anchors);
        }
        files.deinit(gpa);
    }

    for (files_value.array.items) |item| {
        if (item != .object) return error.InvalidManifest;
        const path_value = item.object.get("path") orelse return error.InvalidManifest;
        const digest_value = item.object.get("sha256") orelse return error.InvalidManifest;
        if (path_value != .string or digest_value != .string) return error.InvalidManifest;

        const class: Class = if (item.object.get("class")) |class_value| blk: {
            if (class_value != .string) return error.InvalidManifest;
            if (std.mem.eql(u8, class_value.string, "preserved")) break :blk .preserved;
            if (std.mem.eql(u8, class_value.string, "extended")) break :blk .extended;
            return error.InvalidManifest;
        } else .preserved;

        var size_bytes: u64 = 0;
        if (item.object.get("sizeBytes")) |size_value| {
            if (size_value != .integer or size_value.integer < 0) return error.InvalidManifest;
            size_bytes = @intCast(size_value.integer);
        }

        var anchors: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (anchors.items) |anchor| gpa.free(anchor);
            anchors.deinit(gpa);
        }
        if (item.object.get("anchors")) |anchors_value| {
            if (anchors_value != .array) return error.InvalidManifest;
            for (anchors_value.array.items) |anchor| {
                if (anchor != .string) return error.InvalidManifest;
                try anchors.append(gpa, try gpa.dupe(u8, anchor.string));
            }
        }

        try files.append(gpa, .{
            .path = try gpa.dupe(u8, path_value.string),
            .class = class,
            .digest_hex = try parseDigest(digest_value.string),
            .size_bytes = size_bytes,
            .anchors = try anchors.toOwnedSlice(gpa),
        });
    }

    return .{
        .recorded_utc = recorded_utc,
        .files = try files.toOwnedSlice(gpa),
        .gpa = gpa,
    };
}

/// Verifies every record against the bytes currently in `dir`.
///
/// The first mismatch is reported; verification never writes to the checkout.
pub fn verify(io: std.Io, dir: std.Io.Dir, manifest: Manifest) VerifyError!void {
    for (manifest.files) |record| {
        const bytes = dir.readFileAlloc(io, record.path, manifest.gpa, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return error.MissingFile,
            else => return error.UnreadableFile,
        };
        defer manifest.gpa.free(bytes);

        switch (record.class) {
            .preserved => {
                const actual = digestHexOf(bytes);
                if (!std.mem.eql(u8, &actual, &record.digest_hex)) return error.ContentChanged;
                if (record.size_bytes != 0 and bytes.len != record.size_bytes) return error.SizeChanged;
            },
            .extended => {
                for (record.anchors) |anchor| {
                    if (std.mem.indexOf(u8, bytes, anchor) == null) return error.MissingAnchor;
                }
            },
        }
    }
}

fn digestHexOf(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

const manifest_path = ".jackage-delivery/state/baseline/protected-files.json";

test "AUD-001 preserve the existing checkout" {
    std.debug.print("JCKG_EVIDENCE AUD-001\n", .{});
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const text = try cwd.readFileAlloc(io, manifest_path, gpa, .unlimited);
    defer gpa.free(text);

    var manifest = try parse(gpa, text);
    defer manifest.deinit();

    const expected = [_][]const u8{
        ".gitignore",
        ".zigversion",
        "build.zig",
        "build.zig.zon",
        "scripts/fetch-zig.ps1",
        "scripts/zig.ps1",
        "src/main.zig",
        "src/root.zig",
    };
    try std.testing.expectEqual(expected.len, manifest.files.len);
    for (expected) |path| try std.testing.expect(manifest.find(path) != null);

    // The real checkout satisfies the record: unrelated bytes are unchanged.
    try verify(io, cwd, manifest);

    // 6 files are preserved byte-for-byte; the two build files are anchors.
    var preserved: usize = 0;
    var extended: usize = 0;
    for (manifest.files) |record| {
        switch (record.class) {
            .preserved => preserved += 1,
            .extended => {
                extended += 1;
                try std.testing.expect(record.anchors.len > 0);
            },
        }
    }
    try std.testing.expectEqual(@as(usize, 6), preserved);
    try std.testing.expectEqual(@as(usize, 2), extended);

    // Negative control: a corrupted expectation must be detected instead of
    // reported as preserved.
    var corrupted = try parse(gpa, text);
    defer corrupted.deinit();
    const changed = corrupted.find("src/root.zig") orelse return error.MissingRecord;
    @memset(&changed.digest_hex, '0');
    try std.testing.expectError(error.ContentChanged, verify(io, cwd, corrupted));

    var anchor_broken = try parse(gpa, text);
    defer anchor_broken.deinit();
    const build_record = anchor_broken.find("build.zig.zon") orelse return error.MissingRecord;
    gpa.free(build_record.anchors[0]);
    build_record.anchors[0] = try gpa.dupe(u8, ".minimum_zig_version = \"99.99.99\"");
    try std.testing.expectError(error.MissingAnchor, verify(io, cwd, anchor_broken));

    // A record for a file that no longer exists is a failure, not a skip.
    var missing = try parse(gpa, text);
    defer missing.deinit();
    const absent = missing.find("src/main.zig") orelse return error.MissingRecord;
    gpa.free(absent.path);
    absent.path = try gpa.dupe(u8, "src/main.zig.deleted");
    try std.testing.expectError(error.MissingFile, verify(io, cwd, missing));

    // None of that touched the checkout: the real record still verifies.
    try verify(io, cwd, manifest);
}
