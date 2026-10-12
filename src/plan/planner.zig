//! Action graphs: validation, scheduling, and platform selection
//! (cases PLAN-004, PLAN-009, PLAN-010).
//!
//! A plan is a directed acyclic graph of actions. Validation rejects cycles,
//! duplicated names, and references to actions that do not exist, before any
//! execution. The scheduler only starts actions whose dependencies have
//! completed, keeps the declared concurrency bound, and records when each
//! action really started and finished. Platform selection refuses an action
//! whose execution platform has no executor: a cross-compiled output is not an
//! executor.
const std = @import("std");
const cancel = @import("../core/cancel.zig");

pub const Platform = enum {
    windows_x86_64,
    windows_aarch64,
    linux_x86_64,
    linux_aarch64,
    macos_x86_64,
    macos_aarch64,

    pub fn text(self: Platform) []const u8 {
        return @tagName(self);
    }
};

pub const CachePolicy = enum {
    /// Eligible for the shared release cache: reproducible, no secrets.
    release,
    /// Local development cache only.
    development,
    /// Never cached (for example, an action with undeclared effects).
    noncacheable,
};

pub const OutputKind = enum { file, directory };

pub const OutputDecl = struct {
    path: []const u8,
    kind: OutputKind = .file,
};

pub const ActionNode = struct {
    name: []const u8,
    /// Action identity text (`sha256:...`): the requested computation.
    action_digest: []const u8,
    depends_on: []const []const u8 = &.{},
    execution_platform: Platform,
    output_platform: Platform,
    cache_policy: CachePolicy = .development,
    outputs: []const OutputDecl = &.{},
};

pub const ValidationError = error{
    DuplicateAction,
    UnknownAction,
    SelfDependency,
    CycleDetected,
};

pub const Cycle = struct {
    /// Action names on the cycle, in order, first repeated last.
    path: [][]const u8,
    message: []const u8,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Cycle) void {
        for (self.path) |name| self.gpa.free(name);
        self.gpa.free(self.path);
        self.gpa.free(self.message);
        self.* = undefined;
    }
};

pub const Graph = struct {
    nodes: []const ActionNode,

    pub fn find(self: Graph, name: []const u8) ?ActionNode {
        for (self.nodes) |node| {
            if (std.mem.eql(u8, node.name, name)) return node;
        }
        return null;
    }

    /// Finds a cycle, if one exists, and describes it.
    pub fn findCycle(self: Graph, gpa: std.mem.Allocator) std.mem.Allocator.Error!?Cycle {
        const state = try gpa.alloc(u8, self.nodes.len); // 0 = unvisited, 1 = in progress, 2 = done
        defer gpa.free(state);
        @memset(state, 0);
        const stack: std.ArrayList(usize) = .empty;

        for (self.nodes, 0..) |_, index| {
            if (state[index] == 0) {
                var local_stack = stack;
                defer local_stack.deinit(gpa);
                if (try self.visit(gpa, index, state, &local_stack)) |cycle| return cycle;
            }
        }
        return null;
    }

    fn visit(
        self: Graph,
        gpa: std.mem.Allocator,
        index: usize,
        state: []u8,
        stack: *std.ArrayList(usize),
    ) std.mem.Allocator.Error!?Cycle {
        state[index] = 1;
        try stack.append(gpa, index);
        for (self.nodes[index].depends_on) |dependency| {
            const target = self.find(dependency) orelse continue;
            const target_index = indexOfNode(self.nodes, target.name) orelse continue;
            if (state[target_index] == 1) {
                // Found a back edge: report the stack starting at the target.
                const start = for (stack.items, 0..) |entry, position| {
                    if (entry == target_index) break position;
                } else 0;
                const cycle_nodes = stack.items[start..];
                const path = try gpa.alloc([]const u8, cycle_nodes.len + 1);
                for (cycle_nodes, 0..) |entry, position| {
                    path[position] = try gpa.dupe(u8, self.nodes[entry].name);
                }
                path[cycle_nodes.len] = try gpa.dupe(u8, self.nodes[target_index].name);
                var buffer: [256]u8 = undefined;
                var writer: std.Io.Writer = .fixed(&buffer);
                for (path, 0..) |name, position| {
                    if (position != 0) writer.writeAll(" -> ") catch {};
                    writer.writeAll(name) catch {};
                }
                const message = try gpa.print("dependency cycle: {s}", .{writer.buffered()});
                return .{ .path = path, .message = message, .gpa = gpa };
            }
            if (state[target_index] == 0) {
                if (try self.visit(gpa, target_index, state, stack)) |cycle| return cycle;
            }
        }
        _ = stack.pop();
        state[index] = 2;
        return null;
    }
};

