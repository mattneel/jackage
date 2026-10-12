//! Two work units from one baseline (M16, FACTORY-004).
//!
//! Two agents starting from the same source need two places to write. If they share a
//! directory, each one's build sees the other's half-finished edits, and the failure is
//! not a merge conflict somebody resolves - it is a build that produced a plausible
//! artifact from a state that never existed.
//!
//! So a work unit gets its own workspace, copied from the baseline, and nothing else
//! writes there. The baseline is never a working directory: it is read to make
//! workspaces and to integrate from them, and the test checks that it is byte-identical
//! afterwards.
//!
//! Integration is explicit and separate from editing. Bringing a workspace's changes
//! into the baseline is a named operation over a manifest of changes, and it refuses a
//! change to a file that has moved in the baseline since the workspace was taken -
//! because that is not an integration, it is one agent's work replacing another's.
const std = @import("std");

pub const Error = error{
    InvalidBaseline,
    WorkspaceExists,
    MissingFile,
    BaselineMoved,
    ConflictingChange,
    NotIntegrated,
    WriteFailed,
    OutOfMemory,
};

pub const File = struct {
    path: []const u8,
    bytes: []const u8,
};

/// A source baseline: named files with their exact bytes.
pub const Baseline = struct {
    files: []const File,

    pub fn find(self: Baseline, path: []const u8) ?File {
        for (self.files) |file| {
            if (std.mem.eql(u8, file.path, path)) return file;
        }
        return null;
    }
};

/// One work unit's private copy of the baseline.
pub const Workspace = struct {
    name: []const u8,
    root: []const u8,
    /// The baseline as it was when the workspace was taken. Integration compares
    /// against this rather than against the baseline's current state, which is what
    /// makes "the baseline moved" detectable.
    taken_from: []const File,

    pub fn find(self: Workspace, path: []const u8) ?File {
        for (self.taken_from) |file| {
            if (std.mem.eql(u8, file.path, path)) return file;
        }
        return null;
    }

    pub fn deinit(self: Workspace, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        gpa.free(self.root);
        for (self.taken_from) |file| {
            gpa.free(file.path);
            gpa.free(file.bytes);
        }
        gpa.free(self.taken_from);
    }
};

fn copyFiles(gpa: std.mem.Allocator, files: []const File) Error![]File {
    const copies = try gpa.alloc(File, files.len);
    var filled: usize = 0;
    errdefer {
        for (copies[0..filled]) |file| {
            gpa.free(file.path);
            gpa.free(file.bytes);
        }
        gpa.free(copies);
    }
    for (files, 0..) |file, index| {
        copies[index] = .{
            .path = try gpa.dupe(u8, file.path),
            .bytes = try gpa.dupe(u8, file.bytes),
        };
        filled += 1;
    }
    return copies;
}

/// Frees a file list. The slice is taken by const because it is often the const view a
/// baseline or a workspace exposes; the allocator frees it either way.
pub fn deinitFiles(gpa: std.mem.Allocator, files: []const File) void {
    for (files) |file| {
        gpa.free(file.path);
        gpa.free(file.bytes);
    }
    gpa.free(files);
}

/// Takes a workspace for a work unit: its own root, and its own copy of the baseline.
///
/// Two work units cannot share a root, and a root that is already taken is refused
/// rather than reused - silently reusing one is how two agents end up writing to the
/// same files.
pub fn take(gpa: std.mem.Allocator, baseline: Baseline, name: []const u8, root: []const u8, existing: []const Workspace) Error!Workspace {
    if (baseline.files.len == 0 or name.len == 0 or root.len == 0) return error.InvalidBaseline;
    for (existing) |workspace| {
        if (std.mem.eql(u8, workspace.root, root) or std.mem.eql(u8, workspace.name, name)) {
            return error.WorkspaceExists;
        }
    }
    return .{
        .name = try gpa.dupe(u8, name),
        .root = try gpa.dupe(u8, root),
        .taken_from = try copyFiles(gpa, baseline.files),
    };
}

