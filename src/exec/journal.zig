//! Durable action ownership records, one atomic JSON file per action.
//!
//! Controller startup must reconcile PID *and creation time* before retrying
//! or collecting. A `started` record without an identity is uncertain (the
//! controller may have failed between suspended spawn and recording its PID),
//! so it never authorizes an automatic retry. Live records retain ownership.
const std = @import("std");
const tree = @import("../core/tree.zig");
const windows = @import("windows.zig");

pub const Phase = enum { started, running, completed };
pub const ProcessState = enum { not_started, live, gone, unknown };

pub const Entry = struct {
    schema_version: u32 = 1,
    action_id: []const u8,
    phase: Phase,
    process: ?windows.Identity = null,
    descendants: []const windows.Identity = &.{},
    result_status: ?[]const u8 = null,
};

pub const Observation = struct {
    action_id: []const u8,
    phase: Phase,
    process_state: ProcessState,
    live_descendants: usize,
    /// False means retry, collection, and lease release must all be refused.
    safe_to_retry: bool,
};

pub const Reconciliation = struct {
    observations: []Observation,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Reconciliation) void {
        for (self.observations) |item| self.gpa.free(item.action_id);
        self.gpa.free(self.observations);
        self.* = undefined;
    }
};

pub const Journal = struct {
    dir: std.Io.Dir,
    io: std.Io,
    gpa: std.mem.Allocator,

    fn path(action_id: []const u8, buffer: []u8) ![]const u8 {
        if (!tree.portablePathValid(action_id) or std.mem.indexOfScalar(u8, action_id, '/') != null) return error.InvalidActionId;
        return std.fmt.bufPrint(buffer, "{s}.json", .{action_id});
    }

    /// Flush data before atomic replacement. Workspace output scans never
    /// include this directory; the controller owns it outside the workspace.
    pub fn record(self: Journal, entry: Entry) !void {
        if (entry.schema_version != 1) return error.JournalVersionUnsupported;
        var path_buffer: [tree.max_path_bytes + 8]u8 = undefined;
        const final_path = try path(entry.action_id, &path_buffer);
        const bytes = try std.json.Stringify.valueAlloc(self.gpa, entry, .{});
        defer self.gpa.free(bytes);
        var nonce: [16]u8 = undefined;
        self.io.random(&nonce);
        var temporary_buffer: [64]u8 = undefined;
        const temporary = try std.fmt.bufPrint(&temporary_buffer, ".write-{s}", .{std.fmt.bytesToHex(nonce, .lower)});
        defer self.dir.deleteFile(self.io, temporary) catch {};
        {
            const file = try self.dir.createFile(self.io, temporary, .{ .exclusive = true });
            defer file.close(self.io);
            try file.writeStreamingAll(self.io, bytes);
            try file.sync(self.io);
        }
        try self.dir.rename(temporary, self.dir, final_path, self.io);
    }

    pub fn read(self: Journal, action_id: []const u8) !std.json.Parsed(Entry) {
        var buffer: [tree.max_path_bytes + 8]u8 = undefined;
        const bytes = try self.dir.readFileAlloc(self.io, try path(action_id, &buffer), self.gpa, .limited(1024 * 1024));
        defer self.gpa.free(bytes);
        const parsed = try std.json.parseFromSlice(Entry, self.gpa, bytes, .{ .allocate = .alloc_always });
        errdefer parsed.deinit();
        if (parsed.value.schema_version != 1 or !std.mem.eql(u8, action_id, parsed.value.action_id)) return error.JournalCorrupt;
        return parsed;
    }

    pub fn reconcile(self: Journal, action_id: []const u8) !Observation {
        const parsed = self.read(action_id) catch |err| switch (err) {
            error.FileNotFound => return .{
                .action_id = action_id,
                .phase = .started,
                .process_state = .not_started,
                .live_descendants = 0,
                .safe_to_retry = true,
            },
            else => return err,
        };
        defer parsed.deinit();
        const entry = parsed.value;
        const process_state: ProcessState = if (entry.process) |process| switch (windows.state(process)) {
            .live => .live,
            .gone => .gone,
            .unknown => .unknown,
        } else if (entry.phase == .completed) .gone else .unknown;
        var live_descendants: usize = 0;
        var uncertain = process_state == .unknown;
        for (entry.descendants) |descendant| {
            switch (windows.state(descendant)) {
                .live => live_descendants += 1,
                .unknown => uncertain = true,
                .gone => {},
            }
        }
        return .{
            .action_id = action_id,
            .phase = entry.phase,
            .process_state = process_state,
            .live_descendants = live_descendants,
            .safe_to_retry = process_state == .gone and live_descendants == 0 and !uncertain,
        };
    }

    /// A new controller reports all persisted records before doing new work.
    pub fn reconcileAll(self: Journal) !Reconciliation {
        var observations: std.ArrayList(Observation) = .empty;
        errdefer {
            for (observations.items) |item| self.gpa.free(item.action_id);
            observations.deinit(self.gpa);
        }
        var iterator = self.dir.iterate();
        while (try iterator.next(self.io)) |file| {
            if (file.kind != .file or !std.mem.endsWith(u8, file.name, ".json")) continue;
            const id = file.name[0 .. file.name.len - 5];
            var observation = try self.reconcile(id);
            observation.action_id = try self.gpa.dupe(u8, id);
            errdefer self.gpa.free(observation.action_id);
            try observations.append(self.gpa, observation);
        }
        return .{ .observations = try observations.toOwnedSlice(self.gpa), .gpa = self.gpa };
    }
};
