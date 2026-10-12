//! Refreshing a channel's metadata, and following a repository that moved (M14, GH-005, GH-006).
//!
//! Two things go wrong with a real channel that a fixture can reproduce exactly:
//!
//! - **The metadata does not fit in one response.** It arrives in pages, and the
//!   pages are served by an API that also rate-limits. The adapter must follow every
//!   page - a resolution that stops early silently loses packages, which is the worst
//!   kind of bug because it looks like the package was never published - and it must
//!   retry a rate limit within a stated bound rather than looping until somebody
//!   notices.
//! - **The repository moves.** A URL that worked last week is somewhere else, and a
//!   lockfile written against the old one must still be valid - but only for the same
//!   artifact and the same authorized channel. A new locator that serves different
//!   bytes is not the same package in a new place, it is a different package wearing
//!   the old name, and accepting it would be the classic substitution.
//!
//! Both are handled by pinning what the caller already decided: the digest from the
//! lockfile, the channel that was authorized. The locator is allowed to vary; the
//! identity is not.
const std = @import("std");
const download = @import("../trust/download.zig");
const store_module = @import("../core/store.zig");
const digest = @import("../core/digest.zig");

pub const Error = error{
    RetryLimit,
    PageUnavailable,
    IncompletePagination,
    DigestChanged,
    ChannelChanged,
    UnknownPackage,
    InvalidMetadata,
    NotModified,
    OutOfMemory,
};

pub const Retry = struct {
    /// How many times a rate-limited response is retried before the refresh gives up.
    max_attempts: u8 = 3,
    delay_ms: u32 = 1,
};

pub const PageRef = struct {
    url: []const u8,
    /// The digest the previous page (or the caller) declared for this page. Each page
    /// is pinned by the one before it, so the walk never fetches anything on trust:
    /// the first pin comes from the channel, and every later one from a page that was
    /// itself verified.
    digest: []const u8,
    byte_length: u64,
};

pub const Package = struct {
    name: []const u8,
    digest: []const u8,
};

pub const Page = struct {
    packages: []const Package,
    /// The next page, pinned by this one. Null on the last page.
    next: ?PageRef,
};

/// Parses one page: a package list plus an optional pinned pointer to the next page.
pub fn parsePage(gpa: std.mem.Allocator, bytes: []const u8) Error!Page {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch return error.InvalidMetadata;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidMetadata;
    const packages_value = parsed.value.object.get("packages") orelse return error.InvalidMetadata;
    if (packages_value != .array) return error.InvalidMetadata;

    var packages: std.ArrayList(Package) = .empty;
    errdefer {
        for (packages.items) |package| {
            gpa.free(package.name);
            gpa.free(package.digest);
        }
        packages.deinit(gpa);
    }
    for (packages_value.array.items) |item| {
        if (item != .object) return error.InvalidMetadata;
        const name = item.object.get("name") orelse return error.InvalidMetadata;
        const item_digest = item.object.get("digest") orelse return error.InvalidMetadata;
        if (name != .string or item_digest != .string) return error.InvalidMetadata;
        _ = digest.Digest.parse(item_digest.string) catch return error.InvalidMetadata;
        try packages.append(gpa, .{
            .name = try gpa.dupe(u8, name.string),
            .digest = try gpa.dupe(u8, item_digest.string),
        });
    }

    var next: ?PageRef = null;
    if (parsed.value.object.get("next")) |next_value| {
        if (next_value != .object) return error.InvalidMetadata;
        const url = next_value.object.get("url") orelse return error.InvalidMetadata;
        const next_digest = next_value.object.get("digest") orelse return error.InvalidMetadata;
        const length = next_value.object.get("byte_length") orelse return error.InvalidMetadata;
        if (url != .string or next_digest != .string or length != .integer) return error.InvalidMetadata;
        _ = digest.Digest.parse(next_digest.string) catch return error.InvalidMetadata;
        if (length.integer < 0) return error.InvalidMetadata;
        if (url.string.len == 0) return error.InvalidMetadata;
        next = .{
            .url = try gpa.dupe(u8, url.string),
            .digest = try gpa.dupe(u8, next_digest.string),
            .byte_length = @intCast(length.integer),
        };
    }
    return .{ .packages = try packages.toOwnedSlice(gpa), .next = next };
}

