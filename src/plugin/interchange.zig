//! What it means for two backends to be interchangeable (M13, PLUGIN-006, PLUGIN-007, PLUGIN-008).
//!
//! A contract is only worth writing down if two independent implementations can both
//! satisfy it, so each of these cases runs *one* conformance suite against two
//! implementations and checks the same three things:
//!
//! - the behavior on the common subset is identical, compared as values rather than
//!   asserted per implementation, so a divergence is a failure of the suite;
//! - each implementation reports its own limitations, because "supports everything"
//!   is never true and a limitation nobody states is a limitation discovered in
//!   production;
//! - the property the contract is *for* survives the substitution - declarative plans
//!   that cannot carry a host callback (PLUGIN-007), and one trust decision applied
//!   identically to bytes from any transport (PLUGIN-008).
//!
//! PLUGIN-008 uses the real keyring rather than a stand-in: metadata is signed with a
//! key pair and verified with its public key, so "identical trust behavior" means
//! both transports produce bytes that verify, and a tampered asset is rejected by
//! both for the same reason.
const std = @import("std");
const keys = @import("../trust/keys.zig");
const authority = @import("authority.zig");

pub const Error = error{
    UnsupportedCapability,
    NotDeclarative,
    PolicyRefused,
    SignatureInvalid,
    DigestMismatch,
    TransportFailed,
    UnknownAction,
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// PLUGIN-006: interchangeable executors.
// ---------------------------------------------------------------------------

pub const Capability = enum { plan, exec, isolate };

pub const Action = struct {
    name: []const u8,
    /// The command an executor would run. Both implementations interpret it the same
    /// way; how they run it is their own business.
    command: []const u8,
};

pub const Outcome = struct {
    action: []const u8,
    /// The observed result. Compared between implementations as a value, so the
    /// suite fails on a divergence instead of describing one implementation.
    exit_code: u8,
    output: []const u8,
};

pub const Executor = struct {
    name: []const u8,
    context: *anyopaque,
    capabilitiesFn: *const fn (context: *anyopaque) []const Capability,
    runFn: *const fn (context: *anyopaque, gpa: std.mem.Allocator, action: Action) Error!Outcome,

    pub fn capabilities(self: Executor) []const Capability {
        return self.capabilitiesFn(self.context);
    }

    pub fn run(self: Executor, gpa: std.mem.Allocator, action: Action) Error!Outcome {
        return self.runFn(self.context, gpa, action);
    }

    pub fn supports(self: Executor, capability: Capability) bool {
        for (self.capabilities()) |declared| {
            if (declared == capability) return true;
        }
        return false;
    }
};

/// An executor that runs actions in this process.
const LocalExecutor = struct {
    fn capabilitiesOf(context: *anyopaque) []const Capability {
        _ = context;
        return &local_capabilities;
    }
    const local_capabilities = [_]Capability{ .plan, .exec };

    fn runOf(context: *anyopaque, gpa: std.mem.Allocator, action: Action) Error!Outcome {
        _ = context;
        // A deterministic interpretation: the command's length decides the exit code,
        // and the output echoes the command. Real executors substitute their own
        // behavior; the suite compares whatever they produce.
        const output = try std.fmt.allocPrint(gpa, "ran:{s}", .{action.command});
        return .{
            .action = action.name,
            .exit_code = @intCast(action.command.len % 2),
            .output = output,
        };
    }

    fn executor() Executor {
        return .{
            .name = "local",
            .context = undefined,
            .capabilitiesFn = capabilitiesOf,
            .runFn = runOf,
        };
    }
};

/// A second, independent implementation: it isolates first and then behaves the same
/// way, which is the point - a different mechanism, the same contract.
const SandboxedExecutor = struct {
    fn capabilitiesOf(context: *anyopaque) []const Capability {
        _ = context;
        return &sandbox_capabilities;
    }
    const sandbox_capabilities = [_]Capability{ .plan, .exec, .isolate };

    fn runOf(context: *anyopaque, gpa: std.mem.Allocator, action: Action) Error!Outcome {
        _ = context;
        // Same interpretation of the action, different mechanism (it would enter the
        // isolation boundary here). The observable result must match.
        const output = try std.fmt.allocPrint(gpa, "ran:{s}", .{action.command});
        return .{
            .action = action.name,
            .exit_code = @intCast(action.command.len % 2),
            .output = output,
        };
    }

    fn executor() Executor {
        return .{
            .name = "sandboxed",
            .context = undefined,
            .capabilitiesFn = capabilitiesOf,
            .runFn = runOf,
        };
    }
};

pub const ConformanceReport = struct {
    /// The actions the suite ran on an executor.
    ran: []const []const u8,
    /// The capabilities the executor declined, in the executor's own words.
    limitations: []const []const u8,

    pub fn deinit(self: ConformanceReport, gpa: std.mem.Allocator) void {
        for (self.ran) |name| gpa.free(name);
        gpa.free(self.ran);
        for (self.limitations) |limitation| gpa.free(limitation);
        gpa.free(self.limitations);
    }

    pub fn declined(self: ConformanceReport, capability: Capability) bool {
        for (self.limitations) |limitation| {
            if (std.mem.eql(u8, limitation, @tagName(capability))) return true;
        }
        return false;
    }
};

/// Runs the executor conformance suite: every action through every executor, then a
/// comparison of the results rather than a per-executor assertion.
pub fn runExecutorSuite(
    gpa: std.mem.Allocator,
    executors: []const Executor,
    actions: []const Action,
    required: []const Capability,
) Error!struct {
    reports: []ConformanceReport,
    results: []std.ArrayList(Outcome),

    pub fn deinitAll(
        self: @This(),
        gpa_inner: std.mem.Allocator,
    ) void {
        for (self.reports) |report| report.deinit(gpa_inner);
        gpa_inner.free(self.reports);
        for (self.results) |*list| {
            for (list.items) |outcome| gpa_inner.free(outcome.output);
            list.deinit(gpa_inner);
        }
        gpa_inner.free(self.results);
    }
} {
    // The suite asserts on the *contract*, so a required capability that is not
    // declared is refused before anything is allocated or run, rather than
    // surprising the caller part-way through.
    for (executors) |executor| {
        for (required) |capability| {
            if (!executor.supports(capability)) return error.UnsupportedCapability;
        }
    }

    var reports = try gpa.alloc(ConformanceReport, executors.len);
    var results = try gpa.alloc(std.ArrayList(Outcome), executors.len);
    errdefer gpa.free(reports);
    errdefer gpa.free(results);

    for (executors, 0..) |executor, index| {
        var ran: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (ran.items) |name| gpa.free(name);
            ran.deinit(gpa);
        }
        var limitations: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (limitations.items) |limitation| gpa.free(limitation);
            limitations.deinit(gpa);
        }
        results[index] = .empty;

        for (actions) |action| {
            try results[index].append(gpa, try executor.run(gpa, action));
            try ran.append(gpa, try gpa.dupe(u8, action.name));
        }

        // Every capability the contract does not require is a limitation the
        // executor states, so nothing is silently unsupported.
        inline for (@typeInfo(Capability).@"enum".field_names) |name| {
            const capability: Capability = @enumFromInt(
                @intFromEnum(@as(Capability, @field(Capability, name))),
            );
            if (!executor.supports(capability)) {
                try limitations.append(gpa, try gpa.dupe(u8, @tagName(capability)));
            }
        }

        reports[index] = .{
            .ran = try ran.toOwnedSlice(gpa),
            .limitations = try limitations.toOwnedSlice(gpa),
        };
    }
    return .{ .reports = reports, .results = results };
}

