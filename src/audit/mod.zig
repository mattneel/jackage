//! M00 repository audit.
//!
//! One observation of the checkout: the pinned compiler, the host that is
//! actually available, the source that already exists, the declared inputs,
//! and the record proving unrelated bytes were not touched. The same data
//! backs `jckg doctor`.
const std = @import("std");

pub const pin = @import("pin.zig");
pub const host = @import("host.zig");
pub const inventory = @import("inventory.zig");
pub const provenance = @import("provenance.zig");
pub const manifest = @import("manifest.zig");
pub const baseline = @import("baseline.zig");

pub const manifest_path = ".jackage-delivery/state/baseline/protected-files.json";
pub const source_root = "src";

pub const Checkout = struct {
    /// Pin text recorded in `.zigversion`.
    pin_text: []const u8,
    /// Whether a supplied compiler report matched the pin; null when the
    /// compiler was not exercised in this observation.
    pin_matches: ?bool,
    host_facts: host.HostFacts,
    sources: inventory.Inventory,
    inputs: provenance.Provenance,
    /// True when every preserved file and every build anchor still matches.
    protected_files_verified: bool,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Checkout) void {
        self.gpa.free(self.pin_text);
        self.host_facts.deinit();
        self.sources.deinit();
        self.inputs.deinit();
        self.* = undefined;
    }

    pub fn writeJson(self: Checkout, writer: *std.Io.Writer) !void {
        const SourceEntry = struct {
            path: []const u8,
            sizeBytes: u64,
            sha256: []const u8,
            testBlocks: u32,
        };
        const entries = try self.gpa.alloc(SourceEntry, self.sources.files.len);
        defer self.gpa.free(entries);
        for (self.sources.files, 0..) |file, index| {
            entries[index] = .{
                .path = file.path,
                .sizeBytes = file.size_bytes,
                .sha256 = file.sha256_hex[0..],
                .testBlocks = file.test_blocks,
            };
        }

        var target_buffer: [32]u8 = undefined;
        const document = .{
            .schemaVersion = 1,
            .kind = "jackage-audit",
            .host = .{
                .os = self.host_facts.os.text(),
                .architecture = self.host_facts.arch.text(),
                .target = self.host_facts.target().format(&target_buffer),
                .logicalCpus = self.host_facts.logical_cpus,
                .pageSizeMin = self.host_facts.page_size_min,
                .pageSizeMax = self.host_facts.page_size_max,
                .executable = self.host_facts.executable_path,
            },
            .toolchain = .{
                .recorded = self.pin_text,
                .matches = self.pin_matches,
            },
            .source = .{
                .root = source_root,
                .fileCount = self.sources.files.len,
                .totalBytes = self.sources.totalBytes(),
                .testBlocks = self.sources.totalTestBlocks(),
                .files = entries,
            },
            .provenance = .{
                .dependencies = self.inputs.dependencyCount(),
                .projectLicense = self.inputs.project_license,
                .licenseFiles = self.inputs.license_files,
                .toolchainUrl = self.inputs.toolchain_url,
                .toolchainSha256 = if (self.inputs.toolchain_sha256) |digest| digest[0..] else null,
            },
            .preservation = .{
                .recordVerified = self.protected_files_verified,
                .recordPath = manifest_path,
            },
        };
        try std.json.Stringify.value(document, .{ .whitespace = .indent_2 }, writer);
    }
};

pub const AuditError = error{
    MissingPin,
    MissingPreservationRecord,
    InvalidPreservationRecord,
    UnreadableCheckout,
};

/// Observes the checkout. `toolchain_report` is the text a compiler wrapper
/// reported; when supplied, the pin is checked against it.
pub fn audit(io: std.Io, gpa: std.mem.Allocator, toolchain_report: ?[]const u8) !Checkout {
    const dir = std.Io.Dir.cwd();

    const pin_raw = dir.readFileAlloc(io, ".zigversion", gpa, .unlimited) catch return error.MissingPin;
    defer gpa.free(pin_raw);
    const pin_text = try gpa.dupe(u8, pin.trimReport(pin_raw));
    errdefer gpa.free(pin_text);

    var pin_matches: ?bool = null;
    if (toolchain_report) |report| {
        pin_matches = if (pin.Pin.init(pin_text).verify(report)) |_| true else |_| false;
    }

    const host_facts = try host.detect(io, gpa);
    errdefer {
        var facts = host_facts;
        facts.deinit();
    }

    const sources = try inventory.scan(io, gpa, dir, source_root);
    errdefer {
        var scanned = sources;
        scanned.deinit();
    }

    const inputs = try provenance.inspect(io, gpa, dir);
    errdefer {
        var inspected = inputs;
        inspected.deinit();
    }

    const record_text = dir.readFileAlloc(io, manifest_path, gpa, .unlimited) catch return error.MissingPreservationRecord;
    defer gpa.free(record_text);
    var record = manifest.parse(gpa, record_text) catch return error.InvalidPreservationRecord;
    defer record.deinit();
    manifest.verify(io, dir, record) catch return error.InvalidPreservationRecord;

    return .{
        .pin_text = pin_text,
        .pin_matches = pin_matches,
        .host_facts = host_facts,
        .sources = sources,
        .inputs = inputs,
        .protected_files_verified = true,
        .gpa = gpa,
    };
}

