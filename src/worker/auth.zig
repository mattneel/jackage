//! Worker authentication (case STRICT-006).
//!
//! A per-session token authenticates a worker to the controller (and vice
//! versa) using a local test key and a maintained HMAC implementation. The MAC
//! covers the *canonical claims* - session identity, worker identity, expiry -
//! so altering any binding invalidates the token instead of silently
//! re-scoping it. A challenge/response binds the handshake to a fresh nonce, so
//! a recorded response cannot be replayed against another challenge, and every
//! artifact request is checked against the session's declared scope: a worker
//! holding session A's token cannot ask for session B's artifacts.
const std = @import("std");
const canonical = @import("../core/canonical.zig");
const root = @import("../trust/root.zig");

pub const Error = error{
    Unauthenticated,
    InvalidToken,
    ExpiredToken,
    ForeignSession,
    UnknownArtifact,
    InvalidTimestamp,
    OutOfMemory,
};

const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;

pub const mac_length = 32;

pub const Claims = struct {
    session: []const u8,
    worker: []const u8,
    expires: []const u8,
    /// Optional handshake nonce: present for a challenge response, empty for a
    /// session token.
    nonce: []const u8 = "",
};

/// A bearer token or challenge response. `Claims` are repeated here so a
/// verifier can compare what it expects with what the MAC actually covered.
pub const Token = struct {
    claims: Claims,
    mac: [mac_length]u8,
};

fn macOver(gpa: std.mem.Allocator, key: []const u8, claims: Claims) Error![mac_length]u8 {
    if (!root.validTimestamp(claims.expires)) return error.InvalidTimestamp;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const fields = try arena.alloc(canonical.Entry, 4);
    fields[0] = .{ .key = try arena.dupe(u8, "expires"), .value = .{ .string = try arena.dupe(u8, claims.expires) } };
    fields[1] = .{ .key = try arena.dupe(u8, "nonce"), .value = .{ .string = try arena.dupe(u8, claims.nonce) } };
    fields[2] = .{ .key = try arena.dupe(u8, "session"), .value = .{ .string = try arena.dupe(u8, claims.session) } };
    fields[3] = .{ .key = try arena.dupe(u8, "worker"), .value = .{ .string = try arena.dupe(u8, claims.worker) } };
    var document = canonical.Value{ .object = fields };
    canonical.canonicalize(&document);

    const encoded = try canonical.encodeAlloc(gpa, document);
    defer gpa.free(encoded);

    var mac: [mac_length]u8 = undefined;
    Hmac.create(&mac, encoded, key);
    return mac;
}

/// Mints a token (or a challenge response when `nonce` is non-empty).
pub fn issue(gpa: std.mem.Allocator, key: []const u8, claims: Claims) Error!Token {
    if (claims.session.len == 0 or claims.worker.len == 0) return error.Unauthenticated;
    return .{ .claims = claims, .mac = try macOver(gpa, key, claims) };
}

/// Verifies a token against the expectations of the verifier.
pub fn verify(
    gpa: std.mem.Allocator,
    key: []const u8,
    now: []const u8,
    expected_session: []const u8,
    expected_worker: []const u8,
    expected_nonce: []const u8,
    token: Token,
) Error!void {
    if (!root.validTimestamp(now)) return error.InvalidTimestamp;

    // The MAC must cover exactly the claims the verifier expects; a token that
    // was re-scoped by editing a field fails here even if it was legitimately
    // issued for something else.
    if (!std.mem.eql(u8, token.claims.session, expected_session)) return error.ForeignSession;
    if (!std.mem.eql(u8, token.claims.worker, expected_worker)) return error.Unauthenticated;
    if (!std.mem.eql(u8, token.claims.nonce, expected_nonce)) return error.InvalidToken;

    const expected_mac = try macOver(gpa, key, token.claims);
    if (!std.crypto.timing_safe.eql([mac_length]u8, expected_mac, token.mac)) return error.InvalidToken;

    if (root.expiredAt(token.claims.expires, now) catch return error.InvalidTimestamp) return error.ExpiredToken;
}

/// The artifacts a session is allowed to request.
pub const Scope = struct {
    session: []const u8,
    artifact_digests: []const []const u8,

    pub fn allows(self: Scope, digest_text: []const u8) bool {
        for (self.artifact_digests) |allowed| {
            if (std.mem.eql(u8, allowed, digest_text)) return true;
        }
        return false;
    }
};

/// Authorizes one artifact request for a verified session.
///
/// A valid token does not make every artifact reachable: the request must name
/// an artifact inside the session's scope, and a scope belonging to another
/// session is refused outright rather than partially honored.
pub fn authorizeArtifact(
    token_session: []const u8,
    scope: Scope,
    requested_digest: []const u8,
) Error!void {
    if (!std.mem.eql(u8, token_session, scope.session)) return error.ForeignSession;
    if (!scope.allows(requested_digest)) return error.UnknownArtifact;
}

