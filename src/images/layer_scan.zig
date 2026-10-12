//! Reading an image back and checking every layer of it (M15, IMAGE-008).
//!
//! The declaration is checked as the image is assembled, and that is not enough. An
//! image is a stack of layers, the lower ones may come from somewhere else entirely,
//! and a photo of the top layer tells you nothing about what is underneath. A cache
//! or a `.git` directory in the base layer is just as present in the final image as
//! one in the layer built here.
//!
//! So this module reads the layout the way a consumer would - index, manifest, and
//! the layer blobs it names - walks each layer's tar, and reports the first entry
//! that should not be there, naming the layer. Nothing is inferred from the build
//! inputs: the bytes on disk are what is checked, which is the only claim that
//! survives somebody editing the assembler.
const std = @import("std");
const dev = @import("dev_environment.zig");

pub const Error = error{
    InvalidLayout,
    ProhibitedState,
    OutOfMemory,
};

pub const Offense = struct {
    /// The layer blob's digest, so the offending layer is named rather than the image
    /// as a whole.
    layer: []const u8,
    path: []const u8,
    kind: Kind,

    pub const Kind = enum { secret, git_metadata, cache };

    pub fn deinit(self: Offense, gpa: std.mem.Allocator) void {
        gpa.free(self.layer);
        gpa.free(self.path);
    }
};

/// Caches are not secret, but they are machine state: a build output captured in an
/// image makes the image depend on what some machine happened to have compiled.
const cache_names = [_][]const u8{
    ".zig-cache",
    ".zig-cache-strict",
    "zig-cache",
    "zig-out",
    "node_modules",
    ".jckg-workspaces",
};

pub fn prohibitedPathKind(gpa: std.mem.Allocator, path: []const u8) ?Offense.Kind {
    // Git metadata and caches are checked first because the categories overlap: the
    // image rules also refuse `.git`, and a report that called it a secret would name
    // the wrong problem. What is left is decided by the secret rules, which are the
    // same rules dev_environment uses - one implementation, so a name added to one is
    // a name added to both.
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, ".git")) return .git_metadata;
        for (cache_names) |name| {
            if (std.mem.eql(u8, component, name)) return .cache;
        }
    }
    if (dev.prohibitedPath(gpa, path)) return .secret;
    return null;
}

/// Walks one tar layer, reporting the first member that should not be in an image.
/// The tar is parsed rather than searched: a path that appears inside a file's
/// contents is not a path in the image, and treating it as one would make the check
/// useless in both directions.
pub fn scanTar(gpa: std.mem.Allocator, tar: []const u8) Error!?Offense {
    var offset: usize = 0;
    while (offset + 512 <= tar.len) {
        const header = tar[offset .. offset + 512];
        // Two zero blocks end the archive; a zero-name block is the terminator.
        var empty = true;
        for (header) |byte| {
            if (byte != 0) {
                empty = false;
                break;
            }
        }
        if (empty) break;

        const name_field = header[0..100];
        const name_len = std.mem.indexOfScalar(u8, name_field, 0) orelse name_field.len;
        const name = name_field[0..name_len];
        if (name.len == 0) return error.InvalidLayout;

        const size_field = header[124..136];
        const size_text = std.mem.sliceTo(size_field, 0);
        // The field is octal text, zero-padded; parseInt handles the padding, and an
        // all-zero field is a zero-length member rather than an error.
        const size = std.fmt.parseInt(usize, size_text, 8) catch 0;

        offset += 512;
        if (offset + size > tar.len) return error.InvalidLayout;

        if (prohibitedPathKind(gpa, name)) |kind| {
            return .{
                .layer = try gpa.dupe(u8, ""),
                .path = try gpa.dupe(u8, name),
                .kind = kind,
            };
        }
        // The body matters too: a private key named `notes.txt` is still a key.
        if (dev.prohibitedBody(tar[offset .. offset + size])) {
            return .{
                .layer = try gpa.dupe(u8, ""),
                .path = try gpa.dupe(u8, name),
                .kind = .secret,
            };
        }
        offset += std.mem.alignForward(usize, size, 512);
    }
    return null;
}

