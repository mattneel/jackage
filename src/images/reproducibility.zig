//! What "the same image" means when building it twice (M15, IMAGE-007).
//!
//! Two builds of the same declaration usually differ somewhere. A config document
//! carries a creation timestamp, a build tool adds an annotation, and the image is
//! then not byte-identical even though every byte of the payload is. That is fine -
//! and it is not fine to *report* it as either "reproducible" or "different" without
//! saying which of the two things is being compared.
//!
//! So the comparison is split, and both answers are given:
//!
//! - **payload equality**: every layer's digest. This is the claim that matters to a
//!   consumer, because the layers are what run; if these match, the two images
//!   execute identically whatever their wrappers say.
//! - **image equality**: the manifest and config bytes as well. This is the stricter
//!   claim, and failing it while the payload matches is a statement about the
//!   wrapper, not about the contents.
//!
//! The report names the wrapper fields that differ, so "the images are not
//! byte-identical" is followed by "because of `created`", which is the difference
//! between a finding and a shrug.
const std = @import("std");

pub const Error = error{
    InvalidImage,
    OutOfMemory,
};

pub const Image = struct {
    /// The image config document, as bytes.
    config: []const u8,
    /// Every layer digest, in order.
    layers: []const []const u8,
    /// The manifest document, as bytes.
    manifest: []const u8,
};

pub const Report = struct {
    /// True when every layer digest matches. The images run the same bytes.
    payload_equal: bool,
    /// True when the manifest and config match as well.
    image_equal: bool,
    /// The index of the first layer whose digest differs, when one does.
    differing_layer: ?usize,
    /// Config fields whose serialized values differ, in document order. These are the
    /// wrapper fields: named, so the report says why.
    differing_fields: []const []const u8,

    pub fn deinit(self: Report, gpa: std.mem.Allocator) void {
        for (self.differing_fields) |field| gpa.free(field);
        gpa.free(self.differing_fields);
    }

    pub fn names(self: Report, field: []const u8) bool {
        for (self.differing_fields) |candidate| {
            if (std.mem.eql(u8, candidate, field)) return true;
        }
        return false;
    }
};

/// Compares two builds of an image, reporting payload and wrapper separately.
pub fn compare(gpa: std.mem.Allocator, left: Image, right: Image) Error!Report {
    if (left.layers.len != right.layers.len) return error.InvalidImage;

    var differing_layer: ?usize = null;
    var payload_equal = true;
    for (left.layers, right.layers, 0..) |a, b, index| {
        if (!std.mem.eql(u8, a, b)) {
            payload_equal = false;
            if (differing_layer == null) differing_layer = index;
        }
    }

    var fields: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (fields.items) |field| gpa.free(field);
        fields.deinit(gpa);
    }

    // The config is compared field by field rather than as bytes, because "these
    // documents differ" is only useful next to "in this field".
    const left_config = std.json.parseFromSlice(std.json.Value, gpa, left.config, .{}) catch return error.InvalidImage;
    defer left_config.deinit();
    const right_config = std.json.parseFromSlice(std.json.Value, gpa, right.config, .{}) catch return error.InvalidImage;
    defer right_config.deinit();
    if (left_config.value != .object or right_config.value != .object) return error.InvalidImage;

    var iterator = left_config.value.object.iterator();
    while (iterator.next()) |entry| {
        const other = right_config.value.object.get(entry.key_ptr.*);
        if (other == null) {
            try fields.append(gpa, try gpa.dupe(u8, entry.key_ptr.*));
            continue;
        }
        const a = try std.json.Stringify.valueAlloc(gpa, entry.value_ptr.*, .{});
        defer gpa.free(a);
        const b = try std.json.Stringify.valueAlloc(gpa, other.?, .{});
        defer gpa.free(b);
        if (!std.mem.eql(u8, a, b)) try fields.append(gpa, try gpa.dupe(u8, entry.key_ptr.*));
    }
    var right_iterator = right_config.value.object.iterator();
    while (right_iterator.next()) |entry| {
        if (left_config.value.object.get(entry.key_ptr.*) == null) {
            try fields.append(gpa, try gpa.dupe(u8, entry.key_ptr.*));
        }
    }

    const image_equal = payload_equal and std.mem.eql(u8, left.config, right.config) and
        std.mem.eql(u8, left.manifest, right.manifest);

    return .{
        .payload_equal = payload_equal,
        .image_equal = image_equal,
        .differing_layer = differing_layer,
        .differing_fields = try fields.toOwnedSlice(gpa),
    };
}

