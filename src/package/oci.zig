//! OCI image layout construction and validation (M10, PACK-005 and PACK-006).
//!
//! The layout is the OCI image-layout specification: content-addressed blobs under
//! `blobs/sha256/`, an `index.json`, and an `oci-layout` marker. What makes it
//! trustworthy is the same thing that makes the rest of this product trustworthy -
//! every descriptor's digest is computed from the bytes it names, and the layout is
//! *validated* before it is handed to anyone:
//!
//! - every descriptor in the index, manifests, and config must have a blob present;
//! - that blob's digest must equal the descriptor's;
//! - the descriptor's size must equal the blob's length.
//!
//! A descriptor that disagrees with its blob is a failure that names the descriptor,
//! because a runtime would otherwise discover it later, on someone else's machine.
const std = @import("std");
const digest_module = @import("../core/digest.zig");
const canonical = @import("../core/canonical.zig");

pub const Error = error{
    DescriptorMissingBlob,
    DescriptorDigestMismatch,
    DescriptorSizeMismatch,
    InvalidLayout,
    OutOfMemory,
    WriteFailed,
};

pub const Digest = digest_module.Digest;

pub const media_types = struct {
    pub const index = "application/vnd.oci.image.index.v1+json";
    pub const manifest = "application/vnd.oci.image.manifest.v1+json";
    pub const config = "application/vnd.oci.image.config.v1+json";
    pub const layer = "application/vnd.oci.image.layer.v1.tar";
};

pub const Platform = struct {
    os: []const u8,
    architecture: []const u8,
};

/// One file in the layout: its path inside the layout and its bytes.
pub const BlobFile = struct {
    path: []const u8,
    bytes: []const u8,
};

pub const Layout = struct {
    files: []BlobFile,

    pub fn deinit(self: Layout, gpa: std.mem.Allocator) void {
        for (self.files) |file| {
            gpa.free(file.path);
            gpa.free(file.bytes);
        }
        gpa.free(self.files);
    }

    pub fn find(self: Layout, path: []const u8) ?BlobFile {
        for (self.files) |file| {
            if (std.mem.eql(u8, file.path, path)) return file;
        }
        return null;
    }
};

pub const Request = struct {
    /// The image configuration document (JSON), as the caller declares it.
    config: []const u8,
    /// The runtime closure's layers, in order.
    layers: []const BlobFile,
    /// The platform the image targets; recorded for each descriptor.
    platform: Platform,
};

fn digestOf(bytes: []const u8) Digest {
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &raw, .{});
    return .{ .bytes = raw };
}

fn blobPath(gpa: std.mem.Allocator, digest: Digest) ![]u8 {
    var text_buffer: [Digest.text_length]u8 = undefined;
    const text = digest.text(&text_buffer);
    // "sha256:<hex>" -> "blobs/sha256/<hex>"
    return std.fmt.allocPrint(gpa, "blobs/{s}/{s}", .{ text[0..6], text[7..] });
}

fn stringValue(arena: std.mem.Allocator, text: []const u8) canonical.Value {
    return .{ .string = arena.dupe(u8, text) catch unreachable };
}

fn integerValue(number: usize) canonical.Value {
    return .{ .integer = @intCast(number) };
}

fn descriptorValue(arena: std.mem.Allocator, media_type: []const u8, digest: Digest, size: usize, platform: ?Platform) !canonical.Value {
    var fields: std.ArrayList(canonical.Entry) = .empty;
    try fields.append(arena, .{ .key = "digest", .value = blk: {
        var text_buffer: [Digest.text_length]u8 = undefined;
        break :blk stringValue(arena, digest.text(&text_buffer));
    } });
    try fields.append(arena, .{ .key = "mediaType", .value = stringValue(arena, media_type) });
    if (platform) |p| {
        const platform_fields = try arena.alloc(canonical.Entry, 2);
        platform_fields[0] = .{ .key = "architecture", .value = stringValue(arena, p.architecture) };
        platform_fields[1] = .{ .key = "os", .value = stringValue(arena, p.os) };
        try fields.append(arena, .{ .key = "platform", .value = .{ .object = platform_fields } });
    }
    try fields.append(arena, .{ .key = "size", .value = integerValue(size) });
    return .{ .object = try fields.toOwnedSlice(arena) };
}

