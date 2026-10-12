//! Root metadata, explicit trust enrollment, and safe rotation
//! (cases TRUST-001, TRUST-007).
//!
//! A channel never authorizes itself. The first enrollment requires a
//! fingerprint approved independently of the channel that delivered the
//! document, and a rotation requires authorization from *both* the current root
//! and the next root at their respective thresholds, with a strictly increasing
//! version. Nothing here derives trust from transport (HTTPS or a checksum from
//! the same source), and no partial rotation is ever accepted.
const std = @import("std");
const canonical = @import("../core/canonical.zig");
const keys = @import("keys.zig");

pub const Error = error{
    NotEnrolled,
    FingerprintNotApproved,
    InvalidRootMetadata,
    InvalidThreshold,
    InvalidTimestamp,
    Expired,
    RollbackDetected,
    RotationNotAuthorized,
};

pub const timestamp_length = 20; // "YYYY-MM-DDTHH:MM:SSZ"

/// Canonical UTC timestamp used for expiry comparisons. The format is fixed, so
/// byte order equals chronological order; a malformed value is refused instead
/// of being compared.
pub fn validTimestamp(text_value: []const u8) bool {
    if (text_value.len != timestamp_length) return false;
    const digits = [_]struct { index: usize, from: u8, to: u8 }{
        .{ .index = 0, .from = '0', .to = '9' },
        .{ .index = 1, .from = '0', .to = '9' },
        .{ .index = 2, .from = '0', .to = '9' },
        .{ .index = 3, .from = '0', .to = '9' },
        .{ .index = 5, .from = '0', .to = '9' },
        .{ .index = 6, .from = '0', .to = '9' },
        .{ .index = 8, .from = '0', .to = '9' },
        .{ .index = 9, .from = '0', .to = '9' },
        .{ .index = 11, .from = '0', .to = '9' },
        .{ .index = 12, .from = '0', .to = '9' },
        .{ .index = 14, .from = '0', .to = '9' },
        .{ .index = 15, .from = '0', .to = '9' },
        .{ .index = 17, .from = '0', .to = '9' },
        .{ .index = 18, .from = '0', .to = '9' },
    };
    for (digits) |check| {
        const byte = text_value[check.index];
        if (byte < check.from or byte > check.to) return false;
    }
    if (text_value[4] != '-' or text_value[7] != '-' or text_value[10] != 'T' or text_value[13] != ':' or
        text_value[16] != ':' or text_value[19] != 'Z')
    {
        return false;
    }
    // Month, day, hour, minute, second sanity: enough to reject nonsense
    // without claiming calendar arithmetic.
    const month = std.fmt.parseInt(u8, text_value[5..7], 10) catch return false;
    const day = std.fmt.parseInt(u8, text_value[8..10], 10) catch return false;
    const hour = std.fmt.parseInt(u8, text_value[11..13], 10) catch return false;
    const minute = std.fmt.parseInt(u8, text_value[14..16], 10) catch return false;
    const second = std.fmt.parseInt(u8, text_value[17..19], 10) catch return false;
    if (month < 1 or month > 12) return false;
    if (day < 1 or day > 31) return false;
    if (hour > 23 or minute > 59 or second > 60) return false;
    return true;
}

pub fn expiredAt(expires: []const u8, now: []const u8) Error!bool {
    if (!validTimestamp(expires) or !validTimestamp(now)) return error.InvalidTimestamp;
    return std.mem.order(u8, expires, now) != .gt;
}

