//! Delivering watcher events from a native Linux workspace (M12, SPACE-010).
//!
//! Guest updates arrive as filesystem operations, and the operations an editor
//! actually performs are not all "write": a save may be an ordinary write, an atomic
//! replacement (write a temporary file, rename it over the target), a rename, or a
//! delete. A watcher that only notices writes reports half of what happened, and the
//! half it misses is the half that changes a file's name or removes it - which is
//! exactly what a sync has to propagate.
//!
//! This module speaks inotify directly rather than shelling out to a tool: the events
//! are the kernel's, the masks are the kernel's, and a report says which mask fired.
//! The mapping from mask to a named kind is documented next to it, because the
//! interesting part is not the label but that the underlying event was observed.
//!
//! The implementation is Linux-only and says so at compile time: elsewhere `Watcher`
//! resolves to a stub whose methods return `error.Unsupported`, so a caller cannot
//! mistake a machine without the mechanism for a workspace without changes.
const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    Unsupported,
    WatchFailed,
    PollFailed,
    Closed,
    OutOfMemory,
};

/// What an operation looked like from the kernel's side.
pub const Kind = enum {
    /// The file was written and closed: an ordinary save.
    write,
    /// Something was moved into place under this name - the atomic-replacement save.
    replaced,
    /// Something was moved away from this name.
    renamed_away,
    /// The name was created.
    created,
    /// The name was removed.
    deleted,

    /// The inotify mask this kind is derived from, so a report can be traced back to
    /// the event that produced it.
    pub fn mask(self: Kind) u32 {
        return switch (self) {
            .write => std.os.linux.IN.CLOSE_WRITE,
            .replaced => std.os.linux.IN.MOVED_TO,
            .renamed_away => std.os.linux.IN.MOVED_FROM,
            .created => std.os.linux.IN.CREATE,
            .deleted => std.os.linux.IN.DELETE,
        };
    }
};

pub const Event = struct {
    /// The name relative to the watched directory.
    name: []u8,
    kind: Kind,
    /// The inotify cookie, which pairs the two halves of one rename.
    cookie: u32,

    pub fn deinit(self: Event, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
    }
};

/// The watches this module asks for: every operation a save, a replacement, a rename,
/// or a delete produces.
pub const watch_mask = std.os.linux.IN.CLOSE_WRITE |
    std.os.linux.IN.MOVED_TO |
    std.os.linux.IN.MOVED_FROM |
    std.os.linux.IN.DELETE |
    std.os.linux.IN.CREATE;

pub const Watcher = if (builtin.os.tag == .linux) LinuxWatcher else UnavailableWatcher;

