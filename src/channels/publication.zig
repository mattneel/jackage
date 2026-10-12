//! Planning a publication, and deciding whether anybody asked for it (M14, GH-007, GH-010).
//!
//! Publication is the one operation here that reaches outside the machine and is
//! hard to take back, so it has two properties that are checked rather than assumed:
//!
//! - **A dry run has no effects.** It validates the plan completely - names, digests,
//!   the metadata that will be activated - and touches nothing: no remote write, no
//!   use of the signing key. The test proves this by running the same plan for real
//!   afterwards and watching the counters move, so "zero" is measured against a
//!   baseline that is known to count rather than being vacuously zero.
//! - **Authorization is required and is specific.** With no grant the operation
//!   fails, and it fails *whatever else is true* - including when every test passed,
//!   which is exactly the state a build is in when somebody is tempted to let it
//!   publish itself. A grant names the channel it covers and the moment it expires,
//!   so a grant for a different channel or an expired one is refused as its own
//!   distinct reason rather than as a generic denial.
const std = @import("std");
const keys = @import("../trust/keys.zig");
const digest = @import("../core/digest.zig");

pub const Error = error{
    PublicationUnauthorized,
    GrantExpired,
    GrantChannelMismatch,
    InvalidPlan,
    UploadFailed,
    OutOfMemory,
};

pub const Asset = struct {
    name: []const u8,
    /// The digest text the channel's metadata will advertise for this asset.
    digest: []const u8,
    byte_length: u64,
};

pub const Plan = struct {
    channel: []const u8,
    assets: []const Asset,
    /// Whether the metadata activation step runs. A publication that uploads assets
    /// without activating metadata leaves the channel serving the previous version,
    /// which is the property GH-008 is about.
    activate_metadata: bool = true,
    /// Evidence that the local build is green. Carried deliberately: publication is
    /// not authorized by tests passing, and the field is here so that claim can be
    /// tested rather than asserted.
    all_tests_passed: bool = true,
};

pub const Grant = struct {
    /// The channel this grant authorizes.
    channel: []const u8,
    /// The moment the grant stops being valid, in Unix seconds.
    expires_at: i64,
    /// Who granted it, for the record.
    issuer: []const u8,
};

pub const Effects = struct {
    remote_writes: usize = 0,
    signing_uses: usize = 0,
};

/// The transport a publication would write through. It counts, so "no remote
/// mutation" is an observation rather than a promise.
pub const Transport = struct {
    context: *anyopaque,
    name: []const u8,
    effects: *Effects,
    writeFn: *const fn (context: *anyopaque, effects: *Effects, path: []const u8, bytes: []const u8) Error!void,

    pub fn write(self: Transport, path: []const u8, bytes: []const u8) Error!void {
        // The count happens here, at the one place a write can occur, so no caller can
        // perform one without it being visible.
        self.effects.remote_writes += 1;
        return self.writeFn(self.context, self.effects, path, bytes);
    }
};

/// The signing authority. Every use is counted, which is what makes "no signing
/// authority use occurs" checkable.
pub const Signer = struct {
    context: *anyopaque,
    pair: keys.KeyPair,
    effects: *Effects,

    pub fn sign(self: *const Signer, message: []const u8) Error!keys.SignatureEntry {
        self.effects.signing_uses += 1;
        return self.pair.sign(message) catch return error.UploadFailed;
    }
};

pub const Validation = struct {
    assets: usize,
    total_bytes: u64,
    /// The names that would be published, in order, so the operator reads the plan
    /// rather than a summary of it.
    names: []const []const u8,

    pub fn deinit(self: Validation, gpa: std.mem.Allocator) void {
        for (self.names) |name| gpa.free(name);
        gpa.free(self.names);
    }
};

