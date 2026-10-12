//! Building a release image from a runtime closure (M15, IMAGE-003).
//!
//! A release image ships what a program needs to *run*, and a build machine contains
//! a great deal more than that: a compiler, the scripts that drove it, and caches
//! holding everything it produced along the way. Those belong to the build, not to
//! the artifact. Shipping them is not merely wasteful - a compiler in a runtime image
//! is tens of megabytes of attack surface, and a cache is a copy of whatever the
//! building machine happened to have compiled.
//!
//! The payload is therefore the **runtime closure**: the objects a run needs, named
//! by digest, and nothing else. Two checks enforce it, and they catch different
//! mistakes:
//!
//! - the closure itself is validated: an object that is not in the store, or a
//!   *build-only* path named as runtime, is refused before anything is written. A
//!   closure that claims the compiler is a mistake somebody needs to see;
//! - the written payload is scanned again, because the closure is data and data gets
//!   edited.
//!
//! The image is written with the same OCI layout writer the development image uses:
//! the two backends differ in what they select, not in how an image is laid out.
const std = @import("std");
const dev = @import("dev_environment.zig");
const scan = @import("layer_scan.zig");
const store_module = @import("../core/store.zig");
const digest = @import("../core/digest.zig");

pub const Error = error{
    InvalidClosure,
    BuildOnlyInClosure,
    UnknownClosureObject,
    BuildOnlyInPayload,
    WriteFailed,
    OutOfMemory,
    // Forwarded from the shared payload and layout code: this module reuses the
    // development image's assembler and writer rather than growing a second one, so
    // its error set includes theirs.
    CredentialInPayload,
    InvalidDeclaration,
    InvalidImage,
    UndeclaredPayload,
};

/// One object in the runtime closure: where it goes in the image, and which stored
/// blob its bytes come from.
pub const RuntimeObject = struct {
    /// Path inside the release image.
    path: []const u8,
    digest: []const u8,
    executable: bool = false,
};

pub const Closure = struct {
    name: []const u8,
    /// The base this release image is built on, as a digest.
    base: []const u8,
    objects: []const RuntimeObject,
};

/// Names that belong to a build and never to a runtime payload. Checked as path
/// components, because these appear at any depth.
const build_only_names = [_][]const u8{
    "tools",
    "scripts",
    ".zig-cache",
    ".zig-cache-strict",
    "zig-cache",
    "zig-out",
    "node_modules",
    "build.zig",
    "build.zig.zon",
};

pub fn buildOnlyPath(gpa: std.mem.Allocator, path: []const u8) bool {
    _ = gpa;
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |component| {
        for (build_only_names) |name| {
            if (std.mem.eql(u8, component, name)) return true;
        }
    }
    return false;
}

/// Validates the closure: every object must be in the store, must be a declared
/// digest, and must not be a build-only path.
pub fn validateClosure(
    gpa: std.mem.Allocator,
    store: store_module.Store,
    closure: Closure,
) Error!void {
    if (closure.name.len == 0 or closure.base.len == 0) return error.InvalidClosure;
    if (closure.objects.len == 0) return error.InvalidClosure;

    for (closure.objects, 0..) |object, index| {
        if (object.path.len == 0) return error.InvalidClosure;
        // A compiler or a cache named as runtime is refused here, where the closure is
        // still data and the message can say what is wrong with it.
        if (buildOnlyPath(gpa, object.path)) return error.BuildOnlyInClosure;
        const expected = digest.Digest.parse(object.digest) catch return error.InvalidClosure;
        if (!store.hasBlob(expected)) return error.UnknownClosureObject;
        // Two objects at one path would make the payload ambiguous, and the last
        // write would win by accident rather than by decision.
        for (closure.objects[index + 1 ..]) |other| {
            if (std.mem.eql(u8, object.path, other.path)) return error.InvalidClosure;
        }
    }
}

pub const Release = struct {
    layout: dev.Layout,
    /// The paths the payload actually contains, in order, so a caller can see what
    /// shipped without reading the tar.
    shipped: []const []const u8,

    pub fn deinit(self: Release, gpa: std.mem.Allocator) void {
        self.layout.deinit(gpa);
        for (self.shipped) |path| gpa.free(path);
        gpa.free(self.shipped);
    }
};