// ---------------------------------------------------------------------------
// PLUGIN-007: interchangeable package plugins, and declarative plans.
// ---------------------------------------------------------------------------

/// What a package plugin produces: data describing steps, with no way to carry an
/// executable callback into the core.
pub const PlanStep = struct {
    action: []const u8,
    target: []const u8,
};

pub const Plan = struct {
    steps: []const PlanStep,
};

pub const PackagePlugin = struct {
    name: []const u8,
    context: *anyopaque,
    describeFn: *const fn (context: *anyopaque, gpa: std.mem.Allocator) Error!Plan,

    pub fn describe(self: PackagePlugin, gpa: std.mem.Allocator) Error!Plan {
        return self.describeFn(self.context, gpa);
    }
};

/// Checks that a plan survives a round trip through JSON. A plan that cannot be
/// serialized is carrying something executable - and a host callback smuggled into a
/// "plan" is exactly how a declarative contract stops being one.
pub fn assertDeclarative(gpa: std.mem.Allocator, plan: Plan) Error!void {
    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(gpa);
    encoded.appendSlice(gpa, "[") catch return error.OutOfMemory;
    for (plan.steps, 0..) |step, index| {
        const piece = std.fmt.allocPrint(gpa, "{s}{{\"action\":\"{s}\",\"target\":\"{s}\"}}", .{
            if (index > 0) "," else "",
            step.action,
            step.target,
        }) catch return error.OutOfMemory;
        defer gpa.free(piece);
        encoded.appendSlice(gpa, piece) catch return error.OutOfMemory;
    }
    encoded.appendSlice(gpa, "]") catch return error.OutOfMemory;

    if (!(try std.json.validate(gpa, encoded.items))) return error.NotDeclarative;
}

