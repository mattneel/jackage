//! One contract for two callers (M16, FACTORY-001).
//!
//! A human types a command and an agent reads a document, and both are asking for the
//! same thing: run this locked task. The failure this module prevents is the two paths
//! quietly disagreeing - the CLI resolving one plan while the agent's document names
//! another, both appearing to work, and the difference surfacing as an artifact nobody
//! can explain.
//!
//! The way to prevent it is not to make the two sources similar; it is to make them
//! *converge*. Each source is parsed into the same `Request`, the request carries the
//! identities the lockfile fixed - the plan, the policy, and every artifact - and
//! admission compares those identities field by field, naming the one that differs. A
//! request is admitted only when it is the locked task, whatever asked for it.
//!
//! `identity` renders a request canonically and digests it, so "the same request" is a
//! comparison of bytes rather than a claim about the code path that produced it. The
//! test asserts the two sources produce the *same* identity, which is the property the
//! case is about.
const std = @import("std");
const digest = @import("../core/digest.zig");

pub const Error = error{
    InvalidRequest,
    PlanMismatch,
    PolicyMismatch,
    TaskMismatch,
    ArtifactMismatch,
    OutOfMemory,
};

pub const Artifact = struct {
    name: []const u8,
    digest: []const u8,
};

/// The locked task: the identities that govern every path.
pub const Lock = struct {
    task: []const u8,
    plan_digest: []const u8,
    policy_digest: []const u8,
    artifacts: []const Artifact,

    pub fn artifactDigest(self: Lock, name: []const u8) ?[]const u8 {
        for (self.artifacts) |artifact| {
            if (std.mem.eql(u8, artifact.name, name)) return artifact.digest;
        }
        return null;
    }
};

pub const Request = struct {
    task: []const u8,
    plan_digest: []const u8,
    policy_digest: []const u8,
    artifacts: []const Artifact,
    /// Which caller asked, kept for the record and deliberately *not* part of the
    /// identity: the contract is about what is being asked, not who asked it.
    source: Source,

    pub const Source = enum { human, agent };
};

fn checkDigestText(value: []const u8) Error!void {
    _ = digest.Digest.parse(value) catch return error.InvalidRequest;
}

/// Renders a request canonically and digests it.
///
/// Artifacts are rendered in the order the lockfile lists them rather than sorted by
/// name, because the lockfile's order is part of what was locked; the caller passes
/// them in that order from either source.
pub fn identity(gpa: std.mem.Allocator, request: Request) Error![]u8 {
    var canonical: std.ArrayList(u8) = .empty;
    defer canonical.deinit(gpa);
    const head = std.fmt.allocPrint(gpa, "jackage-request-v1\n{s}\n{s}\n{s}\n", .{
        request.task,
        request.plan_digest,
        request.policy_digest,
    }) catch return error.OutOfMemory;
    defer gpa.free(head);
    canonical.appendSlice(gpa, head) catch return error.OutOfMemory;
    for (request.artifacts) |artifact| {
        const line = std.fmt.allocPrint(gpa, "{s} {s}\n", .{ artifact.name, artifact.digest }) catch
            return error.OutOfMemory;
        defer gpa.free(line);
        canonical.appendSlice(gpa, line) catch return error.OutOfMemory;
    }
    return canonicalDigest(gpa, canonical.items);
}

fn canonicalDigest(gpa: std.mem.Allocator, bytes: []const u8) Error![]u8 {
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &raw, .{});
    return std.fmt.allocPrint(gpa, "sha256:{s}", .{std.fmt.bytesToHex(raw, .lower)}) catch error.OutOfMemory;
}

/// Parses the document an agent is given.
///
/// The shape is the documented one: a task, the plan and policy digests it intends to
/// run, and the artifacts it expects. Anything else is refused rather than guessed at.
pub fn fromDocument(gpa: std.mem.Allocator, document: []const u8) Error!Request {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, document, .{}) catch return error.InvalidRequest;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRequest;
    const object = parsed.value.object;
    const task = object.get("task") orelse return error.InvalidRequest;
    const plan = object.get("plan") orelse return error.InvalidRequest;
    const policy = object.get("policy") orelse return error.InvalidRequest;
    if (task != .string or plan != .string or policy != .string) return error.InvalidRequest;
    try checkDigestText(plan.string);
    try checkDigestText(policy.string);

    const artifacts_value = object.get("artifacts") orelse return error.InvalidRequest;
    if (artifacts_value != .array or artifacts_value.array.items.len == 0) return error.InvalidRequest;
    var artifacts = try gpa.alloc(Artifact, artifacts_value.array.items.len);
    var filled: usize = 0;
    errdefer {
        for (artifacts[0..filled]) |artifact| {
            gpa.free(artifact.name);
            gpa.free(artifact.digest);
        }
        gpa.free(artifacts);
    }
    for (artifacts_value.array.items, 0..) |item, index| {
        if (item != .object) return error.InvalidRequest;
        const name = item.object.get("name") orelse return error.InvalidRequest;
        const item_digest = item.object.get("digest") orelse return error.InvalidRequest;
        if (name != .string or item_digest != .string or name.string.len == 0) return error.InvalidRequest;
        try checkDigestText(item_digest.string);
        artifacts[index] = .{
            .name = try gpa.dupe(u8, name.string),
            .digest = try gpa.dupe(u8, item_digest.string),
        };
        filled += 1;
    }
    return .{
        .task = try gpa.dupe(u8, task.string),
        .plan_digest = try gpa.dupe(u8, plan.string),
        .policy_digest = try gpa.dupe(u8, policy.string),
        .artifacts = artifacts,
        .source = .agent,
    };
}