fn validate(gpa: std.mem.Allocator, plan: Plan) Error!Validation {
    if (plan.channel.len == 0) return error.InvalidPlan;
    if (plan.assets.len == 0) return error.InvalidPlan;

    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |name| gpa.free(name);
        names.deinit(gpa);
    }
    var total: u64 = 0;
    for (plan.assets, 0..) |asset, index| {
        if (asset.name.len == 0) return error.InvalidPlan;
        _ = digest.Digest.parse(asset.digest) catch return error.InvalidPlan;
        // Two assets with one name would make the metadata ambiguous, and the last
        // write would win by accident rather than by decision.
        for (plan.assets[index + 1 ..]) |other| {
            if (std.mem.eql(u8, asset.name, other.name)) return error.InvalidPlan;
        }
        total += asset.byte_length;
        try names.append(gpa, try gpa.dupe(u8, asset.name));
    }
    return .{ .assets = plan.assets.len, .total_bytes = total, .names = try names.toOwnedSlice(gpa) };
}

/// Validates a plan without touching anything.
pub fn dryRun(gpa: std.mem.Allocator, plan: Plan, transport: Transport, signer: *const Signer) Error!Validation {
    const validation = try validate(gpa, plan);
    errdefer validation.deinit(gpa);

    // The plan is checked here, and the effects are not: the caller's counters must
    // still read zero after this returns, which is what the test measures. The
    // parameters are taken so a caller cannot reach a transport or signer through
    // some other path in this function by accident.
    _ = transport;
    _ = signer;
    return validation;
}

pub const Outcome = struct {
    uploaded: usize,
    metadata_activated: bool,
};

/// Publishes a plan, requiring an explicit and valid grant.
///
/// The grant comes first, before anything is validated: an unauthorized request is
/// refused without the operation having looked at the plan at all, so there is no
/// state in which a partial publication exists because the authorization arrived
/// after some work had begun.
pub fn publish(
    gpa: std.mem.Allocator,
    plan: Plan,
    grant: ?Grant,
    now: i64,
    transport: Transport,
    signer: *const Signer,
) Error!Outcome {
    const authorization = grant orelse return error.PublicationUnauthorized;
    if (!std.mem.eql(u8, authorization.channel, plan.channel)) return error.GrantChannelMismatch;
    if (authorization.expires_at <= now) return error.GrantExpired;

    const validation = try validate(gpa, plan);
    defer validation.deinit(gpa);

    var uploaded: usize = 0;
    for (plan.assets) |asset| {
        try transport.write(asset.name, asset.digest);
        uploaded += 1;
    }
    if (plan.activate_metadata) {
        // Metadata activation is what makes the uploads visible, and it is signed, so
        // this is the one place the signing authority is used.
        const entry = try signer.sign(plan.channel);
        _ = entry;
    }
    return .{ .uploaded = uploaded, .metadata_activated = plan.activate_metadata };
}

