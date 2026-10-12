//! Describing packaging work as declared actions (M10, PACK-001).
//!
//! A package backend does not "do" anything here: it *describes* what it would do,
//! as ordinary action nodes in the plan vocabulary the rest of the product already
//! uses. That is the whole point of the case - the tools and effects a backend
//! brings must be visible to the resolver, the policy layer, and the evidence the
//! same way any other action is, rather than hidden inside a function call.
//!
//! A packaging request turns into three declared actions:
//!
//! | action | depends on | declares |
//! |---|---|---|
//! | `package:materialize:<name>` | - | the tree directory |
//! | `package:archive:<name>:<format>` | materialize | the archive file |
//! | `package:verify:<name>:<format>` | archive | the verification report |
//!
//! The graph is handed to the product's own validator before it is returned, so a
//! backend cannot describe a plan the rest of the system would refuse: duplicates
//! and cycles are caught here, in the backend, not later in the executor.
const std = @import("std");
const planner = @import("../plan/planner.zig");

pub const Error = error{
    InvalidRequest,
    OutOfMemory,
    ValidationFailed,
};

pub const Format = enum { zip, tar };

pub fn formatText(format: Format) []const u8 {
    return switch (format) {
        .zip => "zip",
        .tar => "tar",
    };
}

pub const Request = struct {
    /// The package being built, as the channel will publish it.
    name: []const u8,
    /// The tree the package payload comes from, by content digest.
    tree_digest: []const u8,
    /// The archive format the backend produces.
    format: Format,
    /// The platform the produced artifact runs on.
    output_platform: planner.Platform,
};

fn actionDigest(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &raw, .{});
    const hex = std.fmt.bytesToHex(raw, .lower);
    return std.fmt.allocPrint(gpa, "sha256:{s}", .{hex});
}

pub fn deinitNodes(gpa: std.mem.Allocator, nodes: []planner.ActionNode) void {
    for (nodes) |node| {
        gpa.free(node.name);
        gpa.free(node.action_digest);
        for (node.depends_on) |dependency| {
            gpa.free(@constCast(dependency));
        }
        gpa.free(@constCast(node.depends_on));
        for (node.outputs) |output| {
            gpa.free(@constCast(output.path));
        }
        gpa.free(@constCast(node.outputs));
    }
    gpa.free(nodes);
}

/// Describes the packaging work for one request, as a validated action graph.
pub fn describe(gpa: std.mem.Allocator, request: Request) Error![]planner.ActionNode {
    if (request.name.len == 0 or request.tree_digest.len == 0) return error.InvalidRequest;

    const format = formatText(request.format);
    const materialize_name = try std.fmt.allocPrint(gpa, "package:materialize:{s}", .{request.name});
    errdefer gpa.free(materialize_name);
    const archive_name = try std.fmt.allocPrint(gpa, "package:archive:{s}:{s}", .{ request.name, format });
    errdefer gpa.free(archive_name);
    const verify_name = try std.fmt.allocPrint(gpa, "package:verify:{s}:{s}", .{ request.name, format });
    errdefer gpa.free(verify_name);

    const nodes = try gpa.alloc(planner.ActionNode, 3);
    errdefer gpa.free(nodes);

    // Every action carries the identity of the computation it performs, built from
    // the declared inputs - so two requests that differ only in format are two
    // different actions rather than one name with two meanings.
    // Every node owns its dependency and output arrays, including the ones that are
    // empty: `deinitNodes` frees them unconditionally, and a default literal in one
    // node would be a free of memory nobody allocated.
    const no_dependencies = try gpa.alloc([]const u8, 0);
    errdefer gpa.free(no_dependencies);
    nodes[0] = .{
        .name = materialize_name,
        .action_digest = try actionDigest(gpa, request.tree_digest),
        .depends_on = no_dependencies,
        .execution_platform = request.output_platform,
        .output_platform = request.output_platform,
        .outputs = try gpa.dupe(planner.OutputDecl, &.{.{ .path = try gpa.dupe(u8, request.name), .kind = .directory }}),
    };

    const archive_inputs = try std.fmt.allocPrint(gpa, "{s}|{s}", .{ request.tree_digest, format });
    errdefer gpa.free(archive_inputs);
    // The dependency array owns its strings: `deinitNodes` frees both the array and
    // its entries, so pointing at another node's name would free one allocation
    // twice.
    const dependency = try gpa.alloc([]const u8, 1);
    errdefer gpa.free(dependency);
    dependency[0] = try gpa.dupe(u8, materialize_name);
    nodes[1] = .{
        .name = archive_name,
        .action_digest = try actionDigest(gpa, archive_inputs),
        .depends_on = dependency,
        .execution_platform = request.output_platform,
        .output_platform = request.output_platform,
        // Packaging is not a cacheable development artifact: the archive is what
        // gets published, so it must be produced by running the action.
        .cache_policy = .noncacheable,
        .outputs = try gpa.dupe(planner.OutputDecl, &.{.{ .path = try gpa.dupe(u8, request.name), .kind = .file }}),
    };
    gpa.free(archive_inputs);

    const verify_inputs = try std.fmt.allocPrint(gpa, "{s}|verify", .{nodes[1].action_digest});
    errdefer gpa.free(verify_inputs);
    const verify_dependency = try gpa.alloc([]const u8, 1);
    errdefer gpa.free(verify_dependency);
    verify_dependency[0] = try gpa.dupe(u8, archive_name);
    nodes[2] = .{
        .name = verify_name,
        .action_digest = try actionDigest(gpa, verify_inputs),
        .depends_on = verify_dependency,
        .execution_platform = request.output_platform,
        .output_platform = request.output_platform,
        .outputs = try gpa.dupe(planner.OutputDecl, &.{.{ .path = try gpa.dupe(u8, "verification.json"), .kind = .file }}),
    };
    gpa.free(verify_inputs);

    // The product's own validator decides whether this is a legal plan, so a
    // backend cannot describe work the executor would refuse.
    planner.validate(.{ .nodes = nodes }) catch {
        // The backend validates before returning, so a caller never receives a plan
        // the executor would refuse.
        return error.ValidationFailed;
    };
    return nodes;
}