test "m00/audit report assembles observed values" {
    std.debug.print("JCKG_EVIDENCE M00-REPORT\n", .{});
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var observed = try audit(io, gpa, "0.18.0-dev.146+35accc06e\n");
    defer observed.deinit();

    try std.testing.expectEqualStrings("0.18.0-dev.146+35accc06e", observed.pin_text);
    try std.testing.expectEqual(@as(?bool, true), observed.pin_matches);
    try std.testing.expect(observed.protected_files_verified);
    try std.testing.expectEqual(host.osFromBuiltin(@import("builtin").os.tag), observed.host_facts.os);
    try std.testing.expectEqual(host.archFromBuiltin(@import("builtin").cpu.arch), observed.host_facts.arch);
    try std.testing.expectEqual(@as(usize, 0), observed.inputs.dependencyCount());
    // The checkout now declares a licence (MIT, added when the repository was
    // published), so the assembled report carries the detected file rather than a
    // gap. The audit reports what exists; this assertion follows the checkout.
    try std.testing.expect(observed.inputs.project_license != null);
    if (observed.inputs.project_license) |license| {
        try std.testing.expectEqualStrings("LICENSE", license);
    }
    try std.testing.expect(observed.sources.find("src/main.zig") != null);
    try std.testing.expect(observed.sources.totalTestBlocks() >= 3);

    // The report serialises to machine-readable JSON with the observed values.
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try observed.writeJson(&out.writer);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, out.written(), .{});
    defer parsed.deinit();
    const root = parsed.value;
    try std.testing.expect(root == .object);
    try std.testing.expectEqual(@as(i64, 1), root.object.get("schemaVersion").?.integer);
    try std.testing.expectEqualStrings("jackage-audit", root.object.get("kind").?.string);
    const host_value = root.object.get("host").?;
    // The audit describes the host it actually ran on. Asserting "windows" here
    // made the report unusable anywhere else, which is exactly what the declared
    // Linux execution environment exposed.
    try std.testing.expectEqualStrings(@tagName(@import("builtin").os.tag), host_value.object.get("os").?.string);
    var expected_target_buffer: [64]u8 = undefined;
    const expected_target = try std.fmt.bufPrint(&expected_target_buffer, "{s}-{s}", .{
        @tagName(@import("builtin").os.tag),
        @tagName(@import("builtin").cpu.arch),
    });
    try std.testing.expectEqualStrings(expected_target, host_value.object.get("target").?.string);
    const toolchain_value = root.object.get("toolchain").?;
    try std.testing.expectEqualStrings("0.18.0-dev.146+35accc06e", toolchain_value.object.get("recorded").?.string);
    try std.testing.expect(toolchain_value.object.get("matches").?.bool);
    const preservation = root.object.get("preservation").?;
    try std.testing.expect(preservation.object.get("recordVerified").?.bool);
    const provenance_value = root.object.get("provenance").?;
    try std.testing.expectEqual(@as(i64, 0), provenance_value.object.get("dependencies").?.integer);
    // The published checkout carries an MIT LICENSE, so the JSON report names the
    // detected file. The field is a string when a licence exists and null when it
    // does not; this asserts the observed case.
    try std.testing.expectEqualStrings("LICENSE", provenance_value.object.get("projectLicense").?.string);
    try std.testing.expectEqualStrings(
        "ec5d64aae44b54ce8425ecd7b40f1fa5c8061d1dc80939b02ed036513d69ae67",
        provenance_value.object.get("toolchainSha256").?.string,
    );

    // Negative-or-recovery: a mismatching compiler report is reported, not
    // swallowed, and the observation still completes for diagnostics.
    var mismatched = try audit(io, gpa, "0.15.1\n");
    defer mismatched.deinit();
    try std.testing.expectEqual(@as(?bool, false), mismatched.pin_matches);
    try std.testing.expectEqualStrings("0.18.0-dev.146+35accc06e", mismatched.pin_text);

    // Without any compiler report the pin is simply unchecked.
    var unchecked_state = try audit(io, gpa, null);
    defer unchecked_state.deinit();
    try std.testing.expect(unchecked_state.pin_matches == null);
}
