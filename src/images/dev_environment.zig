//! Assembling a development image from a locked declaration (M15, IMAGE-001).
//!
//! A development image is a promise about what a build will see: the tools the
//! declaration names, and nothing of the developer's own machine. The second half is
//! the part that goes wrong quietly. A tarball built from a working directory carries
//! whatever was in it - a `.git-credentials`, an SSH key, an environment file with a
//! token - and the result is an image that builds correctly and leaks a secret to
//! everyone who pulls it.
//!
//! Two mechanisms are used together because either alone has a failure mode:
//!
//! - **the payload is declared, not collected**: only the entries the declaration
//!   names are included, so a workspace's extra files are not part of the input at
//!   all;
//! - **the result is scanned**: the built layers are read back and checked for
//!   credential-shaped names and private-key bodies, so a declaration that names a
//!   credential - by accident or after an edit - is caught before the image exists.
//!
//! The output is a real OCI layout on disk: `oci-layout`, `index.json`, and blobs
//! named by digest. It is written that way because an image nobody else can read is
//! not an image, and because the digests are what a downstream consumer verifies.
const std = @import("std");

pub const Error = error{
    UndeclaredPayload,
    CredentialInPayload,
    InvalidDeclaration,
    InvalidImage,
    WriteFailed,
    OutOfMemory,
};

/// One file the declaration includes: where it goes in the image, and where its bytes
/// come from.
pub const Entry = struct {
    /// Path inside the image.
    path: []const u8,
    /// Path in the source tree.
    source: []const u8,
    /// The executable bit, which is part of what a tool *is*.
    executable: bool = false,
};

/// The locked environment declaration: the tools, and nothing else.
pub const Declaration = struct {
    name: []const u8,
    /// The base image this one is built on, as a digest.
    base: []const u8,
    entries: []const Entry,
    /// Environment variables baked into the image config. Values are checked for
    /// credential shapes, because a token pasted into a Dockerfile is the most common
    /// way for one to reach an image.
    environment: []const struct { key: []const u8, value: []const u8 } = &.{},
};

/// Names that are never part of a tool image. Checked on the *basename* and on the
/// whole path, because both spellings occur.
const prohibited_names = [_][]const u8{
    ".git-credentials",
    ".netrc",
    "_netrc",
    "id_rsa",
    "id_ed25519",
    "id_ecdsa",
    ".env",
    "credentials.json",
    ".npmrc",
    ".pypirc",
};

const prohibited_suffixes = [_][]const u8{ ".pem", ".key", ".pfx", ".p12" };

/// Bodies that are a credential whatever they are called.
const prohibited_bodies = [_][]const u8{
    "-----BEGIN OPENSSH PRIVATE KEY-----",
    "-----BEGIN RSA PRIVATE KEY-----",
    "-----BEGIN EC PRIVATE KEY-----",
    "-----BEGIN PRIVATE KEY-----",
    "ghp_",
    "github_pat_",
    "AKIA",
};

pub fn prohibitedPath(gpa: std.mem.Allocator, path: []const u8) bool {
    _ = gpa;
    const basename = std.fs.path.basename(path);
    for (prohibited_names) |name| {
        if (std.mem.eql(u8, basename, name)) return true;
    }
    for (prohibited_suffixes) |suffix| {
        if (std.mem.endsWith(u8, basename, suffix)) return true;
    }
    // A `.git` directory is not a credential but it is never part of a tool image
    // either: it carries the developer's history and remote configuration.
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, ".git")) return true;
        if (std.mem.eql(u8, component, ".ssh")) return true;
    }
    return false;
}

pub fn prohibitedBody(bytes: []const u8) bool {
    for (prohibited_bodies) |pattern| {
        if (std.mem.indexOf(u8, bytes, pattern) != null) return true;
    }
    return false;
}

