//! Verified runtime artifacts are canonical JSON blobs in core.Store. Runtime
//! edges include every file and every dependent artifact; collection therefore
//! needs no second reference convention. Paths are portable and materialized
//! by copying, never by hardlinking. Command arguments are literal argv prefixes.
const std = @import("std");
const builtin = @import("builtin");
const canonical = @import("../core/canonical.zig");
const digest = @import("../core/digest.zig");
const tree = @import("../core/tree.zig");
const store_module = @import("../core/store.zig");

pub const Command = struct {
    name: []const u8,
    path: []const u8,
    arguments: []const []const u8 = &.{},
};

pub const Artifact = struct {
    schema_version: u32 = 1,
    files: []const tree.Entry,
    commands: []const Command = &.{},
    default_command: ?[]const u8 = null,
    /// Digest text of runtime artifact descriptors, not user source paths.
    dependencies: []const []const u8 = &.{},
};

pub fn componentValid(name: []const u8) bool {
    return name.len <= 128 and tree.portablePathValid(name) and std.mem.indexOfScalar(u8, name, '/') == null;
}

pub fn encode(gpa: std.mem.Allocator, value: anytype) ![]u8 {
    const json = try std.json.Stringify.valueAlloc(gpa, value, .{});
    defer gpa.free(json);
    var diagnostic: canonical.Diagnostic = .{};
    var document = try canonical.parse(gpa, json, &diagnostic);
    defer document.deinit(gpa);
    canonical.canonicalize(&document);
    return canonical.encodeAlloc(gpa, document);
}

pub fn validate(value: Artifact) !void {
    if (value.schema_version != 1) return error.ArtifactVersionUnsupported;
    const model: tree.Tree = .{ .entries = @constCast(value.files), .gpa = undefined };
    try tree.validateWith(model, .portable);
    var offender: ?[]const u8 = null;
    if (tree.destinationCheck(model, if (builtin.os.tag == .windows) .windows else if (builtin.os.tag == .macos) .macos else .linux, &offender)) |err| return err;
    for (value.files) |entry| {
        // Link targets stay inside an artifact. No traversal/absolute link is
        // accepted, and symlink creation failures are returned to the caller.
        if (entry.kind == .symlink and !tree.portablePathValid(entry.target orelse return error.MissingSymlinkTarget)) return error.InvalidTarget;
    }
    for (value.commands, 0..) |command, index| {
        if (!componentValid(command.name)) return error.InvalidCommandName;
        const entry = model.find(command.path) orelse return error.CommandFileMissing;
        if (entry.kind != .file or !entry.executable) return error.CommandNotExecutable;
        for (command.arguments) |argument| if (std.mem.indexOfScalar(u8, argument, 0) != null) return error.InvalidArgument;
        for (value.commands[index + 1 ..]) |other| {
            if (std.ascii.eqlIgnoreCase(command.name, other.name)) return error.DuplicateCommand;
        }
    }
    if (value.default_command) |name| {
        _ = commandNamed(value, name) orelse return error.DefaultCommandMissing;
    }
    for (value.dependencies) |dependency| _ = try digest.Digest.parse(dependency);
}

pub fn commandNamed(value: Artifact, name: []const u8) ?Command {
    for (value.commands) |command| if (std.mem.eql(u8, command.name, name)) return command;
    return null;
}