pub fn deinitPage(gpa: std.mem.Allocator, page: Page) void {
    for (page.packages) |package| {
        gpa.free(package.name);
        gpa.free(package.digest);
    }
    gpa.free(page.packages);
    if (page.next) |next| {
        gpa.free(next.url);
        gpa.free(next.digest);
    }
}

pub const Refresh = struct {
    packages: []Package,
    pages_fetched: usize,
    /// The attempts spent on rate-limited responses, so the bound is visible.
    attempts: usize,

    pub fn deinit(self: Refresh, gpa: std.mem.Allocator) void {
        for (self.packages) |package| {
            gpa.free(package.name);
            gpa.free(package.digest);
        }
        gpa.free(self.packages);
    }

    pub fn digestOf(self: Refresh, name: []const u8) ?[]const u8 {
        for (self.packages) |package| {
            if (std.mem.eql(u8, package.name, name)) return package.digest;
        }
        return null;
    }
};

/// Refreshes metadata by following every page, retrying rate limits within a bound.
///
/// The walk ends when a page declares no next page. A page that cannot be fetched
/// ends the refresh with an error rather than returning what was gathered so far: a
/// partial list would resolve the packages it happens to contain and report every
/// other package as unknown, which looks exactly like a package that was never
/// published.
pub fn refresh(
    gpa: std.mem.Allocator,
    client: *download.Client,
    store: store_module.Store,
    base_url: []const u8,
    first: PageRef,
    retry: Retry,
) Error!Refresh {
    if (retry.max_attempts == 0) return error.RetryLimit;

    var packages: std.ArrayList(Package) = .empty;
    errdefer {
        for (packages.items) |package| {
            gpa.free(package.name);
            gpa.free(package.digest);
        }
        packages.deinit(gpa);
    }

    var current_url = try gpa.dupe(u8, first.url);
    defer gpa.free(current_url);
    var current_digest = try gpa.dupe(u8, first.digest);
    defer gpa.free(current_digest);
    var current_length = first.byte_length;
    var pages_fetched: usize = 0;
    var attempts: usize = 0;

    while (true) {
        // The client performs the bounded retry: a rate limit (429 or 503) is
        // transient to it, so the retry budget passed here is the whole policy and
        // the attempts it reports are the attempts that happened.
        const expected = digest.Digest.parse(current_digest) catch return error.InvalidMetadata;
        var result = client.download(.{
            .url = current_url,
            .expected = .{ .digest = expected, .byte_length = current_length },
            .reuse_verified = false,
            .retry = .{
                .max_attempts = retry.max_attempts,
                .initial_delay_ms = retry.delay_ms,
                .max_delay_ms = retry.delay_ms * 4,
            },
        }) catch |err| switch (err) {
            // A rate limit that outlasts the budget is reported as itself, so the
            // caller can tell "the API is throttling us" from "the page is gone".
            error.RetryLimit => return error.RetryLimit,
            else => return error.PageUnavailable,
        };
        defer result.deinit();
        attempts += result.attempts;
        const bytes = store.readBlobAlloc(gpa, result.artifact.digest) catch return error.PageUnavailable;

        defer gpa.free(bytes);
        pages_fetched += 1;

        const page = try parsePage(gpa, bytes);
        for (page.packages) |package| {
            try packages.append(gpa, .{
                .name = try gpa.dupe(u8, package.name),
                .digest = try gpa.dupe(u8, package.digest),
            });
        }
        errdefer deinitPage(gpa, page);

        if (page.next) |next| {
            // A page may name its successor relatively, so a channel can serve pages
            // without knowing its own public address - which is what makes a static
            // host work at all.
            const resolved = if (std.mem.startsWith(u8, next.url, "http://") or std.mem.startsWith(u8, next.url, "https://"))
                try gpa.dupe(u8, next.url)
            else
                try std.fmt.allocPrint(gpa, "{s}{s}", .{ base_url, next.url });
            gpa.free(current_url);
            current_url = resolved;
            gpa.free(current_digest);
            current_digest = try gpa.dupe(u8, next.digest);
            current_length = next.byte_length;
            deinitPage(gpa, page);
            continue;
        }
        deinitPage(gpa, page);
        break;
    }

    return .{
        .packages = try packages.toOwnedSlice(gpa),
        .pages_fetched = pages_fetched,
        .attempts = attempts,
    };
}