/// A change a work unit made: a file it wrote. Absent means the workspace left the
/// file as it found it.
pub const Change = struct {
    path: []const u8,
    bytes: []const u8,
    /// True when the work unit deleted the file.
    deleted: bool = false,
};

/// Integrates one workspace's changes into the baseline, explicitly.
///
/// A change is refused when the baseline's copy of that file no longer matches what the
/// workspace started from: another work unit has been integrated since, and writing
/// over it would replace their work with this one's. Two changes to the same file are
/// therefore not merged - the second is refused, and the caller decides.
pub fn integrate(
    gpa: std.mem.Allocator,
    baseline: *Baseline,
    workspace: Workspace,
    changes: []const Change,
) Error!Baseline {
    if (changes.len == 0) return error.NotIntegrated;

    var result: std.ArrayList(File) = .empty;
    errdefer {
        for (result.items) |file| {
            gpa.free(file.path);
            gpa.free(file.bytes);
        }
        result.deinit(gpa);
    }
    // Start from the baseline as it is now.
    for (baseline.files) |file| {
        try result.append(gpa, .{
            .path = try gpa.dupe(u8, file.path),
            .bytes = try gpa.dupe(u8, file.bytes),
        });
    }

    for (changes) |change| {
        // What the workspace started from; a change to a file it never had is not an
        // integration either.
        var original: ?File = null;
        for (workspace.taken_from) |file| {
            if (std.mem.eql(u8, file.path, change.path)) original = file;
        }
        if (original == null) return error.MissingFile;

        var index: ?usize = null;
        for (result.items, 0..) |file, position| {
            if (std.mem.eql(u8, file.path, change.path)) index = position;
        }

        // Has the baseline moved for this path? If its current bytes differ from what
        // the workspace started from, integrating would overwrite somebody else's work.
        const current = if (index) |position| result.items[position].bytes else null;
        const unchanged_since_take = if (current) |bytes|
            std.mem.eql(u8, bytes, original.?.bytes)
        else
            false;
        // An already-integrated identical change is idempotent: the same bytes under the
        // same name are the same outcome, so repeating an integration is safe.
        const already_integrated = if (current) |bytes|
            !change.deleted and std.mem.eql(u8, bytes, change.bytes)
        else
            change.deleted;
        if (!unchanged_since_take and !already_integrated) return error.ConflictingChange;

        if (change.deleted) {
            if (index) |position| {
                const removed = result.orderedRemove(position);
                gpa.free(removed.path);
                gpa.free(removed.bytes);
            }
            continue;
        }
        if (index) |position| {
            gpa.free(result.items[position].bytes);
            result.items[position].bytes = try gpa.dupe(u8, change.bytes);
        } else {
            try result.append(gpa, .{
                .path = try gpa.dupe(u8, change.path),
                .bytes = try gpa.dupe(u8, change.bytes),
            });
        }
    }
    deinitFiles(gpa, baseline.files);
    baseline.files = try result.toOwnedSlice(gpa);
    return baseline.*;
}

/// Whether any byte of the baseline changed. The test uses this to assert that taking
/// workspaces and editing inside them leaves the baseline alone.
pub fn sameBytes(a: Baseline, b: Baseline) bool {
    if (a.files.len != b.files.len) return false;
    for (a.files, b.files) |left, right| {
        if (!std.mem.eql(u8, left.path, right.path)) return false;
        if (!std.mem.eql(u8, left.bytes, right.bytes)) return false;
    }
    return true;
}