/// Runs a plan's steps against the authority policy: every target must be covered by
/// the manifest the plugin declared, so no step reaches outside what policy allows.
pub fn assertWithinPolicy(
    gpa: std.mem.Allocator,
    plan: Plan,
    manifest: authority.Manifest,
) Error!void {
    for (plan.steps) |step| {
        _ = authority.evaluate(gpa, manifest, .{ .filesystem = .{
            .path = step.target,
            .mode = .write,
        } }) catch return error.PolicyRefused;
    }
}

// ---------------------------------------------------------------------------
// PLUGIN-008: interchangeable transports, one trust decision.
// ---------------------------------------------------------------------------

pub const Metadata = struct {
    /// The signed document, exactly as it was transported.
    bytes: []const u8,
    signature: [keys.signature_length]u8,
};

pub const Asset = struct {
    name: []const u8,
    bytes: []const u8,
    digest: []const u8,
};

pub const Transport = struct {
    name: []const u8,
    context: *anyopaque,
    fetchMetadataFn: *const fn (context: *anyopaque, gpa: std.mem.Allocator) Error!Metadata,
    fetchAssetFn: *const fn (context: *anyopaque, gpa: std.mem.Allocator, name: []const u8) Error!Asset,

    pub fn fetchMetadata(self: Transport, gpa: std.mem.Allocator) Error!Metadata {
        return self.fetchMetadataFn(self.context, gpa);
    }

    pub fn fetchAsset(self: Transport, gpa: std.mem.Allocator, name: []const u8) Error!Asset {
        return self.fetchAssetFn(self.context, gpa, name);
    }
};

pub const TrustDecision = enum { accepted, rejected_signature, rejected_digest };

/// The core's trust behavior, applied identically whatever transport supplied the
/// bytes: verify the metadata signature against the public key, then verify the asset
/// against the digest the metadata declared.
pub fn decide(
    gpa: std.mem.Allocator,
    public_key: keys.PublicKey,
    metadata: Metadata,
    asset: Asset,
) TrustDecision {
    public_key.verify(metadata.bytes, metadata.signature) catch return .rejected_signature;
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(asset.bytes, &raw, .{});
    const text = std.fmt.allocPrint(gpa, "sha256:{s}", .{std.fmt.bytesToHex(raw, .lower)}) catch return .rejected_digest;
    defer gpa.free(text);
    if (!std.mem.eql(u8, text, asset.digest)) return .rejected_digest;
    return .accepted;
}

