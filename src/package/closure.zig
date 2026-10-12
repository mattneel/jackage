//! Runtime closure selection for release images (M10, PACK-007).
//!
//! A package has two kinds of dependency: the ones it needs to be *built* and the
//! ones it needs to *run*. A release image contains only the second kind, and the
//! rule that makes this more than a filter is transitive:
//!
//! - a runtime edge from a node in the closure pulls its target in, and so on;
//! - a **build** edge pulls its target in for building only - that target is not in
//!   the closure, and neither are *its* dependencies, however they are labelled.
//!
//! The second rule is the one that matters. A compiler is a build dependency; the
//! libraries the compiler itself needs to run are not dependencies of the product
//! just because the product needs the compiler to be built. Shipping them is how a
//! release image ends up carrying a toolchain.
//!
//! An edge naming a dependency that is not declared is a refusal rather than a
//! shrug: silently ignoring it is how an image ships missing the thing it needed.
const std = @import("std");

pub const Error = error{
    UnknownDependency,
    UnknownRoot,
    DuplicateDependency,
    CycleInRuntimeClosure,
    OutOfMemory,
};

pub const Kind = enum { runtime, build };

pub const Edge = struct {
    /// The dependency's name.
    to: []const u8,
    kind: Kind,
};

pub const Node = struct {
    name: []const u8,
    edges: []const Edge = &.{},
};

pub const Graph = struct {
    nodes: []const Node,

    pub fn find(self: Graph, name: []const u8) ?Node {
        for (self.nodes) |node| {
            if (std.mem.eql(u8, node.name, name)) return node;
        }
        return null;
    }
};

/// The closure a release image is built from: the root plus everything reachable
/// through runtime edges only.
pub const Closure = struct {
    /// Names in the closure, root first, then discovery order.
    names: [][]const u8,

    pub fn deinit(self: Closure, gpa: std.mem.Allocator) void {
        for (self.names) |name| gpa.free(name);
        gpa.free(self.names);
    }

    pub fn contains(self: Closure, name: []const u8) bool {
        for (self.names) |entry| {
            if (std.mem.eql(u8, entry, name)) return true;
        }
        return false;
    }
};

/// Computes the runtime closure of `root`.
///
/// The traversal only ever follows `Kind.runtime` edges, which is exactly the
/// statement "only the declared runtime closure enters the payload": a build edge
/// is recorded in the graph and never followed, so nothing behind it can be pulled
/// in by accident.
pub fn runtimeClosure(gpa: std.mem.Allocator, graph: Graph, root: []const u8) Error!Closure {
    if (graph.find(root) == null) return error.UnknownRoot;

    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |name| gpa.free(name);
        names.deinit(gpa);
    }
    try names.append(gpa, try gpa.dupe(u8, root));

    var index: usize = 0;
    while (index < names.items.len) : (index += 1) {
        const current = graph.find(names.items[index]) orelse return error.UnknownDependency;
        for (current.edges) |edge| {
            if (edge.kind != .runtime) continue;
            const target = graph.find(edge.to) orelse return error.UnknownDependency;
            if (target.name.len == 0) return error.UnknownDependency;
            var already = false;
            for (names.items) |existing| {
                if (std.mem.eql(u8, existing, edge.to)) {
                    already = true;
                    break;
                }
            }
            if (already) continue;
            try names.append(gpa, try gpa.dupe(u8, edge.to));
        }
    }
    return .{ .names = try names.toOwnedSlice(gpa) };
}

/// The build-time closure, for comparison: the root plus everything reachable
/// through *any* edge. A release image must be a strict subset of this whenever the
/// package has a build dependency, which is the assertion that keeps the two
/// notions distinct.
pub fn buildClosure(gpa: std.mem.Allocator, graph: Graph, root: []const u8) Error!Closure {
    if (graph.find(root) == null) return error.UnknownRoot;
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |name| gpa.free(name);
        names.deinit(gpa);
    }
    try names.append(gpa, try gpa.dupe(u8, root));
    var index: usize = 0;
    while (index < names.items.len) : (index += 1) {
        const current = graph.find(names.items[index]) orelse return error.UnknownDependency;
        for (current.edges) |edge| {
            if (graph.find(edge.to) == null) return error.UnknownDependency;
            var already = false;
            for (names.items) |existing| {
                if (std.mem.eql(u8, existing, edge.to)) {
                    already = true;
                    break;
                }
            }
            if (already) continue;
            try names.append(gpa, try gpa.dupe(u8, edge.to));
        }
    }
    return .{ .names = try names.toOwnedSlice(gpa) };
}

test "m10/PACK-007 exclude build-only inputs: only the runtime closure enters the payload" {
    std.debug.print("JCKG_EVIDENCE PACK-007\n", .{});
    const gpa = std.testing.allocator;

    // A real shape: the product needs a compiler to be *built*, and the compiler
    // itself needs a standard library to run. None of that belongs in the image.
    // At runtime the product needs a shared library, which needs another one.
    const graph = Graph{ .nodes = &.{
        .{ .name = "app", .edges = &.{
            .{ .to = "compiler", .kind = .build },
            .{ .to = "libfoo", .kind = .runtime },
        } },
        .{ .name = "compiler", .edges = &.{
            // A build dependency's own dependencies stay build-time, even when they
            // are the kind of thing a program links against.
            .{ .to = "compiler-runtime", .kind = .runtime },
        } },
        .{ .name = "compiler-runtime", .edges = &.{} },
        .{ .name = "libfoo", .edges = &.{
            .{ .to = "libbar", .kind = .runtime },
        } },
        .{ .name = "libbar", .edges = &.{} },
    } };

    const closure = try runtimeClosure(gpa, graph, "app");
    defer closure.deinit(gpa);

    // The runtime closure: the product and what it needs to run, transitively.
    try std.testing.expectEqual(@as(usize, 3), closure.names.len);
    try std.testing.expect(closure.contains("app"));
    try std.testing.expect(closure.contains("libfoo"));
    try std.testing.expect(closure.contains("libbar"));

    // Nothing behind the build edge enters, not even the compiler's own runtime
    // dependencies - the rule that a filter would get wrong.
    try std.testing.expect(!closure.contains("compiler"));
    try std.testing.expect(!closure.contains("compiler-runtime"));

    // The build closure is strictly larger, which is what makes the two notions
    // distinguishable rather than the same list under two names.
    const build = try buildClosure(gpa, graph, "app");
    defer build.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 5), build.names.len);
    try std.testing.expect(build.contains("compiler"));
    try std.testing.expect(build.contains("compiler-runtime"));
    try std.testing.expect(build.names.len > closure.names.len);

    // Negative-or-recovery: an edge naming an undeclared dependency is refused
    // rather than ignored, because silently dropping it is how an image ships
    // missing the library it needed.
    const broken = Graph{ .nodes = &.{
        .{ .name = "app", .edges = &.{.{ .to = "libmissing", .kind = .runtime }} },
    } };
    try std.testing.expectError(error.UnknownDependency, runtimeClosure(gpa, broken, "app"));

    // A root that is not declared is its own error, distinct from a broken edge.
    try std.testing.expectError(error.UnknownRoot, runtimeClosure(gpa, graph, "not-a-package"));
}
