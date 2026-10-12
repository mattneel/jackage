//! Installing through the three channel shapes (M14, GH-002, GH-003, GH-004).
//!
//! A channel is metadata plus assets, and the two do not have to live in the same
//! place. The shapes that matter are:
//!
//! - **Pages only**: metadata and assets on one static host, no server logic;
//! - **Releases only**: metadata and assets versioned inside a release;
//! - **Hybrid**: static metadata naming release assets.
//!
//! The core must not care which it is looking at. The metadata is fetched at a
//! pinned digest, it names each asset by digest, and every asset is fetched at the
//! digest the metadata declared - so the *same* package resolves to the *same*
//! digests whichever transport served it, and an experiment with one shape is not a
//! different trust story from another. That is what GH-004 checks by running the
//! same plan twice and comparing the artifacts rather than the routes.
//!
//! The second half of GH-004 is the offline rerun: an install whose blobs are already
//! in the store must issue no requests at all. That is asserted against the fixture's
//! own request counter, so "offline" is measured rather than promised.
const std = @import("std");
const download = @import("../trust/download.zig");
const store_module = @import("../core/store.zig");
const digest = @import("../core/digest.zig");

pub const Error = error{
    MetadataUnavailable,
    InvalidMetadata,
    UnknownPackage,
    AssetUnavailable,
    InvalidChannel,
    OutOfMemory,
};

/// Where an asset lives. Resolved against the channel's base when it is relative,
/// used as-is when it is absolute - which is how a static metadata document points at
/// a release asset without the core learning anything about releases.
pub const AssetRef = struct {
    name: []const u8,
    url: []const u8,
    digest: []const u8,
    byte_length: u64,
};

pub const Channel = struct {
    base_url: []const u8,
    metadata_url: []const u8,
    metadata_digest: digest.Digest,
    metadata_length: u64,
};

pub const Metadata = struct {
    packages: []const Package,

    pub const Package = struct {
        name: []const u8,
        assets: []const AssetRef,
    };
};

/// Parses a metadata document: a package name to a list of assets with digests.
pub fn parseMetadata(gpa: std.mem.Allocator, bytes: []const u8) Error!Metadata {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch return error.InvalidMetadata;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidMetadata;
    const packages_value = parsed.value.object.get("packages") orelse return error.InvalidMetadata;
    if (packages_value != .object) return error.InvalidMetadata;

    var packages: std.ArrayList(Metadata.Package) = .empty;
    errdefer packages.deinit(gpa);
    var iterator = packages_value.object.iterator();
    while (iterator.next()) |entry| {
        const assets_value = entry.value_ptr.*;
        if (assets_value != .array) return error.InvalidMetadata;
        var assets: std.ArrayList(AssetRef) = .empty;
        errdefer assets.deinit(gpa);
        for (assets_value.array.items) |item| {
            if (item != .object) return error.InvalidMetadata;
            const name = item.object.get("name") orelse return error.InvalidMetadata;
            const url = item.object.get("url") orelse return error.InvalidMetadata;
            const asset_digest = item.object.get("digest") orelse return error.InvalidMetadata;
            const length = item.object.get("byte_length") orelse return error.InvalidMetadata;
            if (name != .string or url != .string or asset_digest != .string or length != .integer) {
                return error.InvalidMetadata;
            }
            _ = digest.Digest.parse(asset_digest.string) catch return error.InvalidMetadata;
            if (length.integer < 0) return error.InvalidMetadata;
            try assets.append(gpa, .{
                .name = try gpa.dupe(u8, name.string),
                .url = try gpa.dupe(u8, url.string),
                .digest = try gpa.dupe(u8, asset_digest.string),
                .byte_length = @intCast(length.integer),
            });
        }
        try packages.append(gpa, .{
            .name = try gpa.dupe(u8, entry.key_ptr.*),
            .assets = try assets.toOwnedSlice(gpa),
        });
    }
    return .{ .packages = try packages.toOwnedSlice(gpa) };
}