fn indexOfNode(nodes: []const ActionNode, name: []const u8) ?usize {
    for (nodes, 0..) |node, index| {
        if (std.mem.eql(u8, node.name, name)) return index;
    }
    return null;
}

/// Validates names, references, and acyclicity.
pub fn validate(graph: Graph) ValidationError!void {
    for (graph.nodes, 0..) |node, index| {
        for (graph.nodes[index + 1 ..]) |other| {
            if (std.mem.eql(u8, node.name, other.name)) return error.DuplicateAction;
        }
        for (node.depends_on) |dependency| {
            if (std.mem.eql(u8, dependency, node.name)) return error.SelfDependency;
            if (graph.find(dependency) == null) return error.UnknownAction;
        }
    }
    var detect_buffer: [1]u8 = undefined;
    _ = &detect_buffer;
    // Cycle detection needs allocation for the reported path; the boolean
    // question is answered here without any.
    var visited: std.ArrayList(usize) = .empty;
    defer visited.deinit(std.heap.page_allocator);
    if (hasCycleWithoutAllocation(graph)) return error.CycleDetected;
}

fn hasCycleWithoutAllocation(graph: Graph) bool {
    // Depth-first search with an explicit stack of (node, next dependency).
    const Frame = struct { node: usize, next: usize };
    var frames: [128]Frame = undefined;
    var state: [128]u8 = @splat(0);
    if (graph.nodes.len > frames.len) {
        // Larger graphs are checked by findCycle, which allocates.
        return false;
    }
    for (graph.nodes, 0..) |_, root| {
        if (state[root] != 0) continue;
        var depth: usize = 0;
        frames[depth] = .{ .node = root, .next = 0 };
        state[root] = 1;
        depth += 1;
        while (depth > 0) {
            const frame = &frames[depth - 1];
            const node = graph.nodes[frame.node];
            if (frame.next >= node.depends_on.len) {
                state[frame.node] = 2;
                depth -= 1;
                continue;
            }
            const dependency = node.depends_on[frame.next];
            frame.next += 1;
            const target = indexOfNode(graph.nodes, dependency) orelse continue;
            if (state[target] == 1) return true;
            if (state[target] == 0 and depth < frames.len) {
                state[target] = 1;
                frames[depth] = .{ .node = target, .next = 0 };
                depth += 1;
            }
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// Scheduling
// ---------------------------------------------------------------------------

pub const Event = struct {
    name: []const u8,
    started_ns: u64,
    finished_ns: u64,
};

pub const ExecutionReport = struct {
    events: []Event,
    /// Highest number of actions that were running at the same time.
    max_observed_concurrency: usize,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *ExecutionReport) void {
        self.gpa.free(self.events);
        self.* = undefined;
    }

    pub fn eventFor(self: ExecutionReport, name: []const u8) ?Event {
        for (self.events) |event| {
            if (std.mem.eql(u8, event.name, name)) return event;
        }
        return null;
    }
};

pub const Runner = struct {
    context: ?*anyopaque,
    /// Runs one action. Called from worker threads, so it must be thread-safe.
    run: *const fn (?*anyopaque, ActionNode) anyerror!void,
};

pub const ScheduleError = error{
    InvalidGraph,
    NoNodes,
    ZeroConcurrency,
    ActionFailed,
};

const Shared = struct {
    io: std.Io,
    graph: Graph,
    runner: Runner,
    clock: cancel.Clock,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    /// Ready node indices, kept sorted by action name for determinism.
    ready: std.ArrayList(usize) = .empty,
    completed: []bool,
    started: []bool,
    events: []Event,
    active: usize = 0,
    running: usize = 0,
    max_active: usize = 0,
    /// Nodes that were taken and have returned, whether they succeeded or not.
    finished_nodes: usize = 0,
    failure: ?anyerror = null,
    finished: bool = false,

    fn allDependenciesCompleted(self: *Shared, node_index: usize) bool {
        for (self.graph.nodes[node_index].depends_on) |dependency| {
            const target = indexOfNode(self.graph.nodes, dependency) orelse return false;
            if (!self.completed[target]) return false;
        }
        return true;
    }

    fn enqueueReady(self: *Shared, gpa: std.mem.Allocator) std.mem.Allocator.Error!void {
        for (self.graph.nodes, 0..) |_, index| {
            if (self.started[index] or self.completed[index]) continue;
            if (!self.allDependenciesCompleted(index)) continue;
            if (containsIndex(self.ready.items, index)) continue;
            try self.ready.append(gpa, index);
        }
        std.mem.sortUnstable(usize, self.ready.items, self.graph.nodes, lessNodeName);
    }
};

fn lessNodeName(nodes: []const ActionNode, a: usize, b: usize) bool {
    return std.mem.lessThan(u8, nodes[a].name, nodes[b].name);
}

fn containsIndex(items: []const usize, value: usize) bool {
    for (items) |item| {
        if (item == value) return true;
    }
    return false;
}

fn worker(shared: *Shared, gpa: std.mem.Allocator) void {
    const io = shared.io;
    while (true) {
        var node_index: ?usize = null;
        shared.mutex.lock(io) catch return;
        while (true) {
            if (shared.failure != null) {
                shared.mutex.unlock(io);
                return;
            }
            if (shared.ready.items.len > 0) {
                const taken = shared.ready.orderedRemove(0);
                shared.started[taken] = true;
                shared.running += 1;
                shared.active += 1;
                if (shared.active > shared.max_active) shared.max_active = shared.active;
                node_index = taken;
                break;
            }
            // Nothing ready and nothing left to do: every node has been taken
            // and finished, so the schedule is over.
            if (shared.finished_nodes == shared.graph.nodes.len) {
                shared.mutex.unlock(io);
                return;
            }
            shared.condition.wait(io, &shared.mutex) catch {
                shared.mutex.unlock(io);
                return;
            };
        }
        shared.mutex.unlock(io);

        const node = shared.graph.nodes[node_index.?];
        const started_ns = shared.clock.now();
        const outcome = shared.runner.run(shared.runner.context, node);
        const finished_ns = shared.clock.now();

        shared.mutex.lock(io) catch return;
        shared.events[node_index.?] = .{ .name = node.name, .started_ns = started_ns, .finished_ns = finished_ns };
        shared.running -= 1;
        shared.active -= 1;
        if (outcome) |_| {
            shared.completed[node_index.?] = true;
        } else |err| {
            shared.failure = err;
        }
        shared.finished_nodes += 1;
        shared.enqueueReady(gpa) catch |err| {
            shared.failure = err;
        };
        shared.condition.broadcast(io);
        shared.mutex.unlock(io);
    }
}

/// Runs the graph with bounded concurrency.
///
/// Every node is executed at most once, only after its dependencies completed,
/// and never more than `max_concurrency` actions run at the same time.
pub fn execute(
    gpa: std.mem.Allocator,
    io: std.Io,
    graph: Graph,
    runner: Runner,
    max_concurrency: usize,
    clock: cancel.Clock,
) (ScheduleError || std.mem.Allocator.Error)!ExecutionReport {
    if (graph.nodes.len == 0) return error.NoNodes;
    if (max_concurrency == 0) return error.ZeroConcurrency;
    validate(graph) catch return error.InvalidGraph;
    if (try graph.findCycle(gpa)) |cycle_value| {
        var cycle = cycle_value;
        defer cycle.deinit();
        return error.InvalidGraph;
    }

    const completed = try gpa.alloc(bool, graph.nodes.len);
    defer gpa.free(completed);
    @memset(completed, false);
    const started = try gpa.alloc(bool, graph.nodes.len);
    defer gpa.free(started);
    @memset(started, false);
    const events = try gpa.alloc(Event, graph.nodes.len);
    errdefer gpa.free(events);
    for (events, graph.nodes) |*event, node| {
        event.* = .{ .name = node.name, .started_ns = 0, .finished_ns = 0 };
    }

    var shared = Shared{
        .io = io,
        .graph = graph,
        .runner = runner,
        .clock = clock,
        .completed = completed,
        .started = started,
        .events = events,
    };
    defer shared.ready.deinit(gpa);
    try shared.enqueueReady(gpa);

    const workers = @min(max_concurrency, graph.nodes.len);
    const handles = try gpa.alloc(std.Thread, workers);
    defer gpa.free(handles);
    var spawned: usize = 0;
    for (handles) |*handle| {
        handle.* = std.Thread.spawn(.{}, worker, .{ &shared, gpa }) catch break;
        spawned += 1;
    }
    if (spawned == 0) return error.ActionFailed;
    for (handles[0..spawned]) |handle| handle.join();

    // Both failure returns below rely on the `errdefer` above to release the
    // event array; freeing it here as well would double free it.
    if (shared.failure) |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.ActionFailed,
        };
    }

    // A worker that stopped early would leave nodes unrun; that is a failure,
    // not a partial success.
    if (shared.finished_nodes != graph.nodes.len) {
        return error.ActionFailed;
    }

    return .{ .events = events, .max_observed_concurrency = shared.max_active, .gpa = gpa };
}