/// Builds a layout for one platform: config, layers, manifest, index, marker.
///
/// The manifest and index are built *after* their inputs so every descriptor's
/// digest is computed from bytes that are already in hand, and the marker is the
/// specification's own layout version.
pub fn build(gpa: std.mem.Allocator, request: Request) Error!Layout {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (request.layers.len == 0) return error.InvalidLayout;

    const config_digest = digestOf(request.config);
    const config_path = try blobPath(arena, config_digest);

    // The manifest lists the config and each layer as descriptors over the bytes.
    var manifest_fields: std.ArrayList(canonical.Entry) = .empty;
    try manifest_fields.append(arena, .{ .key = "schemaVersion", .value = integerValue(2) });
    try manifest_fields.append(arena, .{
        .key = "config",
        .value = try descriptorValue(arena, media_types.config, config_digest, request.config.len, null),
    });
    const layer_values = try arena.alloc(canonical.Value, request.layers.len);
    for (request.layers, 0..) |layer, index| {
        layer_values[index] = try descriptorValue(arena, media_types.layer, digestOf(layer.bytes), layer.bytes.len, null);
    }
    try manifest_fields.append(arena, .{ .key = "layers", .value = .{ .array = layer_values } });
    var manifest_document = canonical.Value{ .object = try manifest_fields.toOwnedSlice(arena) };
    canonical.canonicalize(&manifest_document);
    const manifest_bytes = try canonical.encodeAlloc(gpa, manifest_document);
    defer gpa.free(manifest_bytes);
    const manifest_digest = digestOf(manifest_bytes);
    const manifest_path = try blobPath(arena, manifest_digest);

    // The index points at the manifest with its platform, which is what makes a
    // multi-platform image describable by one document (PACK-006).
    const manifests = try arena.alloc(canonical.Value, 1);
    manifests[0] = try descriptorValue(arena, media_types.manifest, manifest_digest, manifest_bytes.len, request.platform);
    var index_fields = try arena.alloc(canonical.Entry, 2);
    index_fields[0] = .{ .key = "manifests", .value = .{ .array = manifests } };
    index_fields[1] = .{ .key = "schemaVersion", .value = integerValue(2) };
    var index_document = canonical.Value{ .object = index_fields };
    canonical.canonicalize(&index_document);
    const index_bytes = try canonical.encodeAlloc(gpa, index_document);
    defer gpa.free(index_bytes);

    var layout_fields = try arena.alloc(canonical.Entry, 1);
    layout_fields[0] = .{ .key = "imageLayoutVersion", .value = stringValue(arena, "1.0.0") };
    var layout_document = canonical.Value{ .object = layout_fields };
    canonical.canonicalize(&layout_document);
    const marker_bytes = try canonical.encodeAlloc(gpa, layout_document);
    defer gpa.free(marker_bytes);

    // Assemble the file set: blobs, the two documents, and the marker.
    var files: std.ArrayList(BlobFile) = .empty;
    errdefer {
        for (files.items) |file| {
            gpa.free(file.path);
            gpa.free(file.bytes);
        }
        files.deinit(gpa);
    }
    try files.append(gpa, .{ .path = try gpa.dupe(u8, config_path), .bytes = try gpa.dupe(u8, request.config) });
    for (request.layers) |layer| {
        const path = try blobPath(arena, digestOf(layer.bytes));
        try files.append(gpa, .{ .path = try gpa.dupe(u8, path), .bytes = try gpa.dupe(u8, layer.bytes) });
    }
    try files.append(gpa, .{ .path = try gpa.dupe(u8, manifest_path), .bytes = try gpa.dupe(u8, manifest_bytes) });
    try files.append(gpa, .{ .path = try gpa.dupe(u8, "index.json"), .bytes = try gpa.dupe(u8, index_bytes) });
    try files.append(gpa, .{ .path = try gpa.dupe(u8, "oci-layout"), .bytes = try gpa.dupe(u8, marker_bytes) });

    return .{ .files = try files.toOwnedSlice(gpa) };
}