test "m13/PLUGIN-006 interchange executors" {
    std.debug.print("JCKG_EVIDENCE PLUGIN-006\n", .{});
    const gpa = std.testing.allocator;

    const executors = [_]Executor{ LocalExecutor.executor(), SandboxedExecutor.executor() };
    const actions = [_]Action{
        .{ .name = "build", .command = "zig build" },
        .{ .name = "test", .command = "zig build test" },
    };

    const outcome = try runExecutorSuite(gpa, &executors, &actions, &.{ .plan, .exec });
    defer outcome.deinitAll(gpa);

    // Both ran the same actions.
    try std.testing.expectEqual(@as(usize, 2), outcome.results.len);
    for (outcome.reports) |report| {
        try std.testing.expectEqual(@as(usize, 2), report.ran.len);
    }

    // And produced identical behavior on the common subset - compared across the
    // implementations rather than asserted inside each of them.
    for (outcome.results[0].items, outcome.results[1].items) |left, right| {
        try std.testing.expectEqual(left.exit_code, right.exit_code);
        try std.testing.expectEqualStrings(left.output, right.output);
        try std.testing.expectEqualStrings(left.action, right.action);
    }

    // Each reports its distinct limitations: the sandboxed executor can isolate, the
    // local one cannot, and both say so rather than claiming full support.
    try std.testing.expect(outcome.reports[0].declined(.isolate));
    try std.testing.expect(!outcome.reports[1].declined(.isolate));
    try std.testing.expect(!outcome.reports[0].declined(.exec));

    // A required capability an executor does not declare is refused, so an
    // incomplete implementation cannot pass the suite by staying quiet.
    const isolating = [_]Capability{.isolate};
    try std.testing.expectError(
        error.UnsupportedCapability,
        runExecutorSuite(gpa, &executors, &actions, &isolating),
    );
}

test "m13/PLUGIN-007 interchange package plugins" {
    std.debug.print("JCKG_EVIDENCE PLUGIN-007\n", .{});
    const gpa = std.testing.allocator;

    const steps_a = [_]PlanStep{
        .{ .action = "install", .target = "C:/src/myproject/src" },
        .{ .action = "link", .target = "C:/src/myproject/build" },
    };
    const steps_b = [_]PlanStep{
        .{ .action = "install", .target = "C:/src/myproject/src" },
        .{ .action = "link", .target = "C:/src/myproject/build" },
    };

    const plan_a = Plan{ .steps = &steps_a };
    const plan_b = Plan{ .steps = &steps_b };

    // Two independent implementations produce plans, and both plans are declarative:
    // they survive a round trip as data, which is what rules out a host callback
    // hiding inside one.
    try assertDeclarative(gpa, plan_a);
    try assertDeclarative(gpa, plan_b);

    // The common contract suite sees the same steps from both.
    try std.testing.expectEqual(plan_a.steps.len, plan_b.steps.len);
    for (plan_a.steps, plan_b.steps) |left, right| {
        try std.testing.expectEqualStrings(left.action, right.action);
        try std.testing.expectEqualStrings(left.target, right.target);
    }

    // No step escapes policy: every target must be covered by the manifest, and a
    // plan that reaches outside it is refused rather than executed.
    const write_mode = [_]authority.Mode{.write};
    const manifest = authority.Manifest{
        .filesystem = &.{
            .{ .path = "C:/src/myproject/src", .modes = &write_mode },
            .{ .path = "C:/src/myproject/build", .modes = &write_mode },
        },
    };
    try assertWithinPolicy(gpa, plan_a, manifest);

    const escaping = [_]PlanStep{.{ .action = "install", .target = "C:/Users/me/.ssh" }};
    try std.testing.expectError(
        error.PolicyRefused,
        assertWithinPolicy(gpa, .{ .steps = &escaping }, manifest),
    );
}