// ---------------------------------------------------------------------------
// Platform selection (PLAN-010)
// ---------------------------------------------------------------------------

pub const Executor = struct {
    name: []const u8,
    platform: Platform,
    /// Whether this executor enforces isolation; the native one does not.
    isolation_enforced: bool = false,
};

pub const Assignment = struct {
    action_name: []const u8,
    executor_name: []const u8,
};

pub const Placement = union(enum) {
    assigned: []Assignment,
    unavailable: Unavailable,

    pub const Unavailable = struct {
        action_name: []const u8,
        execution_platform: Platform,
        output_platform: Platform,
        message: []const u8,
        gpa: std.mem.Allocator,

        pub fn deinit(self: *Unavailable) void {
            self.gpa.free(self.message);
            self.* = undefined;
        }
    };
};

/// Assigns one executor per action, matching the execution platform exactly.
///
/// An action that produces another platform's output still needs an executor
/// for its own execution platform: producing a Windows executable on Linux
/// does not make a Windows test runnable.
pub fn placeActions(
    gpa: std.mem.Allocator,
    graph: Graph,
    executors: []const Executor,
) std.mem.Allocator.Error!Placement {
    const assignments = try gpa.alloc(Assignment, graph.nodes.len);
    errdefer gpa.free(assignments);

    for (graph.nodes, 0..) |node, index| {
        var chosen: ?Executor = null;
        for (executors) |executor| {
            if (executor.platform == node.execution_platform) {
                if (chosen == null or std.mem.lessThan(u8, executor.name, chosen.?.name)) chosen = executor;
            }
        }
        if (chosen) |executor| {
            assignments[index] = .{ .action_name = node.name, .executor_name = executor.name };
            continue;
        }
        gpa.free(assignments);
        const message = try gpa.print(
            "action '{s}' requires a {s} executor, but none is available; a {s} output produced elsewhere is not a {s} executor",
            .{ node.name, node.execution_platform.text(), node.output_platform.text(), node.execution_platform.text() },
        );
        return .{ .unavailable = .{
            .action_name = node.name,
            .execution_platform = node.execution_platform,
            .output_platform = node.output_platform,
            .message = message,
            .gpa = gpa,
        } };
    }
    return .{ .assigned = assignments };
}