pub const Report = struct {
    layers_scanned: usize,
    entries_scanned: usize,

    pub fn deinit(self: Report, gpa: std.mem.Allocator) void {
        _ = gpa;
        _ = self;
    }
};

/// Scans every layer of an OCI layout on disk, in manifest order.
pub fn scanLayout(
    gpa: std.mem.Allocator,
    io: std.Io,
    layout: std.Io.Dir,
) Error!struct { report: Report, offense: ?Offense } {
    const index_bytes = layout.readFileAlloc(io, "index.json", gpa, .limited(1 << 20)) catch
        return error.InvalidLayout;
    defer gpa.free(index_bytes);
    const index = std.json.parseFromSlice(std.json.Value, gpa, index_bytes, .{}) catch return error.InvalidLayout;
    defer index.deinit();
    const manifests = switch (index.value) {
        .object => |object| object.get("manifests") orelse return error.InvalidLayout,
        else => return error.InvalidLayout,
    };
    if (manifests != .array or manifests.array.items.len == 0) return error.InvalidLayout;

    var report = Report{ .layers_scanned = 0, .entries_scanned = 0 };
    var blob_path: [256]u8 = undefined;

    for (manifests.array.items) |descriptor| {
        if (descriptor != .object) return error.InvalidLayout;
        const manifest_digest = descriptor.object.get("digest") orelse return error.InvalidLayout;
        if (manifest_digest != .string) return error.InvalidLayout;
        const manifest_path = try blobPath(&blob_path, manifest_digest.string);
        const manifest_bytes = layout.readFileAlloc(io, manifest_path, gpa, .limited(1 << 20)) catch
            return error.InvalidLayout;
        defer gpa.free(manifest_bytes);
        const manifest = std.json.parseFromSlice(std.json.Value, gpa, manifest_bytes, .{}) catch return error.InvalidLayout;
        defer manifest.deinit();
        const layers = switch (manifest.value) {
            .object => |object| object.get("layers") orelse return error.InvalidLayout,
            else => return error.InvalidLayout,
        };
        if (layers != .array) return error.InvalidLayout;

        for (layers.array.items) |layer| {
            if (layer != .object) return error.InvalidLayout;
            const layer_digest = layer.object.get("digest") orelse return error.InvalidLayout;
            if (layer_digest != .string) return error.InvalidLayout;
            const layer_path = try blobPath(&blob_path, layer_digest.string);
            const layer_bytes = layout.readFileAlloc(io, layer_path, gpa, .limited(256 * 1024 * 1024)) catch
                return error.InvalidLayout;
            defer gpa.free(layer_bytes);
            report.layers_scanned += 1;

            if (try scanTar(gpa, layer_bytes)) |found| {
                gpa.free(found.layer);
                return .{
                    .report = report,
                    .offense = .{
                        .layer = try gpa.dupe(u8, layer_digest.string),
                        .path = found.path,
                        .kind = found.kind,
                    },
                };
            }
            report.entries_scanned += 1;
        }
    }
    return .{ .report = report, .offense = null };
}

fn blobPath(buffer: []u8, digest_text: []const u8) Error![]const u8 {
    if (!std.mem.startsWith(u8, digest_text, "sha256:")) return error.InvalidLayout;
    const hex = digest_text["sha256:".len..];
    if (hex.len != 64) return error.InvalidLayout;
    return std.mem.print(buffer, "blobs/sha256/{s}", .{hex}) catch error.InvalidLayout;
}

