//! What a snapshot may contain, decided by an explicit manifest (M12, SPACE-008).
//!
//! M09's plan answers "what is under this directory minus what a build
//! regenerates". That is not the same question as "what may leave the machine":
//! a checkout also holds files that are ignored by version control yet required to
//! build (generated source), and files that must never be copied anywhere (secrets).
//!
//! The manifest makes both explicit. Required inputs are *kept even when ignored*,
//! because generated-but-required source is invisible to the usual "ignored means
//! disposable" rule. Prohibited paths are *excluded even when present*, because the
//! presence of a file is not permission to copy it. A path that is both required and
//! prohibited is refused rather than resolved: the manifest is contradictory, and
//! guessing which instruction wins is how secrets travel.
//!
//! The preview is the whole point of the exercise: every entry carries why it is
//! there, so a person can read the list before anything is copied.
const std = @import("std");

pub const Error = error{
    MissingRequiredInput,
    ProhibitedRequired,
    InvalidManifest,
    OutOfMemory,
};

pub const Reason = enum {
    /// Ordinary source: present, not ignored by policy, not prohibited.
    source,
    /// Required by the manifest even though it would otherwise be excluded - the
    /// generated-but-required case.
    required_input,
};

pub const Entry = struct {
    path: []const u8,
    reason: Reason,
};

pub const Manifest = struct {
    /// Paths the snapshot must contain, whatever their ignore state.
    required_inputs: []const []const u8 = &.{},
    /// Paths that must never be copied, whatever their presence.
    prohibited: []const []const u8 = &.{},
};

pub const Preview = struct {
    entries: []Entry,
    excluded_prohibited: []const []const u8,
    excluded_generated: []const []const u8,

    pub fn deinit(self: Preview, gpa: std.mem.Allocator) void {
        for (self.entries) |entry| gpa.free(entry.path);
        gpa.free(self.entries);
        for (self.excluded_prohibited) |path| gpa.free(path);
        gpa.free(self.excluded_prohibited);
        for (self.excluded_generated) |path| gpa.free(path);
        gpa.free(self.excluded_generated);
    }

    pub fn reasonFor(self: Preview, path: []const u8) ?Reason {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.path, path)) return entry.reason;
        }
        return null;
    }
};

const MAX_PATH = 4096;

fn normalize(buffer: []u8, path: []const u8) Error![]u8 {
    if (path.len == 0 or path.len > MAX_PATH) return error.InvalidManifest;
    var parts: [128][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (count == 0) return error.InvalidManifest;
            count -= 1;
            continue;
        }
        if (count == parts.len) return error.InvalidManifest;
        parts[count] = part;
        count += 1;
    }
    if (count == 0) return error.InvalidManifest;
    var len: usize = 0;
    for (parts[0..count], 0..) |part, index| {
        if (index > 0) {
            buffer[len] = '/';
            len += 1;
        }
        if (len + part.len > MAX_PATH) return error.InvalidManifest;
        @memcpy(buffer[len .. len + part.len], part);
        len += part.len;
    }
    return buffer[0..len];
}

/// True when `root` is `candidate` or contains it, comparing whole components so a
/// prefix-sharing sibling is not mistaken for a contained path.
fn contains(root: []const u8, candidate: []const u8) bool {
    if (candidate.len < root.len) return false;
    if (!std.mem.eql(u8, candidate[0..root.len], root)) return false;
    return candidate.len == root.len or candidate[root.len] == '/';
}

pub const Candidate = struct {
    path: []const u8,
    /// True when the checkout's own ignore rules would exclude this path - which is
    /// not by itself a reason to exclude it from a snapshot.
    ignored: bool = false,
};

/// Computes what the snapshot will contain, and why, or refuses the manifest.
pub fn evaluate(
    gpa: std.mem.Allocator,
    manifest: Manifest,
    candidates: []const Candidate,
) Error!Preview {
    // A path cannot be both required and prohibited.
    for (manifest.required_inputs) |required| {
        var required_buffer: [MAX_PATH]u8 = undefined;
        const normalized_required = try normalize(&required_buffer, required);
        for (manifest.prohibited) |prohibited| {
            var prohibited_buffer: [MAX_PATH]u8 = undefined;
            const normalized_prohibited = try normalize(&prohibited_buffer, prohibited);
            if (contains(normalized_prohibited, normalized_required) or
                contains(normalized_required, normalized_prohibited))
            {
                return error.ProhibitedRequired;
            }
        }
    }

    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |entry| gpa.free(entry.path);
        entries.deinit(gpa);
    }
    var excluded_prohibited: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (excluded_prohibited.items) |path| gpa.free(path);
        excluded_prohibited.deinit(gpa);
    }
    var excluded_generated: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (excluded_generated.items) |path| gpa.free(path);
        excluded_generated.deinit(gpa);
    }

    var required_seen = try gpa.alloc(bool, manifest.required_inputs.len);
    defer gpa.free(required_seen);
    @memset(required_seen, false);

    for (candidates) |candidate| {
        var buffer: [MAX_PATH]u8 = undefined;
        const normalized = try normalize(&buffer, candidate.path);

        // Prohibition first: presence is not permission, so a secret that happens
        // to be in the checkout is excluded before any other rule considers it.
        var prohibited = false;
        for (manifest.prohibited) |rule| {
            var rule_buffer: [MAX_PATH]u8 = undefined;
            const normalized_rule = try normalize(&rule_buffer, rule);
            if (contains(normalized_rule, normalized)) {
                try excluded_prohibited.append(gpa, try gpa.dupe(u8, candidate.path));
                prohibited = true;
                break;
            }
        }
        if (prohibited) continue;

        // Required inputs are kept even when the checkout's ignore rules would
        // exclude them: generated source that a build needs is exactly this case.
        var required = false;
        for (manifest.required_inputs, 0..) |input, index| {
            var input_buffer: [MAX_PATH]u8 = undefined;
            const normalized_input = try normalize(&input_buffer, input);
            if (contains(normalized_input, normalized) or std.mem.eql(u8, normalized_input, normalized)) {
                required = true;
                required_seen[index] = true;
                break;
            }
        }
        if (required) {
            try entries.append(gpa, .{ .path = try gpa.dupe(u8, candidate.path), .reason = .required_input });
            continue;
        }

        if (candidate.ignored) {
            try excluded_generated.append(gpa, try gpa.dupe(u8, candidate.path));
            continue;
        }
        try entries.append(gpa, .{ .path = try gpa.dupe(u8, candidate.path), .reason = .source });
    }

    // A required input that is not in the checkout is named: the snapshot would be
    // incomplete for its purpose, and the path says which declaration was not met.
    for (manifest.required_inputs, 0..) |_, index| {
        // The errdefers above own the partial lists: freeing them here as well
        // would hand the same strings to the allocator twice.
        if (!required_seen[index]) return error.MissingRequiredInput;
    }

    return .{
        .entries = try entries.toOwnedSlice(gpa),
        .excluded_prohibited = try excluded_prohibited.toOwnedSlice(gpa),
        .excluded_generated = try excluded_generated.toOwnedSlice(gpa),
    };
}