test "m14/GH-007 dry-run publication, m14/GH-010 reject unauthorized publication" {
    std.debug.print("JCKG_EVIDENCE GH-007\n", .{});
    std.debug.print("JCKG_EVIDENCE GH-010\n", .{});
    const gpa = std.testing.allocator;

    const pair = try keys.testKeyPair("gh-007");
    var effects = Effects{};
    var signer = Signer{ .context = undefined, .pair = pair, .effects = &effects };

    const Sink = struct {
        /// A real transport writes somewhere; this one records what it was asked to
        /// write so the test can also check the plan's assets arrived in order.
        gpa: std.mem.Allocator,
        written: std.ArrayList([]const u8) = .empty,

        fn writeOf(context: *anyopaque, counters: *Effects, path: []const u8, bytes: []const u8) Error!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            _ = counters;
            _ = bytes;
            const copy = try self.gpa.dupe(u8, path);
            errdefer self.gpa.free(copy);
            try self.written.append(self.gpa, copy);
        }
    };
    var sink = Sink{ .gpa = gpa };
    defer {
        for (sink.written.items) |path| gpa.free(path);
        sink.written.deinit(gpa);
    }
    const transport = Transport{
        .context = &sink,
        .name = "fixture",
        .effects = &effects,
        .writeFn = Sink.writeOf,
    };

    const asset_digest = "sha256:1111111111111111111111111111111111111111111111111111111111111111";
    const assets = [_]Asset{
        .{ .name = "jckg-x86_64-windows.zip", .digest = asset_digest, .byte_length = 4096 },
        .{ .name = "jckg-x86_64-linux.tar.gz", .digest = asset_digest, .byte_length = 2048 },
    };
    const plan = Plan{ .channel = "stable", .assets = &assets };

    // Dry run: the plan validates completely, and nothing is touched.
    const validation = try dryRun(gpa, plan, transport, &signer);
    defer validation.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), validation.assets);
    try std.testing.expectEqual(@as(u64, 6144), validation.total_bytes);
    try std.testing.expectEqualStrings("jckg-x86_64-windows.zip", validation.names[0]);
    try std.testing.expectEqual(@as(usize, 0), effects.remote_writes);
    try std.testing.expectEqual(@as(usize, 0), effects.signing_uses);

    // The counters are not vacuously zero: the same plan, authorized, moves both. So
    // the zero above measured something real.
    const grant = Grant{ .channel = "stable", .expires_at = 2_000_000_000, .issuer = "user" };
    const published = try publish(gpa, plan, grant, 1_000_000_000, transport, &signer);
    try std.testing.expectEqual(@as(usize, 2), published.uploaded);
    try std.testing.expect(published.metadata_activated);
    try std.testing.expectEqual(@as(usize, 2), effects.remote_writes);
    try std.testing.expectEqual(@as(usize, 1), effects.signing_uses);
    try std.testing.expectEqual(@as(usize, 2), sink.written.items.len);
    try std.testing.expectEqualStrings(assets[0].name, sink.written.items[0]);

    // With no grant, publication fails - and it fails while every test passes, which
    // is exactly the state a build is in when it tries to publish itself.
    const green_plan = Plan{ .channel = "stable", .assets = &assets, .all_tests_passed = true };
    try std.testing.expectError(error.PublicationUnauthorized, publish(gpa, green_plan, null, 1_000_000_000, transport, &signer));

    // A grant for another channel is refused as its own reason.
    const other_grant = Grant{ .channel = "nightly", .expires_at = 2_000_000_000, .issuer = "user" };
    try std.testing.expectError(error.GrantChannelMismatch, publish(gpa, plan, other_grant, 1_000_000_000, transport, &signer));

    // An expired grant is refused too, and the boundary is inclusive: at the expiry
    // second the grant is over.
    const expiring = Grant{ .channel = "stable", .expires_at = 1_000_000_000, .issuer = "user" };
    try std.testing.expectError(error.GrantExpired, publish(gpa, plan, expiring, 1_000_000_000, transport, &signer));

    // Every refusal above happened without any effect at all: the authorization is
    // checked before the plan is even validated, so there is no partial publication
    // to clean up.
    try std.testing.expectEqual(@as(usize, 2), effects.remote_writes);
    try std.testing.expectEqual(@as(usize, 1), effects.signing_uses);
    try std.testing.expectEqual(@as(usize, 2), sink.written.items.len);
    try std.testing.expectEqualStrings(assets[0].name, sink.written.items[0]);

    // A malformed plan is refused by the dry run as well, with the same reasons a
    // real publication would give - which is the point of validating it there.
    const duplicate_assets = [_]Asset{
        .{ .name = "same.zip", .digest = asset_digest, .byte_length = 1 },
        .{ .name = "same.zip", .digest = asset_digest, .byte_length = 2 },
    };
    try std.testing.expectError(error.InvalidPlan, dryRun(gpa, .{ .channel = "stable", .assets = &duplicate_assets }, transport, &signer));
    const bad_digest = [_]Asset{.{ .name = "x.zip", .digest = "not-a-digest", .byte_length = 1 }};
    try std.testing.expectError(error.InvalidPlan, dryRun(gpa, .{ .channel = "stable", .assets = &bad_digest }, transport, &signer));
    try std.testing.expectError(error.InvalidPlan, dryRun(gpa, .{ .channel = "", .assets = &assets }, transport, &signer));
    try std.testing.expectError(error.InvalidPlan, dryRun(gpa, .{ .channel = "stable", .assets = &.{} }, transport, &signer));

    // A dry run of an invalid plan left the counters alone as well.
    try std.testing.expectEqual(@as(usize, 2), effects.remote_writes);
}