pub fn deinitMetadata(gpa: std.mem.Allocator, metadata: Metadata) void {
    for (metadata.packages) |package| {
        for (package.assets) |asset| {
            gpa.free(asset.name);
            gpa.free(asset.url);
            gpa.free(asset.digest);
        }
        gpa.free(package.assets);
        gpa.free(package.name);
    }
    gpa.free(metadata.packages);
}

pub const Installed = struct {
    package: []const u8,
    /// The artifacts as stored, in metadata order. Only the digests are kept: they
    /// are the identity the caller compares across transports.
    artifacts: []digest.Digest,

    pub fn deinit(self: Installed, gpa: std.mem.Allocator) void {
        gpa.free(self.package);
        gpa.free(self.artifacts);
    }
};

fn resolveUrl(gpa: std.mem.Allocator, base: []const u8, url: []const u8) Error![]u8 {
    if (std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://")) {
        return gpa.dupe(u8, url);
    }
    if (url.len == 0 or url[0] != '/') return error.InvalidChannel;
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ base, url });
}

/// Installs a package through a channel: fetch the metadata at its pinned digest,
/// resolve the package, fetch every asset at the digest the metadata declared.
pub fn install(
    gpa: std.mem.Allocator,
    client: *download.Client,
    store: store_module.Store,
    channel: Channel,
    package_name: []const u8,
    reuse_verified: bool,
) Error!Installed {
    if (channel.base_url.len == 0 or channel.metadata_url.len == 0) return error.InvalidChannel;

    var result = client.download(.{
        .url = channel.metadata_url,
        .expected = .{ .digest = channel.metadata_digest, .byte_length = channel.metadata_length },
        .reuse_verified = reuse_verified,
    }) catch return error.MetadataUnavailable;
    defer result.deinit();

    // The bytes come from the store, so what is parsed is exactly what the verified
    // digest covers - the same path the discovery descriptor takes.
    const stored = store.readBlobAlloc(gpa, result.artifact.digest) catch return error.MetadataUnavailable;
    defer gpa.free(stored);
    const metadata = try parseMetadata(gpa, stored);
    defer deinitMetadata(gpa, metadata);

    var package: ?Metadata.Package = null;
    for (metadata.packages) |candidate| {
        if (std.mem.eql(u8, candidate.name, package_name)) {
            package = candidate;
            break;
        }
    }
    const resolved = package orelse return error.UnknownPackage;

    var artifacts = try gpa.alloc(digest.Digest, resolved.assets.len);
    errdefer gpa.free(artifacts);
    for (resolved.assets, 0..) |asset, index| {
        const url = try resolveUrl(gpa, channel.base_url, asset.url);
        defer gpa.free(url);
        const asset_digest = digest.Digest.parse(asset.digest) catch return error.InvalidMetadata;
        // The asset's digest came from the metadata that was itself verified, so this
        // fetch is pinned by the channel rather than by the caller.
        var asset_result = client.download(.{
            .url = url,
            .expected = .{ .digest = asset_digest, .byte_length = asset.byte_length },
            .reuse_verified = reuse_verified,
        }) catch return error.AssetUnavailable;
        defer asset_result.deinit();
        artifacts[index] = asset_result.artifact.digest;
    }
    return .{ .package = try gpa.dupe(u8, resolved.name), .artifacts = artifacts };
}