test "m08/STRICT-006 authenticate workers" {
    std.debug.print("JCKG_EVIDENCE STRICT-006\n", .{});
    const gpa = std.testing.allocator;

    const key = "local-test-session-key";
    const other_key = "different-local-key";
    const expires = root.fixture_expiry;

    const claims = Claims{ .session = "session-a", .worker = "worker-1", .expires = expires };
    const token = try issue(gpa, key, claims);

    // A correctly issued token verifies against the verifier's expectations.
    try verify(gpa, key, root.fixture_now, "session-a", "worker-1", "", token);

    // A tampered MAC is refused, and so is a token issued with another key.
    var tampered = token;
    tampered.mac[0] ^= 0x01;
    try std.testing.expectError(error.InvalidToken, verify(gpa, key, root.fixture_now, "session-a", "worker-1", "", tampered));
    const foreign_key_token = try issue(gpa, other_key, claims);
    try std.testing.expectError(error.InvalidToken, verify(gpa, key, root.fixture_now, "session-a", "worker-1", "", foreign_key_token));

    // A token issued for one session cannot be used as another session's: the
    // binding is checked before anything else.
    try std.testing.expectError(error.ForeignSession, verify(gpa, key, root.fixture_now, "session-b", "worker-1", "", token));

    // Re-scoping the claims without the key fails the MAC check: the signed
    // bytes no longer match the presented claims, so an edited token is refused
    // even when the edits agree with the verifier's expectation.
    var rescoped = token;
    rescoped.claims.session = "session-b";
    try std.testing.expectError(error.InvalidToken, verify(gpa, key, root.fixture_now, "session-b", "worker-1", "", rescoped));
    var other_worker = token;
    other_worker.claims.worker = "worker-2";
    try std.testing.expectError(error.InvalidToken, verify(gpa, key, root.fixture_now, "session-a", "worker-2", "", other_worker));

    // Expiry is enforced against the verifier's clock.
    const past_claims = Claims{ .session = "session-a", .worker = "worker-1", .expires = root.fixture_past };
    const expired = try issue(gpa, key, past_claims);
    try std.testing.expectError(error.ExpiredToken, verify(gpa, key, root.fixture_now, "session-a", "worker-1", "", expired));

    // A challenge response is bound to its nonce: the same token cannot be
    // replayed against a fresh challenge.
    const challenge_claims = Claims{ .session = "session-a", .worker = "worker-1", .expires = expires, .nonce = "nonce-1" };
    const response = try issue(gpa, key, challenge_claims);
    try verify(gpa, key, root.fixture_now, "session-a", "worker-1", "nonce-1", response);
    try std.testing.expectError(error.InvalidToken, verify(gpa, key, root.fixture_now, "session-a", "worker-1", "nonce-2", response));

    // Malformed claims never produce a token at all.
    try std.testing.expectError(error.Unauthenticated, issue(gpa, key, .{ .session = "", .worker = "w", .expires = expires }));
    try std.testing.expectError(error.Unauthenticated, issue(gpa, key, .{ .session = "s", .worker = "", .expires = expires }));
    try std.testing.expectError(error.InvalidTimestamp, issue(gpa, key, .{ .session = "s", .worker = "w", .expires = "soon" }));

    // Artifact authorization: the session scope decides reachability.
    const scope_a = Scope{ .session = "session-a", .artifact_digests = &.{
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    } };
    const scope_b = Scope{ .session = "session-b", .artifact_digests = &.{
        "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    } };
    try authorizeArtifact("session-a", scope_a, scope_a.artifact_digests[0]);
    // A valid session-A token cannot reach session B's scope or artifacts.
    try std.testing.expectError(error.ForeignSession, authorizeArtifact("session-a", scope_b, scope_b.artifact_digests[0]));
    // An artifact outside the scope is refused even for its own session.
    try std.testing.expectError(error.UnknownArtifact, authorizeArtifact("session-a", scope_a, scope_b.artifact_digests[0]));
    try std.testing.expectError(
        error.UnknownArtifact,
        authorizeArtifact("session-a", scope_a, "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"),
    );
    try std.testing.expectError(error.UnknownArtifact, authorizeArtifact("session-a", scope_a, ""));

    // A caller who cannot produce a valid MAC is refused: a fabricated token
    // with matching claims but an unsigned MAC is InvalidToken, while a
    // malformed claim binding (empty session or worker) never becomes a token
    // at all and is Unauthenticated above.
    try std.testing.expectError(
        error.InvalidToken,
        verify(gpa, key, root.fixture_now, "session-a", "worker-1", "", .{
            .claims = .{ .session = "session-a", .worker = "worker-1", .expires = expires },
            .mac = @splat(0),
        }),
    );
}