/// Parses the command line a human types.
///
/// The shape follows the documented interface: `--task`, `--plan`, `--policy`, and one
/// `--artifact name=digest` per artifact, in lockfile order.
pub fn fromCommandLine(gpa: std.mem.Allocator, argv: []const []const u8) Error!Request {
    var task: ?[]const u8 = null;
    var plan: ?[]const u8 = null;
    var policy: ?[]const u8 = null;
    var artifacts: std.ArrayList(Artifact) = .empty;
    defer {
        for (artifacts.items) |artifact| {
            gpa.free(artifact.name);
            gpa.free(artifact.digest);
        }
        artifacts.deinit(gpa);
    }

    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const flag = argv[index];
        if (index + 1 >= argv.len) return error.InvalidRequest;
        const value = argv[index + 1];
        index += 1;
        if (std.mem.eql(u8, flag, "--task")) {
            task = value;
        } else if (std.mem.eql(u8, flag, "--plan")) {
            try checkDigestText(value);
            plan = value;
        } else if (std.mem.eql(u8, flag, "--policy")) {
            try checkDigestText(value);
            policy = value;
        } else if (std.mem.eql(u8, flag, "--artifact")) {
            const separator = std.mem.indexOfScalar(u8, value, '=') orelse return error.InvalidRequest;
            if (separator == 0) return error.InvalidRequest;
            try checkDigestText(value[separator + 1 ..]);
            try artifacts.append(gpa, .{
                .name = try gpa.dupe(u8, value[0..separator]),
                .digest = try gpa.dupe(u8, value[separator + 1 ..]),
            });
        } else {
            return error.InvalidRequest;
        }
    }
    if (task == null or plan == null or policy == null or artifacts.items.len == 0) return error.InvalidRequest;

    const owned = try gpa.alloc(Artifact, artifacts.items.len);
    for (artifacts.items, 0..) |artifact, entry| owned[entry] = artifact;
    // Ownership of the names and digests moves into the returned request, so the
    // collection is cleared rather than freed twice.
    artifacts.clearRetainingCapacity();
    return .{
        .task = try gpa.dupe(u8, task.?),
        .plan_digest = try gpa.dupe(u8, plan.?),
        .policy_digest = try gpa.dupe(u8, policy.?),
        .artifacts = owned,
        .source = .human,
    };
}

pub fn deinitRequest(gpa: std.mem.Allocator, request: Request) void {
    gpa.free(request.task);
    gpa.free(request.plan_digest);
    gpa.free(request.policy_digest);
    for (request.artifacts) |artifact| {
        gpa.free(artifact.name);
        gpa.free(artifact.digest);
    }
    gpa.free(request.artifacts);
}

/// Admits a request against the lock, naming the field that differs.
///
/// Identity first: a request that runs another plan is not this task, and admitting it
/// because the artifacts happen to match would be the disagreement this module exists
/// to refuse.
pub fn admit(lock: Lock, request: Request) Error!void {
    if (!std.mem.eql(u8, lock.task, request.task)) return error.TaskMismatch;
    if (!std.mem.eql(u8, lock.plan_digest, request.plan_digest)) return error.PlanMismatch;
    if (!std.mem.eql(u8, lock.policy_digest, request.policy_digest)) return error.PolicyMismatch;
    if (lock.artifacts.len != request.artifacts.len) return error.ArtifactMismatch;
    for (lock.artifacts, 0..) |locked, index| {
        const asked = request.artifacts[index];
        if (!std.mem.eql(u8, locked.name, asked.name)) return error.ArtifactMismatch;
        if (!std.mem.eql(u8, locked.digest, asked.digest)) return error.ArtifactMismatch;
    }
}