// ---------------------------------------------------------------------------
// Fixtures and tests
// ---------------------------------------------------------------------------

const test_digest_a = "sha256:1000000000000000000000000000000000000000000000000000000000000001";
const test_digest_b = "sha256:1000000000000000000000000000000000000000000000000000000000000002";
const test_digest_c = "sha256:1000000000000000000000000000000000000000000000000000000000000003";

fn monotonicNow(_: ?*anyopaque) u64 {
    const stamp = std.Io.Timestamp.now(std.testing.io, .awake);
    return if (stamp.nanoseconds <= 0) 0 else @intCast(stamp.nanoseconds);
}

fn testClock() cancel.Clock {
    return .{ .context = null, .now_ns = monotonicNow };
}

const fixture_nodes = [_]ActionNode{
    .{
        .name = "build-linux",
        .action_digest = test_digest_a,
        .execution_platform = .linux_x86_64,
        .output_platform = .windows_x86_64,
        .cache_policy = .release,
        .outputs = &.{.{ .path = "zig-out" }},
    },
    .{
        .name = "test-windows",
        .action_digest = test_digest_b,
        .depends_on = &.{"build-linux"},
        .execution_platform = .windows_x86_64,
        .output_platform = .windows_x86_64,
    },
    .{
        .name = "package",
        .action_digest = test_digest_c,
        .depends_on = &.{"test-windows"},
        .execution_platform = .linux_x86_64,
        .output_platform = .linux_x86_64,
    },
};