/// Formats a Unix timestamp as the canonical UTC stamp this module validates.
///
/// A verifier needs its *own* clock: accepting the peer's opinion of the time
/// would make expiry worthless. This is the civil-date conversion, done here so
/// the format and the parser cannot drift apart.
pub fn formatTimestamp(gpa: std.mem.Allocator, seconds: i64) std.mem.Allocator.Error![]u8 {
    var days = @divFloor(seconds, 86_400);
    var seconds_of_day = seconds - days * 86_400;
    if (seconds_of_day < 0) {
        seconds_of_day += 86_400;
        days -= 1;
    }
    const hour: u32 = @intCast(@divFloor(seconds_of_day, 3600));
    const minute: u32 = @intCast(@divFloor(seconds_of_day - @as(i64, hour) * 3600, 60));
    const second: u32 = @intCast(seconds_of_day - @as(i64, hour) * 3600 - @as(i64, minute) * 60);

    // Days since 1970-01-01 to a civil date (Howard Hinnant's algorithm).
    const shifted = days + 719_468;
    const era = @divFloor(shifted, 146_097);
    const day_of_era = shifted - era * 146_097;
    const year_of_era = @divFloor(day_of_era - @divFloor(day_of_era, 1460) + @divFloor(day_of_era, 36_524) - @divFloor(day_of_era, 146_096), 365);
    var year = year_of_era + era * 400;
    const day_of_year = day_of_era - (365 * year_of_era + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100));
    const month_prime = @divFloor(5 * day_of_year + 2, 153);
    const day: u32 = @intCast(day_of_year - @divFloor(153 * month_prime + 2, 5) + 1);
    const month: u32 = @intCast(if (month_prime < 10) month_prime + 3 else month_prime - 9);
    if (month <= 2) year += 1;

    return std.fmt.allocPrint(gpa, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        @as(u64, @intCast(year)),
        month,
        day,
        hour,
        minute,
        second,
    });
}

test "timestamp formatter round-trips through the validator" {
    const gpa = std.testing.allocator;

    // Epoch, leap day, a modern date, and a time-of-day edge.
    const cases = [_]struct { seconds: i64, expected: []const u8 }{
        .{ .seconds = 0, .expected = "1970-01-01T00:00:00Z" },
        .{ .seconds = 951_782_400, .expected = "2000-02-29T00:00:00Z" },
        .{ .seconds = 1_767_225_599, .expected = "2025-12-31T23:59:59Z" },
        .{ .seconds = 86_399, .expected = "1970-01-01T23:59:59Z" },
    };
    for (cases) |case| {
        const text = try formatTimestamp(gpa, case.seconds);
        defer gpa.free(text);
        try std.testing.expectEqualStrings(case.expected, text);
        try std.testing.expect(validTimestamp(text));
    }

    // The formatter's output is comparable with the parser's expectations: a
    // token that expires an hour from `now` is not expired, and one that
    // expired an hour ago is.
    const now = try formatTimestamp(gpa, 1_700_000_000);
    defer gpa.free(now);
    const later = try formatTimestamp(gpa, 1_700_003_600);
    defer gpa.free(later);
    const earlier = try formatTimestamp(gpa, 1_699_996_400);
    defer gpa.free(earlier);
    try std.testing.expect(!try expiredAt(later, now));
    try std.testing.expect(try expiredAt(earlier, now));
}

pub const RoleDefinition = struct {
    role: keys.Role,
    key_ids: []const keys.KeyId,
    threshold: usize,
};