pub const Verification = struct {
    descriptors: usize,
    /// Path of the first descriptor that disagreed with its blob.
    failed: ?[]const u8 = null,

    pub fn ok(self: Verification) bool {
        return self.failed == null;
    }
};

/// Validates every descriptor in the index against the blobs present.
///
/// A layout is accepted only when each descriptor's blob exists, hashes to the
/// described digest, and has the described length. Sizes are the third leg on
/// purpose: a descriptor with a right digest and a wrong size is a document that
/// disagrees with itself.
pub fn validate(gpa: std.mem.Allocator, layout: Layout) Error!Verification {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var report = Verification{ .descriptors = 0 };

    const index_file = layout.find("index.json") orelse return error.InvalidLayout;
    var diagnostic: canonical.Diagnostic = .{};
    const index = canonical.parse(arena, index_file.bytes, &diagnostic) catch return error.InvalidLayout;

    for (index.object) |entry| {
        if (!std.mem.eql(u8, entry.key, "manifests")) continue;
        for (entry.value.array) |descriptor| {
            const verified = try verifyDescriptor(gpa, arena, layout, descriptor);
            report.descriptors += 1;
            if (!verified) return report;
        }
    }

    // Each referenced manifest is itself a document whose descriptors must hold.
    for (index.object) |entry| {
        if (!std.mem.eql(u8, entry.key, "manifests")) continue;
        for (entry.value.array) |descriptor| {
            const digest_text = valueString(descriptor, "digest") orelse return error.InvalidLayout;
            const manifest_digest = Digest.parse(digest_text) catch return error.InvalidLayout;
            const path = try blobPath(arena, manifest_digest);
            const manifest_file = layout.find(path) orelse return error.DescriptorMissingBlob;
            const manifest = canonical.parse(arena, manifest_file.bytes, &diagnostic) catch return error.InvalidLayout;
            for (manifest.object) |manifest_entry| {
                if (std.mem.eql(u8, manifest_entry.key, "config")) {
                    if (!try verifyDescriptor(gpa, arena, layout, manifest_entry.value)) {
                        report.failed = path;
                        return report;
                    }
                    report.descriptors += 1;
                }
                if (std.mem.eql(u8, manifest_entry.key, "layers")) {
                    for (manifest_entry.value.array) |layer_descriptor| {
                        if (!try verifyDescriptor(gpa, arena, layout, layer_descriptor)) {
                            report.failed = path;
                            return report;
                        }
                        report.descriptors += 1;
                    }
                }
            }
        }
    }
    return report;
}

fn valueString(value: canonical.Value, key: []const u8) ?[]const u8 {
    for (value.object) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry.value.string;
    }
    return null;
}

fn valueInteger(value: canonical.Value, key: []const u8) ?i64 {
    for (value.object) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry.value.integer;
    }
    return null;
}

fn verifyDescriptor(gpa: std.mem.Allocator, arena: std.mem.Allocator, layout: Layout, descriptor: canonical.Value) Error!bool {
    const digest_text = valueString(descriptor, "digest") orelse return error.InvalidLayout;
    const descriptor_digest = Digest.parse(digest_text) catch return error.InvalidLayout;
    const size = valueInteger(descriptor, "size") orelse return error.InvalidLayout;
    const path = try blobPath(arena, descriptor_digest);
    const blob = layout.find(path) orelse return error.DescriptorMissingBlob;
    _ = gpa;
    if (blob.bytes.len != @as(usize, @intCast(size))) return error.DescriptorSizeMismatch;
    if (!Digest.eql(digestOf(blob.bytes), descriptor_digest)) return error.DescriptorDigestMismatch;
    return true;
}

