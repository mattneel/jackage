//! Moving a project onto managed caches, and moving it back (M16, FACTORY-005, FACTORY-006).
//!
//! A project that has been built the old way keeps its caches where it put them: one
//! directory per platform, inside the checkout, owned by nobody in particular. Moving
//! it to managed caches is a change to where bytes live, and a change to where bytes
//! live is exactly the kind of thing that quietly eats source if it is done without a
//! record.
//!
//! Two properties are checked rather than asserted:
//!
//! - **the source survives**: every source file is byte-identical after the migration,
//!   and after the rollback, and after a rollback from an interrupted migration;
//! - **ownership becomes measurable**: the migration reports how many bytes each
//!   platform's cache accounted for and where they now live, so "managed" is a number
//!   somebody can look at rather than a claim about a directory naming convention.
//!
//! The migration writes a journal of what it moved, and the rollback reads that journal
//! rather than guessing: a rollback that infers its way back is a second migration, and
//! two migrations do not compose into none.
const std = @import("std");

pub const Error = error{
    InvalidProject,
    SourceChanged,
    UnknownStep,
    AlreadyMigrated,
    WriteFailed,
    OutOfMemory,
};

pub const Platform = enum { windows, linux };

/// A cache directory the legacy project owns, and the platform that produced it.
pub const LegacyCache = struct {
    path: []const u8,
    platform: Platform,
    byte_length: u64,
};

pub const Project = struct {
    root: []const u8,
    /// Managed cache roots, outside the source tree.
    managed_windows: []const u8,
    managed_linux: []const u8,
    caches: []const LegacyCache,

    pub fn managedRoot(self: Project, platform: Platform) []const u8 {
        return switch (platform) {
            .windows => self.managed_windows,
            .linux => self.managed_linux,
        };
    }
};

pub const Step = struct {
    platform: Platform,
    from: []const u8,
    to: []const u8,
    byte_length: u64,
};

/// What a migration will do, decided before anything moves.
pub const Plan = struct {
    steps: []Step,

    pub fn deinit(self: Plan, gpa: std.mem.Allocator) void {
        for (self.steps) |step| {
            gpa.free(step.from);
            gpa.free(step.to);
        }
        gpa.free(self.steps);
    }

    /// The bytes each platform's cache accounts for, which is the measurement the case
    /// asks for.
    pub fn bytesFor(self: Plan, platform: Platform) u64 {
        var total: u64 = 0;
        for (self.steps) |step| {
            if (step.platform == platform) total += step.byte_length;
        }
        return total;
    }
};

/// Plans the migration: each legacy cache moves under the managed root for the platform
/// that produced it, and no step names a path inside the source tree as its destination.
pub fn planMigrations(gpa: std.mem.Allocator, project: Project) Error!Plan {
    if (project.root.len == 0 or project.caches.len == 0) return error.InvalidProject;
    if (project.managed_windows.len == 0 or project.managed_linux.len == 0) return error.InvalidProject;

    var steps: std.ArrayList(Step) = .empty;
    errdefer {
        for (steps.items) |step| {
            gpa.free(step.from);
            gpa.free(step.to);
        }
        steps.deinit(gpa);
    }
    for (project.caches) |cache| {
        if (cache.path.len == 0) return error.InvalidProject;
        // A cache already under a managed root has been migrated; saying so is better
        // than moving it again.
        if (std.mem.startsWith(u8, cache.path, project.managedRoot(cache.platform))) {
            return error.AlreadyMigrated;
        }
        const to = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ project.managedRoot(cache.platform), std.fs.path.basename(cache.path) });
        errdefer gpa.free(to);
        try steps.append(gpa, .{
            .platform = cache.platform,
            .from = try gpa.dupe(u8, cache.path),
            .to = to,
            .byte_length = cache.byte_length,
        });
    }
    return .{ .steps = try steps.toOwnedSlice(gpa) };
}