pub const RootMetadata = struct {
    version: u64,
    expires: []const u8,
    roles: []RoleDefinition,
    /// Whether the repository promises consistent snapshots. Recorded in the
    /// document so a mixed snapshot is later detectable.
    consistent_snapshot: bool = true,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *RootMetadata) void {
        self.gpa.free(self.expires);
        for (self.roles) |definition| {
            self.gpa.free(definition.key_ids);
        }
        self.gpa.free(self.roles);
        self.* = undefined;
    }

    pub fn definitionFor(self: RootMetadata, role: keys.Role) ?RoleDefinition {
        for (self.roles) |definition| {
            if (definition.role == role) return definition;
        }
        return null;
    }

    pub fn toCanonical(self: RootMetadata, gpa: std.mem.Allocator) std.mem.Allocator.Error!canonical.Value {
        const role_values = try gpa.alloc(canonical.Value, self.roles.len);
        for (self.roles, 0..) |definition, index| {
            const key_values = try gpa.alloc(canonical.Value, definition.key_ids.len);
            for (definition.key_ids, 0..) |id, key_index| {
                var buffer: [keys.key_id_length * 2]u8 = undefined;
                key_values[key_index] = .{ .string = try gpa.dupe(u8, keys.keyIdText(id, &buffer)) };
            }
            const fields = try gpa.alloc(canonical.Entry, 3);
            fields[0] = .{ .key = try gpa.dupe(u8, "keyIds"), .value = .{ .array = key_values } };
            fields[1] = .{ .key = try gpa.dupe(u8, "role"), .value = .{ .string = try gpa.dupe(u8, definition.role.text()) } };
            fields[2] = .{ .key = try gpa.dupe(u8, "threshold"), .value = .{ .integer = @intCast(definition.threshold) } };
            role_values[index] = .{ .object = fields };
        }

        const fields = try gpa.alloc(canonical.Entry, 4);
        fields[0] = .{ .key = try gpa.dupe(u8, "consistentSnapshot"), .value = .{ .boolean = self.consistent_snapshot } };
        fields[1] = .{ .key = try gpa.dupe(u8, "expires"), .value = .{ .string = try gpa.dupe(u8, self.expires) } };
        fields[2] = .{ .key = try gpa.dupe(u8, "roles"), .value = .{ .array = role_values } };
        fields[3] = .{ .key = try gpa.dupe(u8, "version"), .value = .{ .integer = @intCast(self.version) } };
        var document = canonical.Value{ .object = fields };
        canonical.canonicalize(&document);
        return document;
    }

    pub fn encode(self: RootMetadata, gpa: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        const value = try self.toCanonical(gpa);
        defer value.deinit(gpa);
        return canonical.encodeAlloc(gpa, value);
    }

    /// The fingerprint an operator approves out of band: the digest of the
    /// canonical document, so any field change is a different root.
    pub fn fingerprint(self: RootMetadata, gpa: std.mem.Allocator) std.mem.Allocator.Error!keys.KeyId {
        const encoded = try self.encode(gpa);
        defer gpa.free(encoded);
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update("jckg:root:v1\x00");
        hasher.update(encoded);
        var digest: keys.KeyId = undefined;
        hasher.final(&digest);
        return digest;
    }
};

pub const Enrollment = struct {
    repository_identity: []const u8,
    fingerprint: keys.KeyId,
    root: RootMetadata,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Enrollment) void {
        self.gpa.free(self.repository_identity);
        self.root.deinit();
        self.* = undefined;
    }
};

/// Every operation that needs enrolled trust goes through this: with no
/// enrollment there is no trust, regardless of how the metadata arrived.
pub fn requireEnrollment(state: ?Enrollment) Error!Enrollment {
    return state orelse error.NotEnrolled;
}

/// First enrollment. `approved_fingerprint` is the value the operator obtained
/// independently of the channel; a document whose fingerprint differs is
/// refused even when the channel presents a matching checksum.
pub fn enroll(
    gpa: std.mem.Allocator,
    repository_identity: []const u8,
    root: RootMetadata,
    approved_fingerprint: keys.KeyId,
    verified_at: []const u8,
) !Enrollment {
    const actual = try root.fingerprint(gpa);
    if (!std.mem.eql(u8, &actual, &approved_fingerprint)) return error.FingerprintNotApproved;
    if (!validTimestamp(root.expires)) return error.InvalidRootMetadata;
    if (try expiredAt(root.expires, verified_at)) return error.Expired;
    const definition = root.definitionFor(.root) orelse return error.InvalidRootMetadata;
    if (definition.threshold == 0 or definition.threshold > definition.key_ids.len) return error.InvalidThreshold;

    for (root.roles) |role_definition| {
        if (role_definition.threshold == 0 or role_definition.threshold > role_definition.key_ids.len) {
            return error.InvalidThreshold;
        }
    }

    return .{
        .repository_identity = try gpa.dupe(u8, repository_identity),
        .fingerprint = actual,
        .root = root,
        .gpa = gpa,
    };
}