test "m10/PACK-005 construct OCI layout: descriptors are verified against their blobs" {
    std.debug.print("JCKG_EVIDENCE PACK-005\n", .{});
    const gpa = std.testing.allocator;

    // A runtime closure (one layer of payload) and an image configuration.
    const layer_one = "runtime closure payload\n";
    const layer_two = "second runtime layer\n";
    const config =
        \\{"architecture":"x86_64","os":"linux","config":{"Entrypoint":["/jckg"]}}
    ;
    const layers = [_]BlobFile{
        .{ .path = "layer-0", .bytes = layer_one },
        .{ .path = "layer-1", .bytes = layer_two },
    };
    const layout = try build(gpa, .{
        .config = config,
        .layers = &layers,
        .platform = .{ .os = "linux", .architecture = "x86_64" },
    });
    defer layout.deinit(gpa);

    // A valid layout: the marker, the index, the manifest, the config, and one blob
    // per layer, each at its content-addressed path.
    try std.testing.expect(layout.find("oci-layout") != null);
    try std.testing.expect(layout.find("index.json") != null);
    var blob_count: usize = 0;
    for (layout.files) |file| {
        if (std.mem.startsWith(u8, file.path, "blobs/sha256/")) blob_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), blob_count);

    const verification = try validate(gpa, layout);
    try std.testing.expect(verification.ok());
    try std.testing.expectEqual(@as(usize, 4), verification.descriptors);

    // The index records the platform, which is what PACK-006 is about: the same
    // image built for another architecture is describable by another index entry.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var diagnostic: canonical.Diagnostic = .{};
    const index = try canonical.parse(arena_state.allocator(), layout.find("index.json").?.bytes, &diagnostic);
    const manifests = valueArray(index, "manifests").?;
    const platform = valueObject(manifests[0], "platform").?;
    try std.testing.expectEqualStrings("linux", valueString(platform, "os").?);
    try std.testing.expectEqualStrings("x86_64", valueString(platform, "architecture").?);

    // Negative-or-recovery: a blob corrupted *to the same length* is refused by the
    // digest check, not by the size check. A shorter tampered blob would only prove
    // the size check works, and size is the weak check.
    const tampered = try gpa.alloc(BlobFile, layout.files.len);
    defer gpa.free(tampered);
    for (layout.files, 0..) |file, index_slot| {
        const bytes = try gpa.dupe(u8, file.bytes);
        if (std.mem.startsWith(u8, file.path, "blobs/") and bytes.len > 0) {
            bytes[0] = if (bytes[0] == 'x') 'y' else 'x';
        }
        tampered[index_slot] = .{ .path = try gpa.dupe(u8, file.path), .bytes = bytes };
    }
    defer for (tampered) |file| {
        gpa.free(file.path);
        gpa.free(file.bytes);
    };
    try std.testing.expectError(error.DescriptorDigestMismatch, validate(gpa, .{ .files = tampered }));

    // A layout missing a referenced blob is refused before anything else.
    const missing = try gpa.alloc(BlobFile, layout.files.len - 1);
    defer gpa.free(missing);
    var written: usize = 0;
    for (layout.files) |file| {
        if (std.mem.startsWith(u8, file.path, "blobs/")) continue;
        missing[written] = file;
        written += 1;
    }
    try std.testing.expectError(error.DescriptorMissingBlob, validate(gpa, .{ .files = missing }));
}

fn valueArray(value: canonical.Value, key: []const u8) ?[]canonical.Value {
    for (value.object) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry.value.array;
    }
    return null;
}

fn valueObject(value: canonical.Value, key: []const u8) ?canonical.Value {
    for (value.object) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry.value;
    }
    return null;
}