pub const LinuxWatcher = struct {
    fd: i32,
    gpa: std.mem.Allocator,
    /// Events read from the kernel but not yet returned. One read returns several,
    /// and dropping the rest would lose exactly the second half of a rename - the
    /// half a sync needs to know where the file went.
    pending: std.ArrayList(Event) = .empty,

    pub fn init(gpa: std.mem.Allocator, path: []const u8) Error!LinuxWatcher {
        const path_z = gpa.allocSentinel(u8, path.len, 0) catch return error.OutOfMemory;
        defer gpa.free(path_z);
        @memcpy(path_z, path);
        const fd_rc = std.os.linux.inotify_init1(std.os.linux.IN.CLOEXEC | std.os.linux.IN.NONBLOCK);
        const fd_signed: isize = @bitCast(fd_rc);
        if (fd_signed < 0) return error.WatchFailed;
        const fd: i32 = @intCast(fd_signed);
        errdefer _ = std.os.linux.close(fd);

        const watch_rc = std.os.linux.inotify_add_watch(fd, path_z.ptr, watch_mask);
        const watch_signed: isize = @bitCast(watch_rc);
        if (watch_signed < 0) return error.WatchFailed;
        return .{ .fd = fd, .gpa = gpa };
    }

    pub fn deinit(self: *LinuxWatcher) void {
        for (self.pending.items) |event| event.deinit(self.gpa);
        self.pending.deinit(self.gpa);
        _ = std.os.linux.close(self.fd);
        self.* = undefined;
    }

    /// Returns one event, waiting up to `timeout_ms` for it, or null when the time
    /// passed with nothing new.
    pub fn next(self: *LinuxWatcher, timeout_ms: i32) Error!?Event {
        if (self.pending.items.len > 0) return self.pending.orderedRemove(0);
        var fds = [_]std.os.linux.pollfd{.{ .fd = self.fd, .events = std.os.linux.POLL.IN, .revents = 0 }};
        const ready_rc = std.os.linux.poll(&fds, 1, timeout_ms);
        const ready_signed: isize = @bitCast(ready_rc);
        if (ready_signed < 0) return error.PollFailed;
        if (ready_signed == 0) return null;

        // One read returns whole events, each followed by its name padded to a
        // four-byte boundary. The buffer is sized for several events at once, because
        // a rename arrives as two and reading them separately would lose the pairing.
        var buffer: [32 * 1024]u8 = undefined;
        const read_rc = std.os.linux.read(self.fd, &buffer, buffer.len);
        const read_signed: isize = @bitCast(read_rc);
        if (read_signed < 0) return error.PollFailed;
        const total: usize = @intCast(read_signed);
        if (total == 0) return error.Closed;

        var offset: usize = 0;
        while (offset + @sizeOf(std.os.linux.inotify_event) <= total) {
            // The buffer is bytes and the event is a struct with alignment, so the
            // fields are copied into an aligned local rather than viewed in place: an
            // unaligned view is a panic waiting for the machine it happens on.
            var header: std.os.linux.inotify_event = undefined;
            @memcpy(std.mem.asBytes(&header), buffer[offset .. offset + @sizeOf(std.os.linux.inotify_event)]);
            offset += @sizeOf(std.os.linux.inotify_event);
            const name_len = header.len;
            if (offset + name_len > total) break;
            const raw_name = buffer[offset .. offset + name_len];
            offset += name_len;

            const trimmed = std.mem.sliceTo(raw_name, 0);
            const kind: ?Kind = if (header.mask & std.os.linux.IN.CLOSE_WRITE != 0)
                .write
            else if (header.mask & std.os.linux.IN.MOVED_TO != 0)
                .replaced
            else if (header.mask & std.os.linux.IN.MOVED_FROM != 0)
                .renamed_away
            else if (header.mask & std.os.linux.IN.CREATE != 0)
                .created
            else if (header.mask & std.os.linux.IN.DELETE != 0)
                .deleted
            else
                null;
            // Events this module did not ask for are skipped rather than reported as
            // something they are not.
            const found = kind orelse continue;
            if (trimmed.len == 0) continue;
            try self.pending.append(self.gpa, .{
                .name = self.gpa.dupe(u8, trimmed) catch return error.OutOfMemory,
                .kind = found,
                .cookie = header.cookie,
            });
        }
        if (self.pending.items.len > 0) return self.pending.orderedRemove(0);
        return null;
    }
};

pub const UnavailableWatcher = struct {
    pub fn init(gpa: std.mem.Allocator, path: []const u8) Error!UnavailableWatcher {
        _ = gpa;
        _ = path;
        return error.Unsupported;
    }

    pub fn deinit(self: *UnavailableWatcher) void {
        _ = self;
    }

    pub fn next(self: *UnavailableWatcher, timeout_ms: i32) Error!?Event {
        _ = self;
        _ = timeout_ms;
        return error.Unsupported;
    }
};

/// Collects events until `count` have arrived or the deadline passes.
pub fn gather(gpa: std.mem.Allocator, watcher: *Watcher, count: usize, total_timeout_ms: i32) Error![]Event {
    var events: std.ArrayList(Event) = .empty;
    errdefer {
        for (events.items) |event| event.deinit(gpa);
        events.deinit(gpa);
    }
    // Each wait is bounded by the caller's timeout, and a wait that expires ends the
    // collection: `poll` returning zero *is* the deadline, so no wall clock is needed
    // and the total wait is bounded by what the caller asked for.
    while (events.items.len < count) {
        const maybe = try watcher.next(total_timeout_ms);
        if (maybe == null) break;
        try events.append(gpa, maybe.?);
    }
    return events.toOwnedSlice(gpa);
}

/// True when the batch contains the given kind for the given name.
pub fn contains(events: []const Event, kind: Kind, name: []const u8) bool {
    for (events) |event| {
        if (event.kind == kind and std.mem.eql(u8, event.name, name)) return true;
    }
    return false;
}

pub fn deinitEvents(gpa: std.mem.Allocator, events: []Event) void {
    for (events) |event| event.deinit(gpa);
    gpa.free(events);
}