/// Rotation authorized by the old root at its threshold *and* by the new root
/// at its threshold. An interrupted or half-authorized rotation is refused, and
/// the input enrollment is left untouched.
pub fn rotate(
    gpa: std.mem.Allocator,
    current: Enrollment,
    next: RootMetadata,
    old_ring: keys.KeyRing,
    new_ring: keys.KeyRing,
    old_signatures: []const keys.SignatureEntry,
    new_signatures: []const keys.SignatureEntry,
    verified_at: []const u8,
) !Enrollment {
    if (next.version <= current.root.version) return error.RollbackDetected;
    if (!validTimestamp(next.expires)) return error.InvalidRootMetadata;
    if (try expiredAt(next.expires, verified_at)) return error.Expired;

    const old_definition = current.root.definitionFor(.root) orelse return error.InvalidRootMetadata;
    const new_definition = next.definitionFor(.root) orelse return error.InvalidRootMetadata;

    // The next root authorizes itself first: the canonical bytes of the *new*
    // document are what both sides sign.
    const next_encoded = try next.encode(gpa);
    defer gpa.free(next_encoded);
    if (!validTimestamp(current.root.expires)) return error.InvalidRootMetadata;

    keys.KeyRing.verifyThreshold(new_ring, .root, new_definition.threshold, next_encoded, new_signatures) catch
        return error.RotationNotAuthorized;

    // Then the current root authorizes the change; the same payload is signed,
    // so a rotation cannot be replayed for a different next root.
    keys.KeyRing.verifyThreshold(old_ring, .root, old_definition.threshold, next_encoded, old_signatures) catch
        return error.RotationNotAuthorized;

    const fingerprint_value = try next.fingerprint(gpa);
    return .{
        .repository_identity = try gpa.dupe(u8, current.repository_identity),
        .fingerprint = fingerprint_value,
        .root = next,
        .gpa = gpa,
    };
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

pub const fixture_now = "2026-10-12T00:00:00Z";
pub const fixture_expiry = "2027-01-01T00:00:00Z";
pub const fixture_past = "2026-01-01T00:00:00Z";

fn roleDefinition(gpa: std.mem.Allocator, role: keys.Role, ids: []const keys.KeyId, threshold: usize) !RoleDefinition {
    const copied = try gpa.alloc(keys.KeyId, ids.len);
    @memcpy(copied, ids);
    return .{ .role = role, .key_ids = copied, .threshold = threshold };
}

pub fn fixtureRoot(
    gpa: std.mem.Allocator,
    version: u64,
    expires: []const u8,
    root_keys: []const keys.KeyId,
    targets_keys: []const keys.KeyId,
) !RootMetadata {
    const roles = try gpa.alloc(RoleDefinition, 2);
    roles[0] = try roleDefinition(gpa, .root, root_keys, root_keys.len);
    roles[1] = try roleDefinition(gpa, .targets, targets_keys, 1);
    return .{
        .version = version,
        .expires = try gpa.dupe(u8, expires),
        .roles = roles,
        .consistent_snapshot = true,
        .gpa = gpa,
    };
}

test "m07/TRUST-001 require root enrollment" {
    std.debug.print("JCKG_EVIDENCE TRUST-001\n", .{});
    const gpa = std.testing.allocator;

    const root_pair = try keys.testKeyPair("root-a");
    const root_id = root_pair.publicKey().id();
    const targets_pair = try keys.testKeyPair("targets-a");
    const targets_id = targets_pair.publicKey().id();

    var root = try fixtureRoot(gpa, 1, fixture_expiry, &.{root_id}, &.{targets_id});
    const fingerprint_value = try root.fingerprint(gpa);

    // No enrollment means no trust, however the metadata arrived.
    try std.testing.expectError(error.NotEnrolled, requireEnrollment(null));

    // The operator approves a fingerprint out of band; matching it enrolls.
    var enrolled = try enroll(gpa, "example.invalid/acme", root, fingerprint_value, fixture_now);
    defer enrolled.deinit();
    try std.testing.expectEqualStrings("example.invalid/acme", enrolled.repository_identity);
    const reacquired = try requireEnrollment(enrolled);
    try std.testing.expectEqualSlices(u8, &fingerprint_value, &reacquired.fingerprint);

    // A channel-presented document whose fingerprint the operator did not
    // approve is refused, even if the channel also supplied a matching
    // checksum: authenticity does not come from the transport.
    var other_root = try fixtureRoot(gpa, 1, fixture_expiry, &.{targets_id}, &.{targets_id});
    defer other_root.deinit();
    const channel_claimed = try other_root.fingerprint(gpa);
    try std.testing.expectError(
        error.FingerprintNotApproved,
        enroll(gpa, "example.invalid/acme", other_root, fingerprint_value, fixture_now),
    );
    // ... and approving the channel's own claim does not help either, because
    // the operator's approved value is a different one.
    try std.testing.expectError(
        error.FingerprintNotApproved,
        enroll(gpa, "example.invalid/acme", root, channel_claimed, fixture_now),
    );

    // An expired root cannot be enrolled, and a malformed expiry is refused
    // rather than compared.
    var expired = try fixtureRoot(gpa, 1, fixture_past, &.{root_id}, &.{targets_id});
    defer expired.deinit();
    const expired_fingerprint = try expired.fingerprint(gpa);
    try std.testing.expectError(
        error.Expired,
        enroll(gpa, "example.invalid/acme", expired, expired_fingerprint, fixture_now),
    );
    var malformed = try fixtureRoot(gpa, 1, "soon", &.{root_id}, &.{targets_id});
    defer malformed.deinit();
    const malformed_fingerprint = try malformed.fingerprint(gpa);
    try std.testing.expectError(
        error.InvalidRootMetadata,
        enroll(gpa, "example.invalid/acme", malformed, malformed_fingerprint, fixture_now),
    );

    // A root whose threshold exceeds its key count is not a valid root.
    var impossible = try fixtureRoot(gpa, 1, fixture_expiry, &.{root_id}, &.{targets_id});
    defer impossible.deinit();
    gpa.free(impossible.roles[0].key_ids);
    impossible.roles[0].key_ids = try gpa.alloc(keys.KeyId, 0);
    impossible.roles[0].threshold = 2;
    const impossible_fingerprint = try impossible.fingerprint(gpa);
    try std.testing.expectError(
        error.InvalidThreshold,
        enroll(gpa, "example.invalid/acme", impossible, impossible_fingerprint, fixture_now),
    );

    // Timestamp validation itself: leap seconds and bounds are handled, and
    // nonsense is refused.
    try std.testing.expect(validTimestamp("2026-12-31T23:59:60Z"));
    try std.testing.expect(!validTimestamp("2026-13-01T00:00:00Z"));
    try std.testing.expect(!validTimestamp("2026-01-32T00:00:00Z"));
    try std.testing.expect(!validTimestamp("2026-01-01T24:00:00Z"));
    try std.testing.expect(!validTimestamp("2026-01-01T00:00:00+00:00"));
    try std.testing.expectError(error.InvalidTimestamp, expiredAt("soon", fixture_now));
}

test "m07/TRUST-007 rotate roots safely" {
    std.debug.print("JCKG_EVIDENCE TRUST-007\n", .{});
    const gpa = std.testing.allocator;

    const old_root_pair = try keys.testKeyPair("root-old");
    const new_root_pair = try keys.testKeyPair("root-new");
    const targets_pair = try keys.testKeyPair("targets-a");
    const old_root_id = old_root_pair.publicKey().id();
    const new_root_id = new_root_pair.publicKey().id();
    const targets_id = targets_pair.publicKey().id();

    var current_root = try fixtureRoot(gpa, 1, fixture_expiry, &.{old_root_id}, &.{targets_id});
    const current_fingerprint = try current_root.fingerprint(gpa);
    var current = try enroll(gpa, "example.invalid/acme", current_root, current_fingerprint, fixture_now);
    defer current.deinit();

    var next_root = try fixtureRoot(gpa, 2, fixture_expiry, &.{new_root_id}, &.{targets_id});
    const next_encoded = try next_root.encode(gpa);
    defer gpa.free(next_encoded);

    const old_roles = [_]keys.Role{.root};
    const old_ring = keys.KeyRing{ .entries = &.{
        .{ .id = old_root_id, .key = old_root_pair.publicKey(), .roles = &old_roles },
    } };
    const new_ring = keys.KeyRing{ .entries = &.{
        .{ .id = new_root_id, .key = new_root_pair.publicKey(), .roles = &old_roles },
    } };

    const old_signature = try old_root_pair.sign(next_encoded);
    const new_signature = try new_root_pair.sign(next_encoded);

    // A rotation authorized by both sides is accepted and changes identity.
    var rotated = try rotate(
        gpa,
        current,
        next_root,
        old_ring,
        new_ring,
        &.{old_signature},
        &.{new_signature},
        fixture_now,
    );
    defer rotated.deinit();
    try std.testing.expectEqual(@as(u64, 2), rotated.root.version);
    try std.testing.expect(!std.mem.eql(u8, &rotated.fingerprint, &current_fingerprint));
    try std.testing.expectEqualStrings("example.invalid/acme", rotated.repository_identity);

    // The same rotation applied to the rotated state is a rollback.
    var replay_next = try fixtureRoot(gpa, 2, fixture_expiry, &.{new_root_id}, &.{targets_id});
    defer replay_next.deinit();
    try std.testing.expectError(
        error.RollbackDetected,
        rotate(gpa, rotated, replay_next, old_ring, new_ring, &.{old_signature}, &.{new_signature}, fixture_now),
    );

    // Half-authorized rotations are refused: only the new root, and only the
    // old root. Each candidate is signed by the side that is present, so the
    // refusal is about the missing authorization and not about a bad signature.
    var third_for_new_only = try fixtureRoot(gpa, 3, fixture_expiry, &.{new_root_id}, &.{targets_id});
    defer third_for_new_only.deinit();
    const third_for_new_bytes = try third_for_new_only.encode(gpa);
    defer gpa.free(third_for_new_bytes);
    const new_only_signature = try new_root_pair.sign(third_for_new_bytes);
    try std.testing.expectError(
        error.RotationNotAuthorized,
        rotate(gpa, current, third_for_new_only, old_ring, new_ring, &.{}, &.{new_only_signature}, fixture_now),
    );

    var third_for_old_only = try fixtureRoot(gpa, 3, fixture_expiry, &.{new_root_id}, &.{targets_id});
    defer third_for_old_only.deinit();
    const third_for_old_bytes = try third_for_old_only.encode(gpa);
    defer gpa.free(third_for_old_bytes);
    const old_only_signature = try old_root_pair.sign(third_for_old_bytes);
    try std.testing.expectError(
        error.RotationNotAuthorized,
        rotate(gpa, current, third_for_old_only, old_ring, new_ring, &.{old_only_signature}, &.{}, fixture_now),
    );

    // A rotation to an expired root is refused before any authorization is
    // evaluated, and an interrupted rotation leaves the current enrollment
    // untouched: the same call still succeeds afterwards.
    var expired_next = try fixtureRoot(gpa, 3, fixture_past, &.{new_root_id}, &.{targets_id});
    const expired_bytes = try expired_next.encode(gpa);
    defer gpa.free(expired_bytes);
    const expired_old_signature = try old_root_pair.sign(expired_bytes);
    const expired_new_signature = try new_root_pair.sign(expired_bytes);
    try std.testing.expectError(
        error.Expired,
        rotate(gpa, current, expired_next, old_ring, new_ring, &.{expired_old_signature}, &.{expired_new_signature}, fixture_now),
    );
    expired_next.deinit();

    try std.testing.expectEqual(@as(u64, 1), current.root.version);
    const still_current = try current.root.fingerprint(gpa);
    try std.testing.expectEqualSlices(u8, &current_fingerprint, &still_current);
}