test "m15/IMAGE-008 exclude user state: prohibited state is absent from every layer" {
    std.debug.print("JCKG_EVIDENCE IMAGE-008\n", .{});
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const source_path = "zig-out/jckg-image-008-source";
    const image_path = "zig-out/jckg-image-008-image";
    cwd.deleteTree(io, source_path) catch {};
    cwd.deleteTree(io, image_path) catch {};
    defer cwd.deleteTree(io, source_path) catch {};
    defer cwd.deleteTree(io, image_path) catch {};

    var source = try cwd.createDirPathOpen(io, source_path, .{ .open_options = .{ .iterate = true } });
    defer source.close(io);
    try source.createDirPath(io, "tools");
    try source.writeFile(io, .{ .sub_path = "tools/tool.sh", .data = "#!/bin/sh\necho tool\n" });
    // A workspace with everything an image must not carry.
    try source.writeFile(io, .{ .sub_path = ".git-credentials", .data = "https://user:token@example\n" });
    try source.createDirPath(io, ".zig-cache");
    try source.writeFile(io, .{ .sub_path = ".zig-cache/artifact", .data = "cache bytes\n" });
    try source.createDirPath(io, ".git");
    try source.writeFile(io, .{ .sub_path = ".git/config", .data = "[remote]\n" });
    try source.createDirPath(io, "node_modules");
    try source.writeFile(io, .{ .sub_path = "node_modules/left-pad.js", .data = "module\n" });

    const entries = [_]dev.Entry{.{ .path = "tools/tool.sh", .source = "tools/tool.sh", .executable = true }};
    const declaration = dev.Declaration{ .name = "jckg-tools", .base = "sha256:00", .entries = &entries };
    const payload = try dev.assemble(gpa, io, source, declaration);
    defer payload.deinit(gpa);
    try dev.scan(gpa, payload);

    const clean_entries = [_]dev.Entry{entries[0]};
    var image = try cwd.createDirPathOpen(io, image_path, .{});
    defer image.close(io);
    const layout = try dev.writeLayout(gpa, io, image, .{ .name = "jckg-tools", .base = "sha256:00", .entries = &clean_entries }, payload);
    defer layout.deinit(gpa);

    // A clean image scans clean, and the scan actually walked a layer - a report of
    // zero layers would make the check vacuous.
    const clean = try scanLayout(gpa, io, image);
    if (clean.offense) |offense| {
        defer offense.deinit(gpa);
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(usize, 1), clean.report.layers_scanned);

    // Now the case: an offence in a *lower* layer. The assembler never sees this
    // layer - it is added to the layout directly, exactly as a base image would be -
    // so a check that only looked at what the build produced would miss it.
    var base_tar: std.ArrayList(u8) = .empty;
    defer base_tar.deinit(gpa);
    try appendTarEntry(gpa, &base_tar, ".zig-cache/artifact", "cache bytes\n");
    try base_tar.appendNTimes(gpa, 0, 1024);
    var base_digest_raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(base_tar.items, &base_digest_raw, .{});
    const base_digest = try std.fmt.allocPrint(gpa, "sha256:{s}", .{std.fmt.bytesToHex(base_digest_raw, .lower)});
    defer gpa.free(base_digest);
    const base_path = try std.fmt.allocPrint(gpa, "blobs/sha256/{s}", .{base_digest["sha256:".len..]});
    defer gpa.free(base_path);
    try image.writeFile(io, .{ .sub_path = base_path, .data = base_tar.items });

    // The manifest now names both layers: the base first, then the tools.
    const both_manifest = try std.fmt.allocPrint(
        gpa,
        "{{\"schemaVersion\":2,\"layers\":[{{\"digest\":\"{s}\",\"size\":{d}}},{{\"digest\":\"{s}\",\"size\":{d}}}]}}",
        .{ base_digest, base_tar.items.len, layout.layer_digest, layout.layer_bytes },
    );
    defer gpa.free(both_manifest);
    var manifest_raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(both_manifest, &manifest_raw, .{});
    const manifest_digest = try std.fmt.allocPrint(gpa, "sha256:{s}", .{std.fmt.bytesToHex(manifest_raw, .lower)});
    defer gpa.free(manifest_digest);
    const manifest_path = try std.fmt.allocPrint(gpa, "blobs/sha256/{s}", .{manifest_digest["sha256:".len..]});
    defer gpa.free(manifest_path);
    try image.writeFile(io, .{ .sub_path = manifest_path, .data = both_manifest });
    const index_json = try std.fmt.allocPrint(
        gpa,
        "{{\"schemaVersion\":2,\"manifests\":[{{\"digest\":\"{s}\",\"size\":{d}}}]}}",
        .{ manifest_digest, both_manifest.len },
    );
    defer gpa.free(index_json);
    try image.writeFile(io, .{ .sub_path = "index.json", .data = index_json });

    const scanned = try scanLayout(gpa, io, image);
    if (scanned.offense) |offense| {
        defer offense.deinit(gpa);
        // The offence is named by the layer it is in, which is what makes the report
        // actionable: "somewhere in this image" is not a finding.
        try std.testing.expectEqual(Offense.Kind.cache, offense.kind);
        try std.testing.expectEqualStrings(".zig-cache/artifact", offense.path);
        try std.testing.expectEqualStrings(base_digest, offense.layer);
        try std.testing.expectEqual(@as(usize, 1), scanned.report.layers_scanned);
    } else {
        return error.TestUnexpectedResult;
    }

    // The rule tables themselves: secrets by name and by body, git metadata, caches.
    try std.testing.expectEqual(Offense.Kind.secret, prohibitedPathKind(gpa, ".git-credentials").?);
    try std.testing.expectEqual(Offense.Kind.secret, prohibitedPathKind(gpa, "id_rsa").?);
    try std.testing.expectEqual(Offense.Kind.secret, prohibitedPathKind(gpa, "keys/server.pem").?);
    try std.testing.expectEqual(Offense.Kind.git_metadata, prohibitedPathKind(gpa, ".git/config").?);
    try std.testing.expectEqual(Offense.Kind.cache, prohibitedPathKind(gpa, "project/.zig-cache/x").?);
    try std.testing.expectEqual(Offense.Kind.cache, prohibitedPathKind(gpa, "app/node_modules/left-pad.js").?);
    try std.testing.expectEqual(Offense.Kind.cache, prohibitedPathKind(gpa, "zig-out/jckg").?);
    try std.testing.expect(prohibitedPathKind(gpa, "tools/tool.sh") == null);
    try std.testing.expect(prohibitedPathKind(gpa, "src/main.zig") == null);

    // A tar whose *contents* mention a prohibited path is not an offence: the check
    // parses members rather than searching bytes, and a search would fail in both
    // directions.
    var innocent: std.ArrayList(u8) = .empty;
    defer innocent.deinit(gpa);
    try appendTarEntry(gpa, &innocent, "notes.txt", "the file .git-credentials is mentioned here\n");
    try innocent.appendNTimes(gpa, 0, 1024);
    try std.testing.expect(try scanTar(gpa, innocent.items) == null);
    // A body that is a private key is an offence whatever the member is called.
    var secretive: std.ArrayList(u8) = .empty;
    defer secretive.deinit(gpa);
    try appendTarEntry(gpa, &secretive, "notes.txt", "-----BEGIN RSA PRIVATE KEY-----\n");
    try secretive.appendNTimes(gpa, 0, 1024);
    const found = (try scanTar(gpa, secretive.items)).?;
    defer found.deinit(gpa);
    try std.testing.expectEqual(Offense.Kind.secret, found.kind);
    try std.testing.expectEqualStrings("notes.txt", found.path);
}