// ---------------------------------------------------------------------------
// GH-006: a repository that moved.
// ---------------------------------------------------------------------------

/// What a lockfile recorded about an artifact, independent of where it lives.
pub const Lock = struct {
    package: []const u8,
    digest: []const u8,
    /// The channel whose authorization covers this artifact.
    channel: []const u8,
};

pub const Locator = struct {
    package: []const u8,
    /// Where the artifact is served now. Allowed to differ from the lockfile's day -
    /// a repository that moved is not a different repository.
    url: []const u8,
    channel: []const u8,
    digest: []const u8,
};

/// Resolves a locked artifact against a locator, accepting only the same identity on
/// the same authorized channel.
///
/// The order is deliberate: identity before location. A locator that serves different
/// bytes is refused even if everything about it looks right, because "the same
/// package, in a new place" and "a different package, in the old package's place" are
/// the same observation from here - and only the digest tells them apart.
pub fn resolveLocked(gpa: std.mem.Allocator, lock: Lock, locator: Locator) Error!void {
    _ = gpa;
    if (!std.mem.eql(u8, lock.package, locator.package)) return error.UnknownPackage;
    // The digest is the identity: a locator that serves different bytes is a
    // substitution, however plausible its address and channel are.
    if (!std.mem.eql(u8, lock.digest, locator.digest)) return error.DigestChanged;
    // The channel is the authorization: moving a package to a channel nobody granted
    // is not covered by the lock, even when the bytes are identical.
    if (!std.mem.eql(u8, lock.channel, locator.channel)) return error.ChannelChanged;
}