/// The payload: the files an image layer will contain.
pub const Payload = struct {
    files: []File,

    pub const File = struct {
        path: []const u8,
        bytes: []u8,
        executable: bool,
    };

    pub fn deinit(self: Payload, gpa: std.mem.Allocator) void {
        for (self.files) |file| {
            gpa.free(file.path);
            gpa.free(file.bytes);
        }
        gpa.free(self.files);
    }

    pub fn find(self: Payload, path: []const u8) ?File {
        for (self.files) |file| {
            if (std.mem.eql(u8, file.path, path)) return file;
        }
        return null;
    }
};

/// Builds the payload from the declaration: only declared entries, never a directory
/// listing, so the workspace's other contents are not an input.
pub fn assemble(
    gpa: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    declaration: Declaration,
) Error!Payload {
    if (declaration.name.len == 0 or declaration.base.len == 0) return error.InvalidDeclaration;
    if (declaration.entries.len == 0) return error.InvalidDeclaration;

    var files: std.ArrayList(Payload.File) = .empty;
    errdefer {
        for (files.items) |file| {
            gpa.free(file.path);
            gpa.free(file.bytes);
        }
        files.deinit(gpa);
    }

    for (declaration.entries) |entry| {
        if (entry.path.len == 0 or entry.source.len == 0) return error.InvalidDeclaration;
        if (prohibitedPath(gpa, entry.path) or prohibitedPath(gpa, entry.source)) {
            // The declaration asked for a credential. Refused rather than skipped: a
            // declaration that names one is a mistake somebody needs to see.
            return error.CredentialInPayload;
        }
        const bytes = root.readFileAlloc(io, entry.source, gpa, .limited(64 * 1024 * 1024)) catch
            return error.UndeclaredPayload;
        errdefer gpa.free(bytes);
        // The body is checked too: a key named `notes.txt` is still a key.
        if (prohibitedBody(bytes)) return error.CredentialInPayload;
        try files.append(gpa, .{
            .path = try gpa.dupe(u8, entry.path),
            .bytes = bytes,
            .executable = entry.executable,
        });
    }

    // Environment values are part of the image config, so they are checked with the
    // same rules as file bodies.
    for (declaration.environment) |variable| {
        if (prohibitedBody(variable.value)) return error.CredentialInPayload;
    }
    return .{ .files = try files.toOwnedSlice(gpa) };
}

/// Scans a finished payload for anything credential-shaped. The declaration is
/// checked as it is assembled and the *result* is checked here, because those catch
/// different mistakes: an entry added later, or a tool whose contents changed.
pub fn scan(gpa: std.mem.Allocator, payload: Payload) Error!void {
    for (payload.files) |file| {
        if (prohibitedPath(gpa, file.path)) return error.CredentialInPayload;
        if (prohibitedBody(file.bytes)) return error.CredentialInPayload;
    }
}

pub const Layout = struct {
    /// The image manifest's digest, which is what a consumer references.
    manifest_digest: []u8,
    /// The layer's digest.
    layer_digest: []u8,
    layer_bytes: usize,

    pub fn deinit(self: Layout, gpa: std.mem.Allocator) void {
        gpa.free(self.manifest_digest);
        gpa.free(self.layer_digest);
    }
};

fn sha256Hex(gpa: std.mem.Allocator, bytes: []const u8) Error![]u8 {
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &raw, .{});
    return std.fmt.allocPrint(gpa, "sha256:{s}", .{std.fmt.bytesToHex(raw, .lower)});
}