/// Builds the release image: the closure's bytes become the payload, the build-only
/// material is checked absent, and the image is written as an OCI layout.
pub fn build(
    gpa: std.mem.Allocator,
    io: std.Io,
    store: store_module.Store,
    destination: std.Io.Dir,
    closure: Closure,
) Error!Release {
    try validateClosure(gpa, store, closure);

    var files: std.ArrayList(dev.Payload.File) = .empty;
    defer {
        for (files.items) |file| {
            gpa.free(file.path);
            gpa.free(file.bytes);
        }
        files.deinit(gpa);
    }
    for (closure.objects) |object| {
        const expected = digest.Digest.parse(object.digest) catch return error.InvalidClosure;
        const bytes = store.readBlobAlloc(gpa, expected) catch return error.UnknownClosureObject;
        errdefer gpa.free(bytes);
        try files.append(gpa, .{
            .path = try gpa.dupe(u8, object.path),
            .bytes = bytes,
            .executable = object.executable,
        });
    }
    const payload = dev.Payload{ .files = files.items };

    // The second check, on the payload that is about to be written: the closure was
    // data, and data gets edited.
    for (payload.files) |file| {
        if (buildOnlyPath(gpa, file.path)) return error.BuildOnlyInPayload;
        if (scan.prohibitedPathKind(gpa, file.path) != null) return error.BuildOnlyInPayload;
    }
    try dev.scan(gpa, payload);

    var shipped: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (shipped.items) |path| gpa.free(path);
        shipped.deinit(gpa);
    }
    for (payload.files) |file| try shipped.append(gpa, try gpa.dupe(u8, file.path));

    const layout = try dev.writeLayout(gpa, io, destination, .{
        .name = closure.name,
        .base = closure.base,
        .entries = &.{},
        .environment = &.{},
    }, payload);
    return .{ .layout = layout, .shipped = try shipped.toOwnedSlice(gpa) };
}

