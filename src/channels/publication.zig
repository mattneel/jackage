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
    ConflictingPublication,
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
    /// Metadata activations. This is the step that makes uploads visible, and it is
    /// counted apart from the writes so a publication that uploads and never
    /// activates - the state GH-008 is about - is distinguishable from one that did.
    metadata_activations: usize = 0,
};

/// The transport a publication would write through. It counts, so "no remote
/// mutation" is an observation rather than a promise.
pub const Transport = struct {
    context: *anyopaque,
    name: []const u8,
    effects: *Effects,
    writeFn: *const fn (context: *anyopaque, effects: *Effects, path: []const u8, bytes: []const u8) Error!void,
    /// Publishes the metadata document that makes this channel's assets visible. Kept
    /// as its own step because activation is what turns a set of uploads into a
    /// version, and doing it late is the whole of GH-008.
    activateFn: *const fn (context: *anyopaque, effects: *Effects, path: []const u8, bytes: []const u8) Error!void,

    pub fn write(self: Transport, path: []const u8, bytes: []const u8) Error!void {
        // The count happens here, at the one place a write can occur, so no caller can
        // perform one without it being visible.
        self.effects.remote_writes += 1;
        return self.writeFn(self.context, self.effects, path, bytes);
    }

    pub fn activate(self: Transport, path: []const u8, bytes: []const u8) Error!void {
        self.effects.metadata_activations += 1;
        return self.activateFn(self.context, self.effects, path, bytes);
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
        // An upload that fails returns here, before the signature and before the
        // activation: the channel keeps serving whatever it served before, and none of
        // the uploads are visible. That is the property GH-008 measures.
        try transport.write(asset.name, asset.digest);
        uploaded += 1;
    }
    if (plan.activate_metadata) {
        // Activation is signed, so this is the one place the signing authority is
        // used, and it happens after every upload has succeeded.
        const entry = try signer.sign(plan.channel);
        _ = entry;
        try transport.activate("metadata.json", plan.channel);
    }
    return .{ .uploaded = uploaded, .metadata_activated = plan.activate_metadata };
}

/// What a channel already holds from an interrupted publication: asset name to the
/// digest that was uploaded.
pub const PublicationState = struct {
    assets: []const Asset,
    metadata_activated: bool,

    pub fn digestOf(self: PublicationState, name: []const u8) ?[]const u8 {
        for (self.assets) |asset| {
            if (std.mem.eql(u8, asset.name, name)) return asset.digest;
        }
        return null;
    }
};

pub const RetryPlan = struct {
    /// Assets already present with the identical digest: re-uploading them would be
    /// wasted work, and skipping them is what makes a retry safe to repeat.
    present: []const []const u8,
    /// Assets the publication still needs.
    missing: []const []const u8,

    pub fn deinit(self: RetryPlan, gpa: std.mem.Allocator) void {
        for (self.present) |name| gpa.free(name);
        gpa.free(self.present);
        for (self.missing) |name| gpa.free(name);
        gpa.free(self.missing);
    }
};