/// Writes a tar layer containing the payload, deterministically.
///
/// Determinism is not decoration: the same declaration must produce the same layer
/// digest on every build, or nothing downstream can verify what it received. Ordering
/// comes from the declaration, mtimes are fixed, and owner is fixed, so the tar is a
/// function of the payload and nothing about the machine that built it.
fn writeLayerTar(gpa: std.mem.Allocator, payload: Payload) Error![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(gpa);

    for (payload.files) |file| {
        var header: [512]u8 = @splat(0);
        if (file.path.len > 100) return error.InvalidImage;
        @memcpy(header[0..file.path.len], file.path);
        // Mode: 0755 or 0644, as octal text in a fixed field.
        const mode_text = if (file.executable) "0000755" else "0000644";
        @memcpy(header[100..107], mode_text);
        @memcpy(header[108..115], "0000000"); // uid
        @memcpy(header[116..123], "0000000"); // gid
        var size_text: [12]u8 = undefined;
        _ = std.fmt.bufPrint(&size_text, "{o:0>11}", .{file.bytes.len}) catch return error.InvalidImage;
        @memcpy(header[124..135], size_text[0..11]);
        // A fixed mtime: a timestamp would make the same payload digest differently
        // on the next build.
        @memcpy(header[136..147], "00000000000");
        header[156] = '0'; // regular file
        @memcpy(header[257..263], "ustar\x00");
        @memcpy(header[263..265], "00");
        // The checksum field is spaces while the sum is computed, then written as
        // six octal digits, a NUL, and a space.
        @memset(header[148..156], ' ');
        var sum: u32 = 0;
        for (header) |byte| sum += byte;
        var checksum: [8]u8 = undefined;
        _ = std.fmt.bufPrint(&checksum, "{o:0>6}\x00 ", .{sum}) catch return error.InvalidImage;
        @memcpy(header[148..156], &checksum);

        try buffer.appendSlice(gpa, &header);
        try buffer.appendSlice(gpa, file.bytes);
        const padding = (512 - (file.bytes.len % 512)) % 512;
        try buffer.appendNTimes(gpa, 0, padding);
    }
    // Two zero blocks end a tar archive.
    try buffer.appendNTimes(gpa, 0, 1024);
    return buffer.toOwnedSlice(gpa);
}

/// Writes a real OCI image layout: `oci-layout`, `index.json`, and blobs under
/// `blobs/sha256/`, named by digest.
pub fn writeLayout(
    gpa: std.mem.Allocator,
    io: std.Io,
    destination: std.Io.Dir,
    declaration: Declaration,
    payload: Payload,
) Error!Layout {
    const layer = try writeLayerTar(gpa, payload);
    defer gpa.free(layer);

    var environment: std.ArrayList(u8) = .empty;
    defer environment.deinit(gpa);
    environment.appendSlice(gpa, "[") catch return error.OutOfMemory;
    for (declaration.environment, 0..) |variable, index| {
        const piece = std.fmt.allocPrint(gpa, "{s}\"{s}={s}\"", .{
            if (index > 0) "," else "",
            variable.key,
            variable.value,
        }) catch return error.OutOfMemory;
        defer gpa.free(piece);
        environment.appendSlice(gpa, piece) catch return error.OutOfMemory;
    }
    environment.appendSlice(gpa, "]") catch return error.OutOfMemory;

    // The config names the declared platform rather than the build machine's: an image
    // that says it was built for whatever host happened to run the build is not a
    // reproducible artifact.
    const config = std.fmt.allocPrint(
        gpa,
        "{{\"architecture\":\"amd64\",\"os\":\"linux\",\"config\":{{\"Env\":{s},\"Labels\":{{\"name\":\"{s}\",\"base\":\"{s}\"}}}}}}",
        .{ environment.items, declaration.name, declaration.base },
    ) catch return error.OutOfMemory;
    defer gpa.free(config);

    const layer_digest = try sha256Hex(gpa, layer);
    defer gpa.free(layer_digest);
    const config_digest = try sha256Hex(gpa, config);
    defer gpa.free(config_digest);

    const manifest = std.fmt.allocPrint(
        gpa,
        "{{\"schemaVersion\":2,\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"config\":{{\"mediaType\":\"application/vnd.oci.image.config.v1+json\",\"digest\":\"{s}\",\"size\":{d}}},\"layers\":[{{\"mediaType\":\"application/vnd.oci.image.layer.v1.tar\",\"digest\":\"{s}\",\"size\":{d}}}]}}",
        .{ config_digest, config.len, layer_digest, layer.len },
    ) catch return error.OutOfMemory;
    defer gpa.free(manifest);
    const manifest_digest = try sha256Hex(gpa, manifest);
    defer gpa.free(manifest_digest);

    const index = std.fmt.allocPrint(
        gpa,
        "{{\"schemaVersion\":2,\"manifests\":[{{\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"digest\":\"{s}\",\"size\":{d}}}]}}",
        .{ manifest_digest, manifest.len },
    ) catch return error.OutOfMemory;
    defer gpa.free(index);

    destination.createDirPath(io, "blobs/sha256") catch return error.WriteFailed;

    var blob_path: [128]u8 = undefined;
    const blobs = [_]struct { digest: []const u8, bytes: []const u8 }{
        .{ .digest = layer_digest, .bytes = layer },
        .{ .digest = config_digest, .bytes = config },
        .{ .digest = manifest_digest, .bytes = manifest },
    };
    for (blobs) |blob| {
        const hex = blob.digest["sha256:".len..];
        const path = std.mem.print(&blob_path, "blobs/sha256/{s}", .{hex}) catch return error.WriteFailed;
        destination.writeFile(io, .{ .sub_path = path, .data = blob.bytes }) catch return error.WriteFailed;
    }
    destination.writeFile(io, .{ .sub_path = "oci-layout", .data = "{\"imageLayoutVersion\":\"1.0.0\"}" }) catch
        return error.WriteFailed;
    destination.writeFile(io, .{ .sub_path = "index.json", .data = index }) catch return error.WriteFailed;

    return .{
        .manifest_digest = try gpa.dupe(u8, manifest_digest),
        .layer_digest = try gpa.dupe(u8, layer_digest),
        .layer_bytes = layer.len,
    };
}