test "m12/SPACE-008 preserve source manifest: required inputs included, prohibited data excluded" {
    std.debug.print("JCKG_EVIDENCE SPACE-008\n", .{});
    const gpa = std.testing.allocator;

    const manifest = Manifest{
        // Generated source a build needs: ignored by the checkout, required here.
        .required_inputs = &.{ "generated/version.zig", "build.zig" },
        // Never copied anywhere, whatever the checkout contains.
        .prohibited = &.{ ".env", "secrets" },
    };

    const candidates = [_]Candidate{
        .{ .path = "src/main.zig" },
        .{ .path = "build.zig" },
        // Present on disk, ignored by version control, and required to build.
        .{ .path = "generated/version.zig", .ignored = true },
        // Ignored output: excluded, and named as such.
        .{ .path = "zig-out/jckg", .ignored = true },
        // A secret that lives in the checkout: excluded even though it is present.
        .{ .path = ".env" },
        .{ .path = "secrets/token.txt" },
        // A path that merely starts with the word "secrets" is not prohibited.
        .{ .path = "secrets.md" },
    };

    const preview = try evaluate(gpa, manifest, &candidates);
    defer preview.deinit(gpa);

    // The required generated source is included - the case the ordinary ignore rule
    // would get wrong - and both required inputs are marked as required.
    try std.testing.expectEqual(Reason.required_input, preview.reasonFor("generated/version.zig").?);
    try std.testing.expectEqual(Reason.required_input, preview.reasonFor("build.zig").?);
    try std.testing.expectEqual(Reason.source, preview.reasonFor("src/main.zig").?);
    try std.testing.expectEqual(Reason.source, preview.reasonFor("secrets.md").?);

    // Nothing prohibited reaches the snapshot, and the exclusion is recorded rather
    // than silent.
    try std.testing.expect(preview.reasonFor(".env") == null);
    try std.testing.expect(preview.reasonFor("secrets/token.txt") == null);
    try std.testing.expectEqual(@as(usize, 2), preview.excluded_prohibited.len);
    try std.testing.expectEqual(@as(usize, 1), preview.excluded_generated.len);
    try std.testing.expectEqualStrings("zig-out/jckg", preview.excluded_generated[0]);

    // A required input that is not in the checkout fails, naming the declaration
    // that was not met rather than producing a snapshot missing a build input.
    const absent = [_]Candidate{.{ .path = "src/main.zig" }};
    try std.testing.expectError(error.MissingRequiredInput, evaluate(gpa, manifest, &absent));

    // A manifest that requires a path it also prohibits is contradictory and is
    // refused: guessing which instruction wins is how secrets travel.
    const contradictory = Manifest{
        .required_inputs = &.{"secrets/token.txt"},
        .prohibited = &.{"secrets"},
    };
    try std.testing.expectError(error.ProhibitedRequired, evaluate(gpa, contradictory, &candidates));

    // A prohibited path reached through `..` is still prohibited: the rule is
    // matched against the normalized path, not the written one.
    const disguised = [_]Candidate{ .{ .path = "src/../.env" }, .{ .path = "src/main.zig" } };
    // Prohibition is the rule under test here, so this manifest requires nothing:
    // otherwise the absent required inputs would fail the evaluation first.
    const prohibition_only = Manifest{ .prohibited = &.{".env"} };
    const guarded = try evaluate(gpa, prohibition_only, &disguised);
    defer guarded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), guarded.entries.len);
    try std.testing.expectEqualStrings("src/main.zig", guarded.entries[0].path);

    // With an empty manifest nothing is prohibited and nothing is required: the
    // policy is explicit, not implied.
    const empty_manifest = try evaluate(gpa, .{}, &candidates);
    defer empty_manifest.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), empty_manifest.excluded_prohibited.len);
}