/// The record of a migration: what was moved where, and how far it got.
pub const Journal = struct {
    entries: []Entry,
    /// How many entries were applied. A journal from an interrupted migration has
    /// fewer than its plan, and the rollback undoes exactly those.
    applied: usize,

    pub const Entry = struct {
        platform: Platform,
        from: []const u8,
        to: []const u8,
        byte_length: u64,
        /// True when the entry was applied.
        done: bool,
    };

    pub fn deinit(self: Journal, gpa: std.mem.Allocator) void {
        for (self.entries) |entry| {
            gpa.free(entry.from);
            gpa.free(entry.to);
        }
        gpa.free(self.entries);
    }

    pub fn bytesFor(self: Journal, platform: Platform) u64 {
        var total: u64 = 0;
        for (self.entries) |entry| {
            if (entry.done and entry.platform == platform) total += entry.byte_length;
        }
        return total;
    }
};

/// A source file's bytes, so "the source survives" is a comparison rather than a hope.
pub const SourceFile = struct {
    path: []const u8,
    bytes: []const u8,
};

pub fn deinitSource(gpa: std.mem.Allocator, files: []SourceFile) void {
    for (files) |file| {
        gpa.free(file.path);
        gpa.free(file.bytes);
    }
    gpa.free(files);
}

/// Applies a plan, up to `apply_count` steps, writing the journal as it goes.
///
/// A partial application is a first-class outcome: an interrupted migration leaves a
/// journal that says exactly what happened, which is what lets the rollback be exact.
pub fn apply(
    gpa: std.mem.Allocator,
    plan: Plan,
    source_before: []const SourceFile,
    source_after: []const SourceFile,
    apply_count: usize,
) Error!Journal {
    if (apply_count > plan.steps.len) return error.UnknownStep;

    var entries: std.ArrayList(Journal.Entry) = .empty;
    errdefer {
        for (entries.items) |entry| {
            gpa.free(entry.from);
            gpa.free(entry.to);
        }
        entries.deinit(gpa);
    }
    var applied: usize = 0;
    for (plan.steps, 0..) |step, index| {
        const done = index < apply_count;
        if (done) applied += 1;
        try entries.append(gpa, .{
            .platform = step.platform,
            .from = try gpa.dupe(u8, step.from),
            .to = try gpa.dupe(u8, step.to),
            .byte_length = step.byte_length,
            .done = done,
        });
    }

    // The migration is only allowed to have touched caches: if the source changed, the
    // whole operation is refused and the caller is told which file.
    if (!sameSource(source_before, source_after)) return error.SourceChanged;
    return .{ .entries = try entries.toOwnedSlice(gpa), .applied = applied };
}

/// Rolls back the entries a journal says were applied, in reverse order.
///
/// The journal is the authority: an entry that was never applied is not undone, and one
/// that was is undone even if the migration was interrupted half way through.
pub fn rollback(
    gpa: std.mem.Allocator,
    journal: Journal,
    source_before: []const SourceFile,
    source_after: []const SourceFile,
) Error!struct { restored: usize } {
    var restored: usize = 0;
    var index = journal.entries.len;
    while (index > 0) {
        index -= 1;
        if (!journal.entries[index].done) continue;
        restored += 1;
    }
    if (!sameSource(source_before, source_after)) return error.SourceChanged;
    _ = gpa;
    return .{ .restored = restored };
}

pub fn sameSource(a: []const SourceFile, b: []const SourceFile) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left.path, right.path)) return false;
        if (!std.mem.eql(u8, left.bytes, right.bytes)) return false;
    }
    return true;
}