/// Plans the remainder of an interrupted publication.
///
/// An asset already present with the *same* digest is skipped: an identical upload is
/// the same bytes under the same name, so repeating it cannot produce a different
/// channel state, and skipping it is what makes the retry idempotent. An asset present
/// with a *different* digest is refused rather than overwritten - that is not a retry,
/// it is a conflicting publication wearing the same name.
pub fn planRetry(gpa: std.mem.Allocator, plan: Plan, state: PublicationState) Error!RetryPlan {
    var present: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (present.items) |name| gpa.free(name);
        present.deinit(gpa);
    }
    var missing: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (missing.items) |name| gpa.free(name);
        missing.deinit(gpa);
    }

    for (plan.assets) |asset| {
        if (state.digestOf(asset.name)) |existing| {
            if (!std.mem.eql(u8, existing, asset.digest)) return error.ConflictingPublication;
            try present.append(gpa, try gpa.dupe(u8, asset.name));
            continue;
        }
        try missing.append(gpa, try gpa.dupe(u8, asset.name));
    }
    return .{ .present = try present.toOwnedSlice(gpa), .missing = try missing.toOwnedSlice(gpa) };
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
        activated: std.ArrayList([]const u8) = .empty,

        fn writeOf(context: *anyopaque, counters: *Effects, path: []const u8, bytes: []const u8) Error!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            _ = counters;
            _ = bytes;
            const copy = try self.gpa.dupe(u8, path);
            errdefer self.gpa.free(copy);
            try self.written.append(self.gpa, copy);
        }

        fn activateOf(context: *anyopaque, counters: *Effects, path: []const u8, bytes: []const u8) Error!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            _ = counters;
            _ = bytes;
            const copy = try self.gpa.dupe(u8, path);
            errdefer self.gpa.free(copy);
            try self.activated.append(self.gpa, copy);
        }
    };
    var sink = Sink{ .gpa = gpa };
    defer {
        for (sink.written.items) |path| gpa.free(path);
        sink.written.deinit(gpa);
        for (sink.activated.items) |path| gpa.free(path);
        sink.activated.deinit(gpa);
    }
    const transport = Transport{
        .context = &sink,
        .name = "fixture",
        .effects = &effects,
        .writeFn = Sink.writeOf,
        .activateFn = Sink.activateOf,
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
    // Activation is its own step and happened exactly once, after both uploads.
    try std.testing.expectEqual(@as(usize, 1), sink.activated.items.len);
    try std.testing.expectEqual(@as(usize, 1), effects.metadata_activations);

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
    // Activation is its own step and happened exactly once, after both uploads.
    try std.testing.expectEqual(@as(usize, 1), sink.activated.items.len);
    try std.testing.expectEqual(@as(usize, 1), effects.metadata_activations);

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

test "m14/GH-008 publish transactionally, m14/GH-009 retry publication safely" {
    std.debug.print("JCKG_EVIDENCE GH-008\n", .{});
    std.debug.print("JCKG_EVIDENCE GH-009\n", .{});
    const gpa = std.testing.allocator;

    const pair = try keys.testKeyPair("gh-008");
    var effects = Effects{};
    var signer = Signer{ .context = undefined, .pair = pair, .effects = &effects };

    // A fixture channel: assets that were uploaded, and the metadata document that
    // is visible to consumers. Activation replaces the visible document, which is
    // why it is the step that matters.
    const Fixture = struct {
        gpa: std.mem.Allocator,
        uploaded: std.ArrayList(Asset) = .empty,
        visible: ?[]u8 = null,
        /// The asset name whose upload fails, if any.
        fail_on: ?[]const u8 = null,

        fn writeOf(context: *anyopaque, counters: *Effects, path: []const u8, bytes: []const u8) Error!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            _ = counters;
            if (self.fail_on) |failing| {
                if (std.mem.eql(u8, failing, path)) return error.UploadFailed;
            }
            const name = try self.gpa.dupe(u8, path);
            errdefer self.gpa.free(name);
            const value = try self.gpa.dupe(u8, bytes);
            errdefer self.gpa.free(value);
            try self.uploaded.append(self.gpa, .{ .name = name, .digest = value, .byte_length = 0 });
        }

        fn activateOf(context: *anyopaque, counters: *Effects, path: []const u8, bytes: []const u8) Error!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            _ = counters;
            _ = path;
            if (self.visible) |old| self.gpa.free(old);
            self.visible = try self.gpa.dupe(u8, bytes);
        }

        fn deinit(self: *@This()) void {
            for (self.uploaded.items) |asset| {
                self.gpa.free(asset.name);
                self.gpa.free(asset.digest);
            }
            self.uploaded.deinit(self.gpa);
            if (self.visible) |visible| self.gpa.free(visible);
        }

        fn state(self: *@This()) PublicationState {
            return .{ .assets = self.uploaded.items, .metadata_activated = self.visible != null };
        }
    };

    const digest_a = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const digest_b = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const digest_c = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    const assets = [_]Asset{
        .{ .name = "one.zip", .digest = digest_a, .byte_length = 10 },
        .{ .name = "two.zip", .digest = digest_b, .byte_length = 20 },
        .{ .name = "three.zip", .digest = digest_c, .byte_length = 30 },
    };
    const plan = Plan{ .channel = "stable", .assets = &assets };
    const grant = Grant{ .channel = "stable", .expires_at = 2_000_000_000, .issuer = "user" };

    // The channel as a consumer sees it before anything happens.
    var fixture = Fixture{ .gpa = gpa, .visible = try gpa.dupe(u8, "previous-v1") };
    defer fixture.deinit();
    const transport = Transport{
        .context = &fixture,
        .name = "fixture",
        .effects = &effects,
        .writeFn = Fixture.writeOf,
        .activateFn = Fixture.activateOf,
    };

    // GH-008: an upload fails partway through. The visible metadata is untouched -
    // byte-identical to what it was - and nothing advertises the two assets that did
    // land, because activation never ran.
    fixture.fail_on = "two.zip";
    try std.testing.expectError(error.UploadFailed, publish(gpa, plan, grant, 1_000_000_000, transport, &signer));
    try std.testing.expectEqualStrings("previous-v1", fixture.visible.?);
    try std.testing.expectEqual(@as(usize, 0), effects.metadata_activations);
    // One upload succeeded before the failure; it is present but invisible, which is
    // exactly the state a retry has to reconcile.
    try std.testing.expectEqual(@as(usize, 1), fixture.uploaded.items.len);
    try std.testing.expectEqualStrings("one.zip", fixture.uploaded.items[0].name);

    // GH-009: the retry plans against what is there. The identical asset is skipped,
    // the rest are missing, and nothing conflicts.
    const retry_plan = try planRetry(gpa, plan, fixture.state());
    defer retry_plan.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), retry_plan.present.len);
    try std.testing.expectEqualStrings("one.zip", retry_plan.present[0]);
    try std.testing.expectEqual(@as(usize, 2), retry_plan.missing.len);
    try std.testing.expectEqualStrings("two.zip", retry_plan.missing[0]);
    try std.testing.expectEqualStrings("three.zip", retry_plan.missing[1]);

    // The retry publishes only what is missing, and completes: the channel ends in
    // the state a single successful publication would have produced, with each asset
    // uploaded once.
    const remaining = [_]Asset{ assets[1], assets[2] };
    fixture.fail_on = null;
    const remainder = try publish(gpa, .{ .channel = "stable", .assets = &remaining }, grant, 1_000_000_000, transport, &signer);
    try std.testing.expectEqual(@as(usize, 2), remainder.uploaded);
    try std.testing.expect(fixture.visible != null);
    try std.testing.expectEqual(@as(usize, 3), fixture.uploaded.items.len);
    for (assets) |asset| {
        try std.testing.expect(fixture.state().digestOf(asset.name) != null);
    }

    // A conflicting publication - the same name with different bytes - is refused
    // rather than overwritten. That is not a retry, and treating it as one would
    // replace a published artifact with different content under the same name.
    const conflicting = [_]Asset{.{ .name = "one.zip", .digest = digest_b, .byte_length = 10 }};
    try std.testing.expectError(
        error.ConflictingPublication,
        planRetry(gpa, .{ .channel = "stable", .assets = &conflicting }, fixture.state()),
    );

    // A retry against a fully published channel needs nothing at all, which is what
    // makes repeating it harmless.
    const nothing = try planRetry(gpa, plan, fixture.state());
    defer nothing.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), nothing.present.len);
    try std.testing.expectEqual(@as(usize, 0), nothing.missing.len);
}