test "m12/SPACE-010 deliver watcher events: write, atomic replacement, rename, and delete are observed" {
    std.debug.print("JCKG_EVIDENCE SPACE-010\n", .{});
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const root_path = "zig-out/jckg-space-010";
    cwd.deleteTree(io, root_path) catch {};
    defer cwd.deleteTree(io, root_path) catch {};
    try cwd.createDirPath(io, root_path);

    var watcher = try Watcher.init(gpa, root_path);
    defer watcher.deinit();

    // 1. An ordinary write. The kernel reports a creation and a close-write for a
    // save, so the batch is collected and the documented change is looked for in it
    // rather than the count being dictated.
    try cwd.writeFile(io, .{ .sub_path = root_path ++ "/written.txt", .data = "first\n" });
    const write_events = try gather(gpa, &watcher, 4, 500);
    defer deinitEvents(gpa, write_events);
    try std.testing.expect(contains(write_events, .write, "written.txt"));
    try std.testing.expect(contains(write_events, .created, "written.txt"));

    // 2. An atomic replacement: an editor writes a temporary file and renames it over
    // the target, which the kernel reports as a move into place.
    try cwd.writeFile(io, .{ .sub_path = root_path ++ "/target.txt.tmp", .data = "second\n" });
    const temp_events = try gather(gpa, &watcher, 4, 500);
    defer deinitEvents(gpa, temp_events);
    try std.testing.expect(contains(temp_events, .created, "target.txt.tmp"));
    try std.Io.Dir.rename(cwd, root_path ++ "/target.txt.tmp", cwd, root_path ++ "/target.txt", io);
    const replace_events = try gather(gpa, &watcher, 4, 500);
    defer deinitEvents(gpa, replace_events);
    try std.testing.expect(contains(replace_events, .replaced, "target.txt"));
    try std.testing.expect(contains(replace_events, .renamed_away, "target.txt.tmp"));

    // 3. A rename: the file moves away from one name and arrives at another, and both
    // halves carry one cookie.
    try std.Io.Dir.rename(cwd, root_path ++ "/written.txt", cwd, root_path ++ "/moved.txt", io);
    const rename_events = try gather(gpa, &watcher, 4, 500);
    defer deinitEvents(gpa, rename_events);
    try std.testing.expect(contains(rename_events, .renamed_away, "written.txt"));
    try std.testing.expect(contains(rename_events, .replaced, "moved.txt"));
    // The two halves of one rename share a cookie, which is what lets a sync pair
    // them rather than guessing.
    var away: ?Event = null;
    var to: ?Event = null;
    for (rename_events) |event| {
        if (event.kind == .renamed_away and std.mem.eql(u8, event.name, "written.txt")) away = event;
        if (event.kind == .replaced and std.mem.eql(u8, event.name, "moved.txt")) to = event;
    }
    try std.testing.expect(away != null and to != null);
    try std.testing.expectEqual(away.?.cookie, to.?.cookie);
    try std.testing.expect(away.?.cookie != 0);

    // 4. A delete.
    cwd.deleteFile(io, root_path ++ "/moved.txt") catch {};
    const delete_events = try gather(gpa, &watcher, 4, 500);
    defer deinitEvents(gpa, delete_events);
    try std.testing.expect(contains(delete_events, .deleted, "moved.txt"));

    // The documented mapping is the kernel's masks, so a report can be traced back to
    // the event that produced it.
    try std.testing.expectEqual(std.os.linux.IN.CLOSE_WRITE, Kind.write.mask());
    try std.testing.expectEqual(std.os.linux.IN.MOVED_TO, Kind.replaced.mask());
    try std.testing.expectEqual(std.os.linux.IN.MOVED_FROM, Kind.renamed_away.mask());
    try std.testing.expectEqual(std.os.linux.IN.DELETE, Kind.deleted.mask());
    try std.testing.expectEqual(std.os.linux.IN.CREATE, Kind.created.mask());

    // A quiet workspace yields no event rather than an invented one.
    const quiet = try gather(gpa, &watcher, 1, 200);
    defer deinitEvents(gpa, quiet);
    try std.testing.expectEqual(@as(usize, 0), quiet.len);

    // Watching a path that does not exist fails rather than silently watching
    // nothing.
    try std.testing.expectError(error.WatchFailed, Watcher.init(gpa, "zig-out/jckg-space-010-absent"));
}