test "m15/IMAGE-003 assemble release image: build-only tools and caches stay outside the payload" {
    std.debug.print("JCKG_EVIDENCE IMAGE-003\n", .{});
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const store_path = "zig-out/jckg-image-003-store";
    const image_path = "zig-out/jckg-image-003-image";
    cwd.deleteTree(io, store_path) catch {};
    cwd.deleteTree(io, image_path) catch {};
    defer cwd.deleteTree(io, store_path) catch {};
    defer cwd.deleteTree(io, image_path) catch {};

    var store_root = try cwd.createDirPathOpen(io, store_path, .{});
    defer store_root.close(io);
    const store = store_module.Store.init(io, gpa, store_root);
    try store.ensureLayout();

    // The runtime closure: the program and the data it reads at run time.
    const program = "#!/bin/sh\necho jckg\n";
    const data = "runtime payload\n";
    const program_digest = try store.importBytes(program, null);
    const data_digest = try store.importBytes(data, null);
    var program_buffer: [digest.Digest.text_length]u8 = undefined;
    var data_buffer: [digest.Digest.text_length]u8 = undefined;
    const program_text = try gpa.dupe(u8, program_digest.text(&program_buffer));
    defer gpa.free(program_text);
    const data_text = try gpa.dupe(u8, data_digest.text(&data_buffer));
    defer gpa.free(data_text);

    // Build-only bytes exist in the store too - a compiler, a script, a cache - and
    // they are what must not reach the payload.
    const compiler_digest = try store.importBytes("compiler bytes\n", null);
    var compiler_buffer: [digest.Digest.text_length]u8 = undefined;
    const compiler_text = try gpa.dupe(u8, compiler_digest.text(&compiler_buffer));
    defer gpa.free(compiler_text);

    const objects = [_]RuntimeObject{
        .{ .path = "bin/jckg", .digest = program_text, .executable = true },
        .{ .path = "share/jckg/data", .digest = data_text },
    };
    const closure = Closure{ .name = "jckg-runtime", .base = "sha256:00", .objects = &objects };

    var image = try cwd.createDirPathOpen(io, image_path, .{});
    defer image.close(io);
    const release = try build(gpa, io, store, image, closure);
    defer release.deinit(gpa);

    // The payload is the closure, and it is exactly the closure: two entries, in
    // order, with the executable bit preserved.
    try std.testing.expectEqual(@as(usize, 2), release.shipped.len);
    try std.testing.expectEqualStrings("bin/jckg", release.shipped[0]);
    try std.testing.expectEqualStrings("share/jckg/data", release.shipped[1]);

    // Build-only paths are absent from the payload, checked on the whole image rather
    // than on the closure alone: the scan reads every layer back.
    const scanned = try scan.scanLayout(gpa, io, image);
    if (scanned.offense) |offense| {
        defer offense.deinit(gpa);
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(usize, 1), scanned.report.layers_scanned);
    for (release.shipped) |path| {
        try std.testing.expect(!buildOnlyPath(gpa, path));
    }

    // A closure that names the compiler as runtime is refused, and refused before the
    // image exists: this is the mistake a closure edit makes.
    const with_compiler = [_]RuntimeObject{
        objects[0],
        .{ .path = "tools/zig", .digest = compiler_text },
    };
    try std.testing.expectError(
        error.BuildOnlyInClosure,
        build(gpa, io, store, image, .{ .name = "x", .base = "sha256:00", .objects = &with_compiler }),
    );
    // A cache as a runtime object is refused the same way.
    const with_cache = [_]RuntimeObject{
        objects[0],
        .{ .path = "lib/.zig-cache/blob", .digest = compiler_text },
    };
    try std.testing.expectError(
        error.BuildOnlyInClosure,
        build(gpa, io, store, image, .{ .name = "x", .base = "sha256:00", .objects = &with_cache }),
    );
    // The build definition itself is build-only: a release image does not need the
    // instructions that produced it.
    const with_build_file = [_]RuntimeObject{
        objects[0],
        .{ .path = "build.zig", .digest = compiler_text },
    };
    try std.testing.expectError(
        error.BuildOnlyInClosure,
        build(gpa, io, store, image, .{ .name = "x", .base = "sha256:00", .objects = &with_build_file }),
    );

    // An object that is not in the store cannot be shipped, and the error says so
    // rather than writing an empty file.
    const absent = [_]RuntimeObject{.{ .path = "bin/absent", .digest = "sha256:9999999999999999999999999999999999999999999999999999999999999999" }};
    try std.testing.expectError(
        error.UnknownClosureObject,
        build(gpa, io, store, image, .{ .name = "x", .base = "sha256:00", .objects = &absent }),
    );
    // A malformed digest is a caller mistake, not a missing object.
    const malformed = [_]RuntimeObject{.{ .path = "bin/x", .digest = "not-a-digest" }};
    try std.testing.expectError(
        error.InvalidClosure,
        build(gpa, io, store, image, .{ .name = "x", .base = "sha256:00", .objects = &malformed }),
    );
    // Two objects at one path would make the payload ambiguous.
    const duplicated = [_]RuntimeObject{ objects[0], .{ .path = "bin/jckg", .digest = data_text } };
    try std.testing.expectError(
        error.InvalidClosure,
        build(gpa, io, store, image, .{ .name = "x", .base = "sha256:00", .objects = &duplicated }),
    );
    // An empty closure is not a release.
    try std.testing.expectError(
        error.InvalidClosure,
        build(gpa, io, store, image, .{ .name = "x", .base = "sha256:00", .objects = &.{} }),
    );

    // The name rules themselves, including the boundary that a path merely starting
    // with a build-only word is fine.
    try std.testing.expect(buildOnlyPath(gpa, "tools/zig"));
    try std.testing.expect(buildOnlyPath(gpa, "a/tools/zig"));
    try std.testing.expect(buildOnlyPath(gpa, "scripts/test.ps1"));
    try std.testing.expect(buildOnlyPath(gpa, ".zig-cache/artifact"));
    try std.testing.expect(buildOnlyPath(gpa, "zig-out/jckg"));
    try std.testing.expect(buildOnlyPath(gpa, "build.zig"));
    try std.testing.expect(!buildOnlyPath(gpa, "bin/jckg"));
    try std.testing.expect(!buildOnlyPath(gpa, "share/jckg/data"));
    // A file whose name merely begins with a build-only word is not that directory.
    try std.testing.expect(!buildOnlyPath(gpa, "share/tools.md"));
    try std.testing.expect(!buildOnlyPath(gpa, "share/scripts.json"));
}