test "m10/PACK-001 plan package actions: tools and effects are declared actions" {
    std.debug.print("JCKG_EVIDENCE PACK-001\n", .{});
    const gpa = std.testing.allocator;

    const tree_digest = "sha256:1111111111111111111111111111111111111111111111111111111111111111";
    const nodes = try describe(gpa, .{
        .name = "jackage",
        .tree_digest = tree_digest,
        .format = .tar,
        .output_platform = .linux_x86_64,
    });
    defer deinitNodes(gpa, nodes);

    // Three ordinary declared actions: the tree is materialized, the archive is
    // written from it, and the archive is verified. The effects are ordered by
    // declaration, not by hope.
    try std.testing.expectEqual(@as(usize, 3), nodes.len);
    try std.testing.expectEqualStrings("package:materialize:jackage", nodes[0].name);
    try std.testing.expectEqualStrings("package:archive:jackage:tar", nodes[1].name);
    try std.testing.expectEqualStrings("package:verify:jackage:tar", nodes[2].name);
    try std.testing.expectEqual(@as(usize, 0), nodes[0].depends_on.len);
    try std.testing.expectEqualStrings(nodes[0].name, nodes[1].depends_on[0]);
    try std.testing.expectEqualStrings(nodes[1].name, nodes[2].depends_on[0]);
    try std.testing.expectEqual(@as(usize, 1), nodes[0].outputs.len);
    try std.testing.expectEqualStrings("jackage", nodes[0].outputs[0].path);
    try std.testing.expectEqual(planner.OutputKind.directory, nodes[0].outputs[0].kind);
    try std.testing.expectEqual(planner.OutputKind.file, nodes[1].outputs[0].kind);

    // The declared identities are the declared inputs: the same tree in two formats
    // is two different archive actions, and the verification identifies the archive
    // it verifies.
    const zip_nodes = try describe(gpa, .{
        .name = "jackage",
        .tree_digest = tree_digest,
        .format = .zip,
        .output_platform = .linux_x86_64,
    });
    defer deinitNodes(gpa, zip_nodes);
    try std.testing.expect(!std.mem.eql(u8, nodes[1].action_digest, zip_nodes[1].action_digest));
    try std.testing.expect(std.mem.eql(u8, nodes[0].action_digest, zip_nodes[0].action_digest));
    try std.testing.expect(std.mem.eql(u8, nodes[2].action_digest, zip_nodes[2].action_digest) == false);

    // Packaging is not a cacheable development artifact, and it targets the
    // platform it declares rather than the one it happens to run on.
    try std.testing.expectEqual(planner.CachePolicy.noncacheable, nodes[1].cache_policy);
    try std.testing.expectEqual(planner.Platform.linux_x86_64, nodes[1].output_platform);

    // Negative-or-recovery: an incomplete request is refused, and the refusal
    // happens before any action is described.
    try std.testing.expectError(error.InvalidRequest, describe(gpa, .{
        .name = "",
        .tree_digest = tree_digest,
        .format = .tar,
        .output_platform = .linux_x86_64,
    }));
    try std.testing.expectError(error.InvalidRequest, describe(gpa, .{
        .name = "jackage",
        .tree_digest = "",
        .format = .tar,
        .output_platform = .linux_x86_64,
    }));
}