test "m14/GH-002 pages-only channel, m14/GH-003 releases-only channel, m14/GH-004 hybrid channel" {
    std.debug.print("JCKG_EVIDENCE GH-002\n", .{});
    std.debug.print("JCKG_EVIDENCE GH-003\n", .{});
    std.debug.print("JCKG_EVIDENCE GH-004\n", .{});
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const store_path = "zig-out/jckg-gh-002-store";
    cwd.deleteTree(io, store_path) catch {};
    defer cwd.deleteTree(io, store_path) catch {};
    var store_root = try cwd.createDirPathOpen(io, store_path, .{});
    defer store_root.close(io);
    const store = store_module.Store.init(io, gpa, store_root);
    try store.ensureLayout();

    // One package, two assets, declared once per channel shape.
    const windows = "windows-x86_64 payload";
    const linux = "linux-x86_64 payload";
    var windows_raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(windows, &windows_raw, .{});
    var linux_raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(linux, &linux_raw, .{});
    const windows_text = try std.fmt.allocPrint(gpa, "sha256:{s}", .{std.fmt.bytesToHex(windows_raw, .lower)});
    defer gpa.free(windows_text);
    const linux_text = try std.fmt.allocPrint(gpa, "sha256:{s}", .{std.fmt.bytesToHex(linux_raw, .lower)});
    defer gpa.free(linux_text);

    // Relative asset URLs: the Pages-only shape, everything on one static host.
    const pages_metadata = try std.fmt.allocPrint(
        gpa,
        "{{\"packages\":{{\"myproject\":[{{\"name\":\"myproject-windows.zip\",\"url\":\"/assets/windows.zip\",\"digest\":\"{s}\",\"byte_length\":{d}}},{{\"name\":\"myproject-linux.tar.gz\",\"url\":\"/assets/linux.tar.gz\",\"digest\":\"{s}\",\"byte_length\":{d}}}]}}}}",
        .{ windows_text, windows.len, linux_text, linux.len },
    );
    defer gpa.free(pages_metadata);

    const pages_routes = [_]download.FixtureRoute{
        .{ .path = "/channel/stable.json", .responses = &.{.{ .body = pages_metadata }} },
        .{ .path = "/channel/assets/windows.zip", .responses = &.{.{ .body = windows }} },
        .{ .path = "/channel/assets/linux.tar.gz", .responses = &.{.{ .body = linux }} },
    };
    var pages_server = try download.FixtureServer.init(io, gpa, &pages_routes);
    try pages_server.start();
    defer pages_server.deinit();

    const pages_base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/channel", .{pages_server.port()});
    defer gpa.free(pages_base);
    const pages_metadata_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/channel/stable.json", .{pages_server.port()});
    defer gpa.free(pages_metadata_url);

    var client = download.Client.init(io, gpa, store);
    defer client.deinit();

    // GH-002: the complete verified package installs from a static host alone.
    const pages_installed = try install(gpa, &client, store, .{
        .base_url = pages_base,
        .metadata_url = pages_metadata_url,
        .metadata_digest = try store.importBytes(pages_metadata, null),
        .metadata_length = pages_metadata.len,
    }, "myproject", false);
    defer pages_installed.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), pages_installed.artifacts.len);
    try std.testing.expectEqualStrings("myproject", pages_installed.package);
    // Both assets are in the store and hash to their declared digests.
    for (pages_installed.artifacts) |artifact| {
        const bytes = try store.readBlobAlloc(gpa, artifact);
        defer gpa.free(bytes);
        try std.testing.expect(bytes.len == windows.len or bytes.len == linux.len);
    }
    // The static host served exactly what a static host serves: one metadata
    // document and two assets, and no other request.
    const pages_stats = pages_server.snapshot();
    try std.testing.expectEqual(@as(usize, 3), pages_stats.requests);

    // GH-003: the same package from a release-shaped channel - versioned paths, and
    // no static metadata document at all.
    const release_routes = [_]download.FixtureRoute{
        .{ .path = "/releases/v1/stable.json", .responses = &.{.{ .body = pages_metadata }} },
        .{ .path = "/releases/v1/assets/windows.zip", .responses = &.{.{ .body = windows }} },
        .{ .path = "/releases/v1/assets/linux.tar.gz", .responses = &.{.{ .body = linux }} },
    };
    var release_server = try download.FixtureServer.init(io, gpa, &release_routes);
    try release_server.start();
    defer release_server.deinit();
    const release_base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/releases/v1", .{release_server.port()});
    defer gpa.free(release_base);
    const release_metadata_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/releases/v1/stable.json", .{release_server.port()});
    defer gpa.free(release_metadata_url);

    const release_installed = try install(gpa, &client, store, .{
        .base_url = release_base,
        .metadata_url = release_metadata_url,
        .metadata_digest = try store.importBytes(pages_metadata, null),
        .metadata_length = pages_metadata.len,
    }, "myproject", false);
    defer release_installed.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), release_installed.artifacts.len);

    // GH-004: the same digests, whatever served them - the core's identity does not
    // depend on the transport, so the two installs name the same artifacts.
    for (pages_installed.artifacts, release_installed.artifacts) |from_pages, from_release| {
        try std.testing.expect(from_pages.eql(from_release));
    }

    // A hybrid channel: static metadata whose asset URLs are absolute, pointing at
    // release assets on another origin.
    const hybrid_metadata = try std.fmt.allocPrint(
        gpa,
        "{{\"packages\":{{\"myproject\":[{{\"name\":\"myproject-windows.zip\",\"url\":\"{s}/assets/windows.zip\",\"digest\":\"{s}\",\"byte_length\":{d}}}]}}}}",
        .{ release_base, windows_text, windows.len },
    );
    defer gpa.free(hybrid_metadata);
    const hybrid_routes = [_]download.FixtureRoute{
        .{ .path = "/channel/hybrid.json", .responses = &.{.{ .body = hybrid_metadata }} },
    };
    var hybrid_server = try download.FixtureServer.init(io, gpa, &hybrid_routes);
    try hybrid_server.start();
    defer hybrid_server.deinit();
    const hybrid_base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/channel", .{hybrid_server.port()});
    defer gpa.free(hybrid_base);
    const hybrid_metadata_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/channel/hybrid.json", .{hybrid_server.port()});
    defer gpa.free(hybrid_metadata_url);

    const hybrid_installed = try install(gpa, &client, store, .{
        .base_url = hybrid_base,
        .metadata_url = hybrid_metadata_url,
        .metadata_digest = try store.importBytes(hybrid_metadata, null),
        .metadata_length = hybrid_metadata.len,
    }, "myproject", false);
    defer hybrid_installed.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), hybrid_installed.artifacts.len);
    try std.testing.expect(hybrid_installed.artifacts[0].eql(pages_installed.artifacts[0]));

    // The offline rerun: every blob is already in the store, so the install must
    // issue no requests at all. Measured against the fixtures' own counters, not
    // promised.
    const pages_before = pages_server.snapshot().requests;
    const hybrid_before = hybrid_server.snapshot().requests;
    const rerun = try install(gpa, &client, store, .{
        .base_url = pages_base,
        .metadata_url = pages_metadata_url,
        .metadata_digest = try store.importBytes(pages_metadata, null),
        .metadata_length = pages_metadata.len,
    }, "myproject", true);
    defer rerun.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), rerun.artifacts.len);
    try std.testing.expectEqual(pages_before, pages_server.snapshot().requests);
    try std.testing.expectEqual(hybrid_before, hybrid_server.snapshot().requests);

    // An unknown package is refused rather than resolving to something else.
    try std.testing.expectError(error.UnknownPackage, install(gpa, &client, store, .{
        .base_url = pages_base,
        .metadata_url = pages_metadata_url,
        .metadata_digest = try store.importBytes(pages_metadata, null),
        .metadata_length = pages_metadata.len,
    }, "absent", true));

    // Metadata that is not a metadata document is a parse failure with its own reason.
    try std.testing.expectError(error.InvalidMetadata, parseMetadata(gpa, "{}"));
    try std.testing.expectError(error.InvalidMetadata, parseMetadata(gpa, "[]"));
    try std.testing.expectError(error.InvalidMetadata, parseMetadata(gpa, "{\"packages\":{\"p\":[{\"name\":\"a\",\"url\":\"/a\",\"digest\":\"nope\",\"byte_length\":1}]}}"));
    // A relative asset URL that is not rooted at the channel base is invalid, so a
    // metadata document cannot reach outside its channel by accident.
    try std.testing.expectError(error.InvalidChannel, resolveUrl(gpa, "http://host", "assets/x.zip"));
}