test "m16/FACTORY-004 isolate parallel agents: distinct workspaces, explicit integration" {
    std.debug.print("JCKG_EVIDENCE FACTORY-004\n", .{});
    const gpa = std.testing.allocator;

    const shared_source = "fn shared() void {}\n";
    const other_source = "const value = 1;\n";
    const baseline_files = [_]File{
        .{ .path = "src/shared.zig", .bytes = shared_source },
        .{ .path = "src/other.zig", .bytes = other_source },
    };
    var baseline = Baseline{ .files = try copyFiles(gpa, &baseline_files) };
    defer deinitFiles(gpa, baseline.files);
    const baseline_before = try copyFiles(gpa, &baseline_files);
    defer deinitFiles(gpa, baseline_before);

    // Two work units, two roots, two copies. Neither can see the other's edits.
    var workspaces: [2]Workspace = undefined;
    workspaces[0] = try take(gpa, baseline, "unit-a", "zig-out/jckg-factory-004/a", workspaces[0..0]);
    defer workspaces[0].deinit(gpa);
    workspaces[1] = try take(gpa, baseline, "unit-b", "zig-out/jckg-factory-004/b", workspaces[0..1]);
    defer workspaces[1].deinit(gpa);

    try std.testing.expect(!std.mem.eql(u8, workspaces[0].root, workspaces[1].root));
    // Each workspace has its own copy rather than a reference to the baseline's bytes,
    // which is what makes one unit's edit invisible to the other.
    for (workspaces) |workspace| {
        try std.testing.expectEqual(@as(usize, 2), workspace.taken_from.len);
        try std.testing.expectEqualStrings(shared_source, workspace.find("src/shared.zig").?.bytes);
    }
    // A workspace with a root or a name already taken is refused, because silently
    // reusing one is how two agents end up writing to the same files.
    try std.testing.expectError(
        error.WorkspaceExists,
        take(gpa, baseline, "unit-a", "zig-out/jckg-factory-004/c", &workspaces),
    );
    try std.testing.expectError(
        error.WorkspaceExists,
        take(gpa, baseline, "unit-c", "zig-out/jckg-factory-004/a", &workspaces),
    );

    // The baseline is untouched by the units' work so far.
    try std.testing.expect(sameBytes(baseline, .{ .files = baseline_before }));

    // Integration is explicit: one unit's change to one file arrives, and the other
    // unit's change to another file arrives after it without conflict.
    const change_a = [_]Change{
        .{ .path = "src/shared.zig", .bytes = "fn shared() void { return; }\n" },
    };
    _ = try integrate(gpa, &baseline, workspaces[0], &change_a);
    try std.testing.expectEqualStrings("fn shared() void { return; }\n", baseline.find("src/shared.zig").?.bytes);
    try std.testing.expectEqualStrings(other_source, baseline.find("src/other.zig").?.bytes);

    const change_b = [_]Change{
        .{ .path = "src/other.zig", .bytes = "const value = 2;\n" },
    };
    _ = try integrate(gpa, &baseline, workspaces[1], &change_b);
    try std.testing.expectEqualStrings("const value = 2;\n", baseline.find("src/other.zig").?.bytes);

    // Repeating an identical integration is idempotent: the same bytes under the same
    // name are the same outcome.
    _ = try integrate(gpa, &baseline, workspaces[0], &change_a);

    // The conflict: the second unit also changed the file the first unit integrated.
    // Its workspace still holds the baseline's original bytes, so integrating now would
    // replace the first unit's work with the second's - refused, as its own error.
    const conflicting = [_]Change{
        .{ .path = "src/shared.zig", .bytes = "fn shared() void { /* b's version */ }\n" },
    };
    try std.testing.expectError(error.ConflictingChange, integrate(gpa, &baseline, workspaces[1], &conflicting));
    // And the refused integration changed nothing.
    try std.testing.expectEqualStrings("fn shared() void { return; }\n", baseline.find("src/shared.zig").?.bytes);

    // A change to a file the workspace never had is not an integration either, and an
    // empty change set is not an integration at all.
    const invented = [_]Change{.{ .path = "src/invented.zig", .bytes = "x\n" }};
    try std.testing.expectError(error.MissingFile, integrate(gpa, &baseline, workspaces[0], &invented));
    try std.testing.expectError(error.NotIntegrated, integrate(gpa, &baseline, workspaces[0], &.{}));

    // A deletion travels the same way.
    const deletion = [_]Change{.{ .path = "src/other.zig", .bytes = "", .deleted = true }};
    const taken_after = try take(gpa, baseline, "unit-d", "zig-out/jckg-factory-004/d", &workspaces);
    defer taken_after.deinit(gpa);
    _ = try integrate(gpa, &baseline, taken_after, &deletion);
    try std.testing.expect(baseline.find("src/other.zig") == null);
}