test "m15/IMAGE-007 report image reproducibility: payload equality and image equality are separate" {
    std.debug.print("JCKG_EVIDENCE IMAGE-007\n", .{});
    const gpa = std.testing.allocator;

    const layer_a = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const layer_b = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const layer_c = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";

    // Two builds whose payload is identical and whose wrapper differs in one field -
    // the creation timestamp, which is exactly the field every builder varies.
    const first_config = "{\"architecture\":\"amd64\",\"os\":\"linux\",\"created\":\"2026-01-01T00:00:00Z\",\"config\":{\"Env\":[\"JCKG_HOME=/jckg\"]}}";
    const second_config = "{\"architecture\":\"amd64\",\"os\":\"linux\",\"created\":\"2026-02-02T00:00:00Z\",\"config\":{\"Env\":[\"JCKG_HOME=/jckg\"]}}";

    const first = Image{ .config = first_config, .layers = &.{ layer_a, layer_b }, .manifest = "{\"schemaVersion\":2}" };
    const second = Image{ .config = second_config, .layers = &.{ layer_a, layer_b }, .manifest = "{\"schemaVersion\":2}" };

    const report = try compare(gpa, first, second);
    defer report.deinit(gpa);

    // The payload is equal: the layers are the bytes that run, and they match.
    try std.testing.expect(report.payload_equal);
    try std.testing.expect(report.differing_layer == null);
    // The image is not: the wrapper moved.
    try std.testing.expect(!report.image_equal);
    // And the report says which wrapper field moved, so the finding is actionable
    // rather than a shrug.
    try std.testing.expectEqual(@as(usize, 1), report.differing_fields.len);
    try std.testing.expect(report.names("created"));
    try std.testing.expect(!report.names("architecture"));

    // A differing layer is a payload difference, and it is named by index.
    const third = Image{ .config = first_config, .layers = &.{ layer_a, layer_c }, .manifest = "{\"schemaVersion\":2}" };
    const payload_report = try compare(gpa, first, third);
    defer payload_report.deinit(gpa);
    try std.testing.expect(!payload_report.payload_equal);
    try std.testing.expectEqual(@as(usize, 1), payload_report.differing_layer.?);
    try std.testing.expect(!payload_report.image_equal);

    // Identical builds, for completeness: both claims hold, and nothing is named.
    const identical = try compare(gpa, first, first);
    defer identical.deinit(gpa);
    try std.testing.expect(identical.payload_equal);
    try std.testing.expect(identical.image_equal);
    try std.testing.expectEqual(@as(usize, 0), identical.differing_fields.len);

    // A field present on one side only is reported too, and so is one that differs
    // inside a nested document: naming only the top level would leave a reader to
    // diff by hand.
    const with_annotation = "{\"architecture\":\"amd64\",\"os\":\"linux\",\"created\":\"2026-01-01T00:00:00Z\",\"config\":{\"Env\":[\"JCKG_HOME=/other\"]},\"annotation\":\"ci\"}";
    const nested = Image{ .config = with_annotation, .layers = &.{ layer_a, layer_b }, .manifest = "{\"schemaVersion\":2}" };
    const nested_report = try compare(gpa, first, nested);
    defer nested_report.deinit(gpa);
    try std.testing.expect(nested_report.payload_equal);
    try std.testing.expect(nested_report.names("annotation"));
    try std.testing.expect(nested_report.names("config"));

    // A manifest difference makes the images unequal even when everything else
    // matches: that is the whole-image claim, and it does not pretend otherwise.
    const other_manifest = Image{ .config = first_config, .layers = &.{ layer_a, layer_b }, .manifest = "{\"schemaVersion\":2,\"annotations\":{}}" };
    const manifest_report = try compare(gpa, first, other_manifest);
    defer manifest_report.deinit(gpa);
    try std.testing.expect(manifest_report.payload_equal);
    try std.testing.expect(!manifest_report.image_equal);
    try std.testing.expectEqual(@as(usize, 0), manifest_report.differing_fields.len);

    // Comparing images with different layer counts is a caller mistake, not a report.
    const short = Image{ .config = first_config, .layers = &.{layer_a}, .manifest = "{\"schemaVersion\":2}" };
    try std.testing.expectError(error.InvalidImage, compare(gpa, first, short));
}