test "m15/IMAGE-001 assemble dev environment: declared tools, no host credentials" {
    std.debug.print("JCKG_EVIDENCE IMAGE-001\n", .{});
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const source_path = "zig-out/jckg-image-001-source";
    const image_path = "zig-out/jckg-image-001-image";
    cwd.deleteTree(io, source_path) catch {};
    cwd.deleteTree(io, image_path) catch {};
    defer cwd.deleteTree(io, source_path) catch {};
    defer cwd.deleteTree(io, image_path) catch {};

    var source = try cwd.createDirPathOpen(io, source_path, .{ .open_options = .{ .iterate = true } });
    defer source.close(io);
    // The declared tools.
    try source.createDirPath(io, "tools");
    try source.writeFile(io, .{ .sub_path = "tools/zig", .data = "#!/bin/sh\necho zig\n" });
    try source.writeFile(io, .{ .sub_path = "tools/build.sh", .data = "#!/bin/sh\necho build\n" });
    // The developer's own machine, present in the same tree and deliberately not part
    // of the declaration. This is the material the image must not pick up.
    try source.writeFile(io, .{ .sub_path = ".git-credentials", .data = "https://user:token@example\n" });
    try source.writeFile(io, .{ .sub_path = "id_rsa", .data = "-----BEGIN OPENSSH PRIVATE KEY-----\n" });
    try source.createDirPath(io, ".ssh");
    try source.writeFile(io, .{ .sub_path = ".ssh/config", .data = "Host *\n" });
    try source.writeFile(io, .{ .sub_path = "notes.txt", .data = "-----BEGIN RSA PRIVATE KEY-----\n" });

    const entries = [_]Entry{
        .{ .path = "tools/zig", .source = "tools/zig", .executable = true },
        .{ .path = "tools/build.sh", .source = "tools/build.sh", .executable = true },
        .{ .path = "notes.txt", .source = "notes.txt" },
    };
    const declaration = Declaration{
        .name = "jackage-dev",
        .base = "sha256:0000000000000000000000000000000000000000000000000000000000000000",
        .entries = &entries,
        .environment = &.{.{ .key = "JCKG_HOME", .value = "/jckg" }},
    };

    // The payload is the declaration, not the directory: the credentials that are
    // sitting in the source tree are not in the image at all.
    try std.testing.expectError(error.CredentialInPayload, assemble(gpa, io, source, declaration));

    // Drop the entry whose *body* is a private key: the declaration is now clean, and
    // the workspace's credentials are still ignored because they were never declared.
    const clean_entries = [_]Entry{ entries[0], entries[1] };
    const clean = Declaration{ .name = declaration.name, .base = declaration.base, .entries = &clean_entries, .environment = declaration.environment };
    const payload = try assemble(gpa, io, source, clean);
    defer payload.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), payload.files.len);
    try std.testing.expect(payload.find("tools/zig") != null);
    try std.testing.expect(payload.find("tools/build.sh") != null);
    try std.testing.expect(payload.find(".git-credentials") == null);
    try std.testing.expect(payload.find("id_rsa") == null);
    // The executable bit travelled with the tool, because that is part of what a tool
    // is.
    try std.testing.expect(payload.find("tools/zig").?.executable);
    // And the finished payload scans clean.
    try scan(gpa, payload);

    // A declaration that names a credential is refused rather than silently skipping
    // it: somebody needs to see that edit.
    const naming = [_]Entry{.{ .path = ".git-credentials", .source = ".git-credentials" }};
    try std.testing.expectError(
        error.CredentialInPayload,
        assemble(gpa, io, source, .{ .name = "x", .base = "sha256:00", .entries = &naming }),
    );
    // A path under `.git` is refused even though it is not a credential file: a tool
    // image has no business carrying anybody's history.
    const history = [_]Entry{.{ .path = ".git/config", .source = "tools/zig" }};
    try std.testing.expectError(
        error.CredentialInPayload,
        assemble(gpa, io, source, .{ .name = "x", .base = "sha256:00", .entries = &history }),
    );
    // A credential pasted into the environment is caught with the same rules.
    const tokens = [_]Entry{entries[0]};
    try std.testing.expectError(
        error.CredentialInPayload,
        assemble(gpa, io, source, .{
            .name = "x",
            .base = "sha256:00",
            .entries = &tokens,
            .environment = &.{.{ .key = "GITHUB_TOKEN", .value = "ghp_abcdefghijklmnopqrstuvwxyz0123456789" }},
        }),
    );
    // A declared source that does not exist is an error, not an empty file.
    const missing = [_]Entry{.{ .path = "tools/absent", .source = "tools/absent" }};
    try std.testing.expectError(
        error.UndeclaredPayload,
        assemble(gpa, io, source, .{ .name = "x", .base = "sha256:00", .entries = &missing }),
    );
    // An empty declaration is not an image.
    try std.testing.expectError(
        error.InvalidDeclaration,
        assemble(gpa, io, source, .{ .name = "x", .base = "sha256:00", .entries = &.{} }),
    );

    // A real OCI layout on disk: oci-layout, index.json, and blobs named by digest.
    var image = try cwd.createDirPathOpen(io, image_path, .{});
    defer image.close(io);
    const layout = try writeLayout(gpa, io, image, clean, payload);
    defer layout.deinit(gpa);
    try std.testing.expect(std.mem.startsWith(u8, layout.layer_digest, "sha256:"));
    try std.testing.expect(layout.layer_bytes % 512 == 0);
    _ = image.statFile(io, "oci-layout", .{}) catch return error.TestUnexpectedResult;
    _ = image.statFile(io, "index.json", .{}) catch return error.TestUnexpectedResult;
    const layer_blob_path = try std.fmt.allocPrint(gpa, "blobs/sha256/{s}", .{layout.layer_digest["sha256:".len..]});
    defer gpa.free(layer_blob_path);
    const stored = try image.readFileAlloc(io, layer_blob_path, gpa, .limited(1 << 20));
    defer gpa.free(stored);
    try std.testing.expectEqual(layout.layer_bytes, stored.len);
    // The layer is a real tar: the ustar magic is where a tar reader looks for it.
    try std.testing.expectEqualStrings("ustar", stored[257..262]);

    // Two builds of the same declaration produce the same layer digest, which is what
    // makes the artifact verifiable by whoever downloads it.
    const again = try writeLayout(gpa, io, image, clean, payload);
    defer again.deinit(gpa);
    try std.testing.expectEqualStrings(layout.layer_digest, again.layer_digest);
    try std.testing.expectEqualStrings(layout.manifest_digest, again.manifest_digest);
}