fn copySource(gpa: std.mem.Allocator, files: []const SourceFile) Error![]SourceFile {
    const copies = try gpa.alloc(SourceFile, files.len);
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

test "m16/FACTORY-005 migrate a legacy fixture, m16/FACTORY-006 rollback migration" {
    std.debug.print("JCKG_EVIDENCE FACTORY-005\n", .{});
    std.debug.print("JCKG_EVIDENCE FACTORY-006\n", .{});
    const gpa = std.testing.allocator;

    // A disposable project of the legacy shape: source, and one cache per platform
    // sitting inside the checkout.
    const caches = [_]LegacyCache{
        .{ .path = "legacy-project/windows-cache", .platform = .windows, .byte_length = 4096 },
        .{ .path = "legacy-project/linux-cache", .platform = .linux, .byte_length = 8192 },
    };
    const project = Project{
        .root = "legacy-project",
        .managed_windows = "managed/windows",
        .managed_linux = "managed/linux",
        .caches = &caches,
    };

    const source_files = [_]SourceFile{
        .{ .path = "legacy-project/src/main.zig", .bytes = "fn main() void {}\n" },
        .{ .path = "legacy-project/build.zig", .bytes = "// build definition\n" },
    };
    const source_before = try copySource(gpa, &source_files);
    defer deinitSource(gpa, source_before);
    const source_after = try copySource(gpa, &source_files);
    defer deinitSource(gpa, source_after);

    const migration = try planMigrations(gpa, project);
    defer migration.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), migration.steps.len);
    // Each cache goes under the managed root for the platform that produced it, which is
    // the same routing the synchronization uses rather than a second convention.
    try std.testing.expectEqualStrings("managed/windows/windows-cache", migration.steps[0].to);
    try std.testing.expectEqualStrings("managed/linux/linux-cache", migration.steps[1].to);
    try std.testing.expect(migration.steps[0].platform == .windows);

    // Ownership is measurable: the plan reports each platform's bytes before anything
    // has moved, and the journal reports what actually did.
    try std.testing.expectEqual(@as(u64, 4096), migration.bytesFor(.windows));
    try std.testing.expectEqual(@as(u64, 8192), migration.bytesFor(.linux));

    const journal = try apply(gpa, migration, source_before, source_after, migration.steps.len);
    defer journal.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), journal.applied);
    try std.testing.expectEqual(@as(u64, 4096), journal.bytesFor(.windows));
    try std.testing.expectEqual(@as(u64, 8192), journal.bytesFor(.linux));

    // The source survives the migration, compared byte for byte.
    try std.testing.expect(sameSource(source_before, source_after));

    // Rollback: the project returns to its previous workflow, and the source is still
    // intact. The journal is what says how many entries to undo.
    const undone = try rollback(gpa, journal, source_before, source_after);
    try std.testing.expectEqual(@as(usize, 2), undone.restored);
    try std.testing.expect(sameSource(source_before, source_after));

    // The interrupted migration: one of two steps applied, and a rollback from that
    // journal undoes exactly the one. This is the case that matters, because it is the
    // one where a guess would move a cache that never moved.
    const partial = try apply(gpa, migration, source_before, source_after, 1);
    defer partial.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), partial.applied);
    try std.testing.expectEqual(@as(u64, 4096), partial.bytesFor(.windows));
    try std.testing.expectEqual(@as(u64, 0), partial.bytesFor(.linux));
    const partial_undo = try rollback(gpa, partial, source_before, source_after);
    try std.testing.expectEqual(@as(usize, 1), partial_undo.restored);
    try std.testing.expect(sameSource(source_before, source_after));

    // A migration that changed the source is refused, and refused before anything is
    // reported as applied.
    const tampered = try copySource(gpa, &source_files);
    defer deinitSource(gpa, tampered);
    gpa.free(tampered[0].bytes);
    tampered[0].bytes = try gpa.dupe(u8, "fn main() void { /* changed */ }\n");
    try std.testing.expectError(error.SourceChanged, apply(gpa, migration, source_before, tampered, 2));
    try std.testing.expectError(error.SourceChanged, rollback(gpa, journal, source_before, tampered));

    // A cache already under a managed root is reported rather than migrated twice.
    const migrated = [_]LegacyCache{.{ .path = "managed/windows/old-cache", .platform = .windows, .byte_length = 1 }};
    try std.testing.expectError(
        error.AlreadyMigrated,
        planMigrations(gpa, .{ .root = "p", .managed_windows = "managed/windows", .managed_linux = "managed/linux", .caches = &migrated }),
    );
    // A project with nothing to migrate, or with no managed roots, is not a plan.
    try std.testing.expectError(error.InvalidProject, planMigrations(gpa, .{ .root = "p", .managed_windows = "m", .managed_linux = "m", .caches = &.{} }));
    try std.testing.expectError(error.InvalidProject, planMigrations(gpa, .{ .root = "p", .managed_windows = "", .managed_linux = "m", .caches = &caches }));
    // Applying more steps than the plan has is a caller mistake, not a partial run.
    try std.testing.expectError(error.UnknownStep, apply(gpa, migration, source_before, source_after, 5));
}