test "m16/FACTORY-001 one human-agent contract: both paths are governed by the same identities" {
    std.debug.print("JCKG_EVIDENCE FACTORY-001\n", .{});
    const gpa = std.testing.allocator;

    const payload = "sha256:1111111111111111111111111111111111111111111111111111111111111111";
    const tool = "sha256:2222222222222222222222222222222222222222222222222222222222222222";
    const plan = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const policy = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    const locked_artifacts = [_]Artifact{
        .{ .name = "bin/jckg", .digest = payload },
        .{ .name = "tools/zig", .digest = tool },
    };
    const lock = Lock{
        .task = "selfhost-build",
        .plan_digest = plan,
        .policy_digest = policy,
        .artifacts = &locked_artifacts,
    };

    // The same task, asked for two ways. The agent reads a document; the human types
    // a command line. Neither is privileged over the other.
    const document = 
    \\{"task":"selfhost-build",
    \\ "plan":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    \\ "policy":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    \\ "artifacts":[{"name":"bin/jckg","digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111"},
    \\              {"name":"tools/zig","digest":"sha256:2222222222222222222222222222222222222222222222222222222222222222"}]}
    ;
    const command_line = [_][]const u8{
        "--task",     "selfhost-build",
        "--plan",     plan,
        "--policy",   policy,
        "--artifact", "bin/jckg=sha256:1111111111111111111111111111111111111111111111111111111111111111",
        "--artifact", "tools/zig=sha256:2222222222222222222222222222222222222222222222222222222222222222",
    };

    const from_agent = try fromDocument(gpa, document);
    defer deinitRequest(gpa, from_agent);
    const from_human = try fromCommandLine(gpa, &command_line);
    defer deinitRequest(gpa, from_human);

    // Neither path is admitted by being a path: both are admitted because the
    // identities match the lock.
    try admit(lock, from_agent);
    try admit(lock, from_human);

    // And the identities are the same, compared as bytes rather than argued about.
    const agent_identity = try identity(gpa, from_agent);
    defer gpa.free(agent_identity);
    const human_identity = try identity(gpa, from_human);
    defer gpa.free(human_identity);
    try std.testing.expectEqualStrings(human_identity, agent_identity);
    // The source is recorded but is not part of the identity, which is what lets the
    // same request be compared across callers at all.
    try std.testing.expectEqual(Request.Source.human, from_human.source);
    try std.testing.expectEqual(Request.Source.agent, from_agent.source);

    // A request that runs another plan is refused, and named as a plan mismatch rather
    // than as a generic failure.
    var other_plan = try fromDocument(gpa, document);
    defer deinitRequest(gpa, other_plan);
    gpa.free(other_plan.plan_digest);
    other_plan.plan_digest = try gpa.dupe(u8, tool);
    try std.testing.expectError(error.PlanMismatch, admit(lock, other_plan));

    // Another policy is refused as a policy mismatch: policy is an identity here, not
    // a setting that can be chosen at execution time.
    var other_policy = try fromDocument(gpa, document);
    defer deinitRequest(gpa, other_policy);
    gpa.free(other_policy.policy_digest);
    other_policy.policy_digest = try gpa.dupe(u8, tool);
    try std.testing.expectError(error.PolicyMismatch, admit(lock, other_policy));

    // A different task with the right digests is still a different task.
    var other_task = try fromDocument(gpa, document);
    defer deinitRequest(gpa, other_task);
    gpa.free(other_task.task);
    other_task.task = try gpa.dupe(u8, "something-else");
    try std.testing.expectError(error.TaskMismatch, admit(lock, other_task));

    // An artifact that differs is refused, and so is one that is missing or renamed:
    // the lockfile's list is the whole list.
    const short_artifacts = [_]Artifact{.{ .name = "bin/jckg", .digest = payload }};
    const short_lock = Lock{ .task = lock.task, .plan_digest = plan, .policy_digest = policy, .artifacts = &short_artifacts };
    try std.testing.expectError(error.ArtifactMismatch, admit(short_lock, from_agent));
    const renamed = [_]Artifact{
        .{ .name = "bin/other", .digest = payload },
        .{ .name = "tools/zig", .digest = tool },
    };
    const renamed_lock = Lock{ .task = lock.task, .plan_digest = plan, .policy_digest = policy, .artifacts = &renamed };
    try std.testing.expectError(error.ArtifactMismatch, admit(renamed_lock, from_agent));

    // Both sources refuse malformed input rather than filling in defaults: a request
    // nobody could have meant is not a request.
    try std.testing.expectError(error.InvalidRequest, fromDocument(gpa, "{}"));
    try std.testing.expectError(error.InvalidRequest, fromDocument(gpa, "not json"));
    try std.testing.expectError(error.InvalidRequest, fromDocument(gpa, "{\"task\":\"t\",\"plan\":\"not-a-digest\",\"policy\":\"sha256:bb\",\"artifacts\":[{\"name\":\"a\",\"digest\":\"sha256:aa\"}]}"));
    try std.testing.expectError(error.InvalidRequest, fromDocument(gpa, "{\"task\":\"t\",\"plan\":\"sha256:aa\",\"artifacts\":[]}"));
    try std.testing.expectError(error.InvalidRequest, fromCommandLine(gpa, &.{ "--task", "t", "--plan", plan }));
    try std.testing.expectError(error.InvalidRequest, fromCommandLine(gpa, &.{ "--unknown", "x" }));
    try std.testing.expectError(error.InvalidRequest, fromCommandLine(gpa, &.{ "--task", "t", "--plan", plan, "--policy", policy, "--artifact", "nope" }));
}