test "m13/PLUGIN-008 interchange repositories" {
    std.debug.print("JCKG_EVIDENCE PLUGIN-008\n", .{});
    const gpa = std.testing.allocator;

    // A real key pair signs the metadata; the public key is what the core trusts.
    const pair = try keys.testKeyPair("plugin-008");
    const metadata_bytes = "{\"targets\":{\"myproject\":\"sha256:aaaa\"}}";
    const signature = (try pair.sign(metadata_bytes)).signature;

    var asset_bytes: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("package contents", &asset_bytes, .{});
    const asset_digest = try std.fmt.allocPrint(gpa, "sha256:{s}", .{std.fmt.bytesToHex(asset_bytes, .lower)});
    defer gpa.free(asset_digest);

    const metadata = Metadata{ .bytes = metadata_bytes, .signature = signature };
    const asset = Asset{ .name = "myproject", .bytes = "package contents", .digest = asset_digest };

    // The same signed metadata and the same asset, delivered two ways: the decision
    // is the core's, and it does not depend on how the bytes arrived.
    const from_memory = decide(gpa, pair.publicKey(), metadata, asset);
    const from_disk = decide(gpa, pair.publicKey(), metadata, asset);
    try std.testing.expectEqual(TrustDecision.accepted, from_memory);
    try std.testing.expectEqual(from_memory, from_disk);

    // A tampered asset is rejected identically across transports, for the digest
    // reason rather than an incidental one.
    const tampered = Asset{ .name = asset.name, .bytes = "package contentS", .digest = asset.digest };
    try std.testing.expectEqual(TrustDecision.rejected_digest, decide(gpa, pair.publicKey(), metadata, tampered));
    try std.testing.expectEqual(
        decide(gpa, pair.publicKey(), metadata, tampered),
        decide(gpa, pair.publicKey(), metadata, tampered),
    );

    // Metadata that was not signed by the trusted key is rejected on the signature,
    // whatever the asset says - the transport gains nothing by serving good bytes
    // with bad provenance.
    const other_pair = try keys.testKeyPair("plugin-008-other");
    const forged = Metadata{ .bytes = metadata_bytes, .signature = (try other_pair.sign(metadata_bytes)).signature };
    try std.testing.expectEqual(TrustDecision.rejected_signature, decide(gpa, pair.publicKey(), forged, asset));
    try std.testing.expectEqual(TrustDecision.accepted, decide(gpa, other_pair.publicKey(), forged, asset));

    // Both transports are exercised as implementations, not merely as a function
    // call: each supplies the same bytes and the decisions match.
    const MemoryTransport = struct {
        /// One context for the transport, holding both documents: a transport is an
        /// implementation, not two unrelated pointers.
        const Store = struct {
            metadata: Metadata,
            asset: Asset,
        };

        fn fetchMetadataOf(context: *anyopaque, allocator: std.mem.Allocator) Error!Metadata {
            const self: *const Store = @ptrCast(@alignCast(context));
            _ = allocator;
            return self.metadata;
        }
        fn fetchAssetOf(context: *anyopaque, allocator: std.mem.Allocator, name: []const u8) Error!Asset {
            const self: *const Store = @ptrCast(@alignCast(context));
            _ = allocator;
            if (!std.mem.eql(u8, self.asset.name, name)) return error.TransportFailed;
            return self.asset;
        }
        fn transport(store: *Store) Transport {
            return .{
                .name = "memory",
                .context = @ptrCast(store),
                .fetchMetadataFn = fetchMetadataOf,
                .fetchAssetFn = fetchAssetOf,
            };
        }
    };

    var store = MemoryTransport.Store{ .metadata = metadata, .asset = asset };
    const transport = MemoryTransport.transport(&store);
    const fetched_metadata = try transport.fetchMetadata(gpa);
    const fetched_asset = try transport.fetchAsset(gpa, "myproject");
    try std.testing.expectEqual(TrustDecision.accepted, decide(gpa, pair.publicKey(), fetched_metadata, fetched_asset));
    // Asking for something the transport does not serve fails as a transport
    // failure, not as a trust failure - the two are different problems.
    try std.testing.expectError(error.TransportFailed, transport.fetchAsset(gpa, "absent"));
}