pub fn read(store: store_module.Store, gpa: std.mem.Allocator, object: digest.Digest) !std.json.Parsed(Artifact) {
    const bytes = try store.readBlobAlloc(gpa, object);
    defer gpa.free(bytes);
    const parsed = try std.json.parseFromSlice(Artifact, gpa, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try validate(parsed.value);
    const encoded = try encode(gpa, parsed.value);
    defer gpa.free(encoded);
    if (!std.mem.eql(u8, bytes, encoded)) return error.ArtifactNotCanonical;
    return parsed;
}

/// Caller serializes publication with profile collection (Manager.publish).
pub fn publish(store: store_module.Store, value: Artifact) !digest.Digest {
    try validate(value);
    for (value.files) |entry| {
        if (entry.kind != .file) continue;
        const object = try digest.Digest.parse(entry.digest orelse return error.MissingFileMetadata);
        const bytes = try store.readBlobAlloc(store.gpa, object);
        defer store.gpa.free(bytes);
        if (bytes.len != entry.byte_length) return error.LengthMismatch;
    }
    for (value.dependencies) |dependency| {
        const parsed = try read(store, store.gpa, try digest.Digest.parse(dependency));
        parsed.deinit();
    }
    const encoded = try encode(store.gpa, value);
    defer store.gpa.free(encoded);
    const object = try store.importBytes(encoded, null);
    for (value.files) |entry| if (entry.kind == .file) try store.addReference(object, try digest.Digest.parse(entry.digest orelse return error.MissingFileMetadata));
    for (value.dependencies) |dependency| try store.addReference(object, try digest.Digest.parse(dependency));
    return object;
}

/// Reference sidecars are mutable store metadata, so verify their completeness
/// against the hashed artifact declarations rather than blindly trusting them.
pub fn verifyReferences(store: store_module.Store, roots: []const digest.Digest) !void {
    var artifacts: std.ArrayList(digest.Digest) = .empty;
    defer artifacts.deinit(store.gpa);
    for (roots) |root| try appendUnique(store.gpa, &artifacts, root);
    var index: usize = 0;
    while (index < artifacts.items.len) : (index += 1) {
        const object = artifacts.items[index];
        const parsed = try read(store, store.gpa, object);
        defer parsed.deinit();
        var declared: std.ArrayList(digest.Digest) = .empty;
        defer declared.deinit(store.gpa);
        for (parsed.value.files) |entry| if (entry.kind == .file) {
            const file = try digest.Digest.parse(entry.digest orelse return error.MissingFileMetadata);
            var buffer: [128]u8 = undefined;
            const stat = try store.dir.statFile(store.io, store.blobPath(file, &buffer), .{});
            if (stat.size != entry.byte_length) return error.LengthMismatch;
            try appendUnique(store.gpa, &declared, file);
        };
        for (parsed.value.dependencies) |text| {
            const dependency = try digest.Digest.parse(text);
            try appendUnique(store.gpa, &declared, dependency);
            try appendUnique(store.gpa, &artifacts, dependency);
        }
        const references = try store.referencesOf(store.gpa, object);
        defer store.gpa.free(references);
        if (references.len != declared.items.len) return error.IncompleteClosure;
        for (declared.items) |expected| {
            var found = false;
            for (references) |reference| if (expected.eql(reference)) { found = true; break; };
            if (!found) return error.IncompleteClosure;
        }
    }
}

/// Artifact descriptors are visited once even when several roots share a
/// dependency. Each descriptor is stored in packages/<digest>, so dependencies
/// cannot silently overwrite files belonging to the selected package.
pub fn materialize(store: store_module.Store, workspace: std.Io.Dir, roots: []const digest.Digest) !void {
    var pending: std.ArrayList(digest.Digest) = .empty;
    defer pending.deinit(store.gpa);
    for (roots) |root| try appendUnique(store.gpa, &pending, root);
    var index: usize = 0;
    while (index < pending.items.len) : (index += 1) {
        const object = pending.items[index];
        const parsed = try read(store, store.gpa, object);
        defer parsed.deinit();
        var prefix_buffer: [80]u8 = undefined;
        const prefix = try packagePath(object, &prefix_buffer);
        try workspace.createDirPath(store.io, prefix);
        const destination = try workspace.openDir(store.io, prefix, .{});
        defer destination.close(store.io);
        for (parsed.value.files) |entry| switch (entry.kind) {
            .file => try store.materializeBlob(try digest.Digest.parse(entry.digest orelse return error.MissingFileMetadata), destination, entry.path, entry.executable),
            .directory => try destination.createDirPath(store.io, entry.path),
            .symlink => {
                if (std.fs.path.dirname(entry.path)) |parent| try destination.createDirPath(store.io, parent);
                try destination.symLink(store.io, entry.target orelse return error.MissingSymlinkTarget, entry.path, .{});
            },
        };
        for (parsed.value.dependencies) |dependency| try appendUnique(store.gpa, &pending, try digest.Digest.parse(dependency));
    }
}

pub fn packagePath(object: digest.Digest, buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "packages/{s}", .{std.fmt.bytesToHex(object.bytes, .lower)});
}

pub fn appendUnique(gpa: std.mem.Allocator, list: *std.ArrayList(digest.Digest), object: digest.Digest) !void {
    for (list.items) |existing| if (existing.eql(object)) return;
    try list.append(gpa, object);
}