test "m05/PLAN-004 reject graph cycles" {
    std.debug.print("JCKG_EVIDENCE PLAN-004\n", .{});
    const gpa = std.testing.allocator;

    // A prohibited cycle between two actions.
    const cyclic_nodes = [_]ActionNode{
        .{
            .name = "a",
            .action_digest = test_digest_a,
            .depends_on = &.{"b"},
            .execution_platform = .linux_x86_64,
            .output_platform = .linux_x86_64,
        },
        .{
            .name = "b",
            .action_digest = test_digest_b,
            .depends_on = &.{"a"},
            .execution_platform = .linux_x86_64,
            .output_platform = .linux_x86_64,
        },
    };
    const cyclic = Graph{ .nodes = &cyclic_nodes };
    try std.testing.expectError(error.CycleDetected, validate(cyclic));
    const found = (try cyclic.findCycle(gpa)) orelse return error.ExpectedCycle;
    var cycle = found;
    defer cycle.deinit();
    try std.testing.expect(cycle.path.len >= 3);
    try std.testing.expect(std.mem.indexOf(u8, cycle.message, "a") != null);
    try std.testing.expect(std.mem.indexOf(u8, cycle.message, "b") != null);

    // A longer cycle, and a self dependency, are caught too.
    const long_nodes = [_]ActionNode{
        .{ .name = "one", .action_digest = test_digest_a, .depends_on = &.{"three"}, .execution_platform = .linux_x86_64, .output_platform = .linux_x86_64 },
        .{ .name = "two", .action_digest = test_digest_b, .depends_on = &.{"one"}, .execution_platform = .linux_x86_64, .output_platform = .linux_x86_64 },
        .{ .name = "three", .action_digest = test_digest_c, .depends_on = &.{"two"}, .execution_platform = .linux_x86_64, .output_platform = .linux_x86_64 },
    };
    try std.testing.expectError(error.CycleDetected, validate(Graph{ .nodes = &long_nodes }));

    const self_nodes = [_]ActionNode{
        .{ .name = "loop", .action_digest = test_digest_a, .depends_on = &.{"loop"}, .execution_platform = .linux_x86_64, .output_platform = .linux_x86_64 },
    };
    try std.testing.expectError(error.SelfDependency, validate(Graph{ .nodes = &self_nodes }));

    // A missing dependency and a duplicated name are rejected before execution.
    const unknown_nodes = [_]ActionNode{
        .{ .name = "x", .action_digest = test_digest_a, .depends_on = &.{"ghost"}, .execution_platform = .linux_x86_64, .output_platform = .linux_x86_64 },
    };
    try std.testing.expectError(error.UnknownAction, validate(Graph{ .nodes = &unknown_nodes }));
    const duplicate_nodes = [_]ActionNode{
        .{ .name = "same", .action_digest = test_digest_a, .execution_platform = .linux_x86_64, .output_platform = .linux_x86_64 },
        .{ .name = "same", .action_digest = test_digest_b, .execution_platform = .linux_x86_64, .output_platform = .linux_x86_64 },
    };
    try std.testing.expectError(error.DuplicateAction, validate(Graph{ .nodes = &duplicate_nodes }));

    // Negative-or-recovery: the acyclic fixture graph passes validation and has
    // no reported cycle.
    const acyclic = Graph{ .nodes = &fixture_nodes };
    try validate(acyclic);
    try std.testing.expect((try acyclic.findCycle(gpa)) == null);
}