/// Appends one tar member, in the same deterministic form the layout writer uses.
fn appendTarEntry(gpa: std.mem.Allocator, buffer: *std.ArrayList(u8), path: []const u8, bytes: []const u8) !void {
    var header: [512]u8 = @splat(0);
    @memcpy(header[0..path.len], path);
    @memcpy(header[100..107], "0000644");
    @memcpy(header[108..115], "0000000");
    @memcpy(header[116..123], "0000000");
    var size_text: [12]u8 = undefined;
    _ = try std.fmt.bufPrint(&size_text, "{o:0>11}", .{bytes.len});
    @memcpy(header[124..135], size_text[0..11]);
    @memcpy(header[136..147], "00000000000");
    header[156] = '0';
    @memcpy(header[257..263], "ustar\x00");
    @memcpy(header[263..265], "00");
    @memset(header[148..156], ' ');
    var sum: u32 = 0;
    for (header) |byte| sum += byte;
    var checksum: [8]u8 = undefined;
    _ = try std.fmt.bufPrint(&checksum, "{o:0>6}\x00 ", .{sum});
    @memcpy(header[148..156], &checksum);
    try buffer.appendSlice(gpa, &header);
    try buffer.appendSlice(gpa, bytes);
    try buffer.appendNTimes(gpa, 0, (512 - (bytes.len % 512)) % 512);
}