test "m14/GH-005 handle rate limits, m14/GH-006 handle changed locator" {
    std.debug.print("JCKG_EVIDENCE GH-005\n", .{});
    std.debug.print("JCKG_EVIDENCE GH-006\n", .{});
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const store_path = "zig-out/jckg-gh-005-store";
    cwd.deleteTree(io, store_path) catch {};
    defer cwd.deleteTree(io, store_path) catch {};
    var store_root = try cwd.createDirPathOpen(io, store_path, .{});
    defer store_root.close(io);
    const store = store_module.Store.init(io, gpa, store_root);
    try store.ensureLayout();

    var client = download.Client.init(io, gpa, store);
    defer client.deinit();

    // A refresh with no retry budget at all is refused up front: "bounded retry" with
    // a bound of zero is not a retry policy.
    try std.testing.expectError(error.RetryLimit, refresh(gpa, &client, store, "/c", .{
        .url = "/c/page1", .digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .byte_length = 1,
    }, .{ .max_attempts = 0 }));

    // Three pages, each pinning the next by digest. The package under test is on the
    // last page, so a walk that stops early cannot find it.
    const gamma_digest = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    const page_three = try std.fmt.allocPrint(gpa, "{{\"packages\":[{{\"name\":\"gamma\",\"digest\":\"{s}\"}}]}}", .{gamma_digest});
    defer gpa.free(page_three);
    var page_three_raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(page_three, &page_three_raw, .{});
    const page_three_text = try std.fmt.allocPrint(gpa, "sha256:{s}", .{std.fmt.bytesToHex(page_three_raw, .lower)});
    defer gpa.free(page_three_text);

    const page_two = try std.fmt.allocPrint(
        gpa,
        "{{\"packages\":[{{\"name\":\"beta\",\"digest\":\"{s}\"}}],\"next\":{{\"url\":\"/c/page3\",\"digest\":\"{s}\",\"byte_length\":{d}}}}}",
        .{ gamma_digest, page_three_text, page_three.len },
    );
    defer gpa.free(page_two);
    var page_two_raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(page_two, &page_two_raw, .{});
    const page_two_text = try std.fmt.allocPrint(gpa, "sha256:{s}", .{std.fmt.bytesToHex(page_two_raw, .lower)});
    defer gpa.free(page_two_text);

    const page_one = try std.fmt.allocPrint(
        gpa,
        "{{\"packages\":[{{\"name\":\"alpha\",\"digest\":\"{s}\"}}],\"next\":{{\"url\":\"/c/page2\",\"digest\":\"{s}\",\"byte_length\":{d}}}}}",
        .{ gamma_digest, page_two_text, page_two.len },
    );
    defer gpa.free(page_one);

    // Page two rate-limits on its first attempt and then succeeds, which is what a
    // bounded retry is for.
    const page_two_429 = download.FixtureResponse{ .status = 429, .body = "slow down" };
    const page_two_ok = download.FixtureResponse{ .body = page_two };
    const routes = [_]download.FixtureRoute{
        .{ .path = "/c/page1", .responses = &.{.{ .body = page_one }} },
        .{ .path = "/c/page2", .responses = &.{ page_two_429, page_two_ok } },
        .{ .path = "/c/page3", .responses = &.{.{ .body = page_three }} },
    };
    var server = try download.FixtureServer.init(io, gpa, &routes);
    try server.start();
    defer server.deinit();

    const page_one_url = try server.urlAlloc(gpa, "/c/page1");
    defer gpa.free(page_one_url);
    const base_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{server.port()});
    defer gpa.free(base_url);

    var digest_buffer: [digest.Digest.text_length]u8 = undefined;
    const page_one_stored = try store.importBytes(page_one, null);
    const page_one_digest = try gpa.dupe(u8, page_one_stored.text(&digest_buffer));
    defer gpa.free(page_one_digest);
    const refreshed = try refresh(gpa, &client, store, base_url, .{
        .url = page_one_url,
        .digest = page_one_digest,
        .byte_length = page_one.len,
    }, .{ .max_attempts = 3, .delay_ms = 1 });
    defer refreshed.deinit(gpa);

    // Every page was walked, so a package that exists only on the last page resolves.
    try std.testing.expectEqual(@as(usize, 3), refreshed.pages_fetched);
    try std.testing.expectEqual(@as(usize, 3), refreshed.packages.len);
    try std.testing.expect(refreshed.digestOf("gamma") != null);
    try std.testing.expectEqualStrings(gamma_digest, refreshed.digestOf("gamma").?);
    try std.testing.expect(refreshed.digestOf("alpha") != null);
    // The rate limit cost exactly one extra attempt, and the bound was never reached.
    try std.testing.expectEqual(@as(usize, 4), refreshed.attempts);
    try std.testing.expect(refreshed.attempts <= 3 * 3);

    // A page that is never served fails the refresh rather than returning a partial
    // list: an incomplete walk would report gamma as unknown, which looks exactly
    // like a package that was never published.
    const missing_routes = [_]download.FixtureRoute{
        .{ .path = "/c/page1", .responses = &.{.{ .body = page_one }} },
    };
    var missing_server = try download.FixtureServer.init(io, gpa, &missing_routes);
    try missing_server.start();
    defer missing_server.deinit();
    const missing_url = try missing_server.urlAlloc(gpa, "/c/page1");
    defer gpa.free(missing_url);
    const missing_base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{missing_server.port()});
    defer gpa.free(missing_base);
    try std.testing.expectError(error.PageUnavailable, refresh(gpa, &client, store, missing_base, .{
        .url = missing_url,
        .digest = page_one_digest,
        .byte_length = page_one.len,
    }, .{ .max_attempts = 2, .delay_ms = 1 }));

    // A page whose declared digest does not match what arrives is refused by the
    // download itself - the chain is pinned, so a rewritten page is caught.
    const tampered_routes = [_]download.FixtureRoute{
        .{ .path = "/c/page1", .responses = &.{.{ .body = page_two }} },
    };
    var tampered_server = try download.FixtureServer.init(io, gpa, &tampered_routes);
    try tampered_server.start();
    defer tampered_server.deinit();
    const tampered_url = try tampered_server.urlAlloc(gpa, "/c/page1");
    defer gpa.free(tampered_url);
    try std.testing.expectError(error.PageUnavailable, refresh(gpa, &client, store, "/c", .{
        .url = tampered_url,
        .digest = page_one_digest,
        .byte_length = page_one.len,
    }, .{ .max_attempts = 2, .delay_ms = 1 }));

    // Parsing: the last page declares no next, an empty packages list is valid, and a
    // page missing its list or carrying a malformed digest is refused whole.
    const last_page = try parsePage(gpa, page_three);
    defer deinitPage(gpa, last_page);
    try std.testing.expect(last_page.next == null);
    try std.testing.expectEqual(@as(usize, 1), last_page.packages.len);
    const middle_page = try parsePage(gpa, page_two);
    defer deinitPage(gpa, middle_page);
    try std.testing.expectEqualStrings("/c/page3", middle_page.next.?.url);
    try std.testing.expectEqualStrings(page_three_text, middle_page.next.?.digest);
    const empty_page = try parsePage(gpa, "{\"packages\":[]}");
    defer deinitPage(gpa, empty_page);
    try std.testing.expect(empty_page.next == null);
    try std.testing.expectError(error.InvalidMetadata, parsePage(gpa, "{\"next\":\"/x\"}"));
    try std.testing.expectError(error.InvalidMetadata, parsePage(gpa, "{\"packages\":[{\"name\":\"a\",\"digest\":\"nope\"}]}"));
    try std.testing.expectError(error.InvalidMetadata, parsePage(gpa, "{\"packages\":\"not-an-array\"}"));
    // A next pointer without a digest is refused: an unpinned successor would break
    // the chain the walk depends on.
    try std.testing.expectError(error.InvalidMetadata, parsePage(gpa, "{\"packages\":[],\"next\":{\"url\":\"/x\"}}"));

    // GH-006: the lockfile's identity is what survives the move.
    const lock = Lock{
        .package = "myproject",
        .digest = "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        .channel = "stable",
    };
    try resolveLocked(gpa, lock, .{
        .package = "myproject",
        .url = "https://old.example/jackage/channel",
        .channel = "stable",
        .digest = lock.digest,
    });
    // The same artifact at a new address: also fine - a moved repository is the same
    // repository, and this is the case the function exists for.
    try resolveLocked(gpa, lock, .{
        .package = "myproject",
        .url = "https://new.example/jackage/channel",
        .channel = "stable",
        .digest = lock.digest,
    });
    // Different bytes at the new address: refused. A plausible-looking address is
    // exactly why the check is here.
    try std.testing.expectError(error.DigestChanged, resolveLocked(gpa, lock, .{
        .package = "myproject",
        .url = "https://new.example/jackage/channel",
        .channel = "stable",
        .digest = "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    }));
    // Identical bytes on a channel nobody authorized: refused. The bytes being right
    // does not make the authorization right.
    try std.testing.expectError(error.ChannelChanged, resolveLocked(gpa, lock, .{
        .package = "myproject",
        .url = "https://new.example/jackage/channel",
        .channel = "nightly",
        .digest = lock.digest,
    }));
    // A different package wearing the locked name: refused before anything else.
    try std.testing.expectError(error.UnknownPackage, resolveLocked(gpa, lock, .{
        .package = "other",
        .url = "https://new.example/jackage/channel",
        .channel = "stable",
        .digest = lock.digest,
    }));
}