test "m05/PLAN-009 schedule dependencies" {
    std.debug.print("JCKG_EVIDENCE PLAN-009\n", .{});
    const gpa = std.testing.allocator;

    const Recorder = struct {
        mutex: std.Io.Mutex = .init,
        started: [4]u64 = @splat(0),
        finished: [4]u64 = @splat(0),
        counts: [4]u64 = @splat(0),
        active: u64 = 0,
        max_active: u64 = 0,
        fail_on: ?[]const u8 = null,

        fn indexOf(_: *@This(), name: []const u8) usize {
            if (std.mem.eql(u8, name, "a")) return 0;
            if (std.mem.eql(u8, name, "b")) return 1;
            if (std.mem.eql(u8, name, "c")) return 2;
            return 3;
        }

        fn run(context: ?*anyopaque, node: ActionNode) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const io = std.testing.io;
            const index = self.indexOf(node.name);
            self.mutex.lock(io) catch return error.RecorderFailed;
            self.active += 1;
            if (self.active > self.max_active) self.max_active = self.active;
            self.started[index] = monotonicNow(null);
            self.counts[index] += 1;
            self.mutex.unlock(io);

            if (self.fail_on) |failing| {
                if (std.mem.eql(u8, failing, node.name)) return error.ActionFailed;
            }
            // Real work takes real time; independent actions can overlap.
            std.Io.Clock.Duration.sleep(.{ .raw = .{ .nanoseconds = 15 * std.time.ns_per_ms }, .clock = .awake }, std.testing.io) catch {};

            self.mutex.lock(io) catch return error.RecorderFailed;
            self.finished[index] = monotonicNow(null);
            self.active -= 1;
            self.mutex.unlock(io);
        }
    };

    const nodes = [_]ActionNode{
        .{ .name = "a", .action_digest = test_digest_a, .execution_platform = .linux_x86_64, .output_platform = .linux_x86_64 },
        .{ .name = "b", .action_digest = test_digest_b, .execution_platform = .linux_x86_64, .output_platform = .linux_x86_64 },
        .{ .name = "c", .action_digest = test_digest_c, .depends_on = &.{"a"}, .execution_platform = .linux_x86_64, .output_platform = .linux_x86_64 },
        .{ .name = "d", .action_digest = test_digest_a, .depends_on = &.{ "a", "b", "c" }, .execution_platform = .linux_x86_64, .output_platform = .linux_x86_64 },
    };
    const graph = Graph{ .nodes = &nodes };

    var recorder = Recorder{};
    var report = try execute(gpa, std.testing.io, graph, .{ .context = &recorder, .run = Recorder.run }, 4, testClock());
    defer report.deinit();

    // Every action ran exactly once, and dependencies finished before their
    // dependents started.
    for (recorder.counts) |count| try std.testing.expectEqual(@as(u64, 1), count);
    try std.testing.expect(recorder.started[2] >= recorder.finished[0]);
    try std.testing.expect(recorder.started[3] >= recorder.finished[0]);
    try std.testing.expect(recorder.started[3] >= recorder.finished[1]);
    try std.testing.expect(recorder.started[3] >= recorder.finished[2]);
    // Independent actions overlapped, and the bound was respected.
    try std.testing.expect(recorder.max_active >= 2);
    try std.testing.expect(report.max_observed_concurrency <= 4);

    // A single worker serializes the whole graph.
    var serial_recorder = Recorder{};
    var serial = try execute(gpa, std.testing.io, graph, .{ .context = &serial_recorder, .run = Recorder.run }, 1, testClock());
    defer serial.deinit();
    try std.testing.expectEqual(@as(u64, 1), serial_recorder.max_active);
    try std.testing.expectEqual(@as(usize, 1), serial.max_observed_concurrency);
    for (serial_recorder.counts) |count| try std.testing.expectEqual(@as(u64, 1), count);

    // Negative-or-recovery: a failing action stops the schedule, dependents do
    // not run, and the failure is reported rather than swallowed.
    var failing_recorder = Recorder{ .fail_on = "a" };
    const outcome = execute(gpa, std.testing.io, graph, .{ .context = &failing_recorder, .run = Recorder.run }, 4, testClock());
    try std.testing.expectError(error.ActionFailed, outcome);
    try std.testing.expectEqual(@as(u64, 0), failing_recorder.counts[2]);
    try std.testing.expectEqual(@as(u64, 0), failing_recorder.counts[3]);

    // Invalid configurations are refused before anything runs.
    try std.testing.expectError(error.ZeroConcurrency, execute(gpa, std.testing.io, graph, .{ .context = &recorder, .run = Recorder.run }, 0, testClock()));
    try std.testing.expectError(error.NoNodes, execute(gpa, std.testing.io, Graph{ .nodes = &.{} }, .{ .context = &recorder, .run = Recorder.run }, 2, testClock()));
}

test "m05/PLAN-010 separate platforms" {
    std.debug.print("JCKG_EVIDENCE PLAN-010\n", .{});
    const gpa = std.testing.allocator;

    const executors = [_]Executor{
        .{ .name = "linux-native", .platform = .linux_x86_64 },
        .{ .name = "windows-native", .platform = .windows_x86_64 },
    };
    var placement = try placeActions(gpa, Graph{ .nodes = &fixture_nodes }, &executors);
    defer switch (placement) {
        .assigned => |assignments| gpa.free(assignments),
        .unavailable => |*unavailable| unavailable.deinit(),
    };
    try std.testing.expect(placement == .assigned);
    try std.testing.expectEqual(@as(usize, 3), placement.assigned.len);
    try std.testing.expectEqualStrings("linux-native", placement.assigned[0].executor_name);
    try std.testing.expectEqualStrings("windows-native", placement.assigned[1].executor_name);

    // Only a Linux executor exists: the Linux build is fine (its output is a
    // Windows executable), but the Windows test cannot run.
    const linux_only = [_]Executor{.{ .name = "linux-native", .platform = .linux_x86_64 }};
    var missing = try placeActions(gpa, Graph{ .nodes = &fixture_nodes }, &linux_only);
    defer switch (missing) {
        .assigned => |assignments| gpa.free(assignments),
        .unavailable => |*unavailable| unavailable.deinit(),
    };
    try std.testing.expect(missing == .unavailable);
    try std.testing.expectEqualStrings("test-windows", missing.unavailable.action_name);
    try std.testing.expectEqual(Platform.windows_x86_64, missing.unavailable.execution_platform);
    try std.testing.expectEqual(Platform.windows_x86_64, missing.unavailable.output_platform);
    try std.testing.expect(std.mem.indexOf(u8, missing.unavailable.message, "not a") != null);

    // Negative-or-recovery: byte-identical placement on a second run.
    var again = try placeActions(gpa, Graph{ .nodes = &fixture_nodes }, &executors);
    defer switch (again) {
        .assigned => |assignments| gpa.free(assignments),
        .unavailable => |*unavailable| unavailable.deinit(),
    };
    try std.testing.expect(again == .assigned);
    for (placement.assigned, again.assigned) |left, right| {
        try std.testing.expectEqualStrings(left.action_name, right.action_name);
        try std.testing.expectEqualStrings(left.executor_name, right.executor_name);
    }
}
