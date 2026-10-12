//! Profile transactions and holder-aware collection. All mutations and lease
//! publication share a real OS file lock, including across client instances.
//! Generation JSON and pointer data are flushed before atomic rename; a restart
//! reads only `active`, never a staging filename. Collection is conservative:
//! an unended lease, uncertain process, or protected/in-use file is retained.
const std = @import("std");
const builtin = @import("builtin");
const artifact = @import("artifact.zig");
const digest = @import("../core/digest.zig");
const store_module = @import("../core/store.zig");
const resolver = @import("../plan/resolver.zig");
const exec = @import("../exec/mod.zig");
const process = @import("process.zig");

pub const Package = struct {
    namespace: []const u8,
    name: []const u8,
    version: []const u8,
    artifact: []const u8,
};
pub const Command = struct {
    name: []const u8,
    namespace: []const u8,
    package: []const u8,
    artifact: []const u8,
    path: []const u8,
    arguments: []const []const u8 = &.{},
};
pub const Manifest = struct {
    schema_version: u32 = 1,
    id: []const u8,
    parent: ?[]const u8,
    packages: []const Package,
    closure: []const []const u8,
    commands: []const Command,
};
pub const Generation = struct {
    parsed: std.json.Parsed(Manifest),
    pub fn manifest(self: Generation) Manifest { return self.parsed.value; }
    pub fn deinit(self: *Generation) void { self.parsed.deinit(); self.* = undefined; }
    pub fn command(self: Generation, name: []const u8) ?Command {
        for (self.manifest().commands) |entry| if (commandNamesEqual(entry.name, name)) return entry;
        return null;
    }
};

/// Collisions are errors unless this complete owner declaration selects one of
/// the packages exposing the command. No order-dependent last-writer-wins rule.
pub const CommandOwner = struct { command: []const u8, namespace: []const u8, package: []const u8 };
pub const Collision = struct {
    command: [128]u8 = undefined,
    command_len: usize = 0,
    first: [512]u8 = undefined,
    first_len: usize = 0,
    second: [512]u8 = undefined,
    second_len: usize = 0,
    pub fn commandName(self: *const Collision) []const u8 { return self.command[0..self.command_len]; }
    pub fn firstPackage(self: *const Collision) []const u8 { return self.first[0..self.first_len]; }
    pub fn secondPackage(self: *const Collision) []const u8 { return self.second[0..self.second_len]; }
};

pub const ActivationPoint = enum {
    generation_written,
    generation_flushed,
    generation_published,
    pointer_written,
    pointer_flushed,
    pointer_replaced,
};
pub const InstallOptions = struct {
    owners: []const CommandOwner = &.{},
    collision: ?*Collision = null,
    /// A transaction observer may interrupt at any durable boundary. Returning
    /// an error simulates a client stopping; no rollback rewrites the pointer.
    context: ?*anyopaque = null,
    checkpoint: ?*const fn (?*anyopaque, ActivationPoint) anyerror!void = null,
};
/// Windows creation timestamps exceed canonical JSON's safe integer range.
/// Encode the exact tick count as decimal text, never round or truncate it.
pub const Owner = struct {
    pid: u32,
    created: []const u8,
    fn fromIdentity(gpa: std.mem.Allocator, value: process.Identity) !Owner {
        return .{ .pid = value.pid, .created = try gpa.print("{d}", .{value.created}) };
    }
    pub fn identity(self: Owner) !process.Identity {
        return .{ .pid = self.pid, .created = try std.fmt.parseInt(u64, self.created, 10) };
    }
};
pub const LeaseRecord = struct {
    schema_version: u32 = 1,
    id: []const u8,
    generation: ?[]const u8 = null,
    owner: Owner,
    started_ms: i64,
    closure: []const []const u8,
    /// If set, release also requires this external holder to be gone.
    holder: ?Owner = null,
};
pub const Lease = struct {
    manager: Manager,
    profile: []u8,
    parsed: std.json.Parsed(LeaseRecord),
    released: bool = false,
    pub fn id(self: Lease) []const u8 { return self.parsed.value.id; }
    /// The executor journal uses the lease ID as action_id. A live or uncertain
    /// process tree forbids release; callers cannot expire a lease by age.
    pub fn release(self: *Lease) !void {
        if (self.released) return;
        const lock_file = try self.manager.lock();
        defer self.manager.unlock(lock_file);
        try self.ensureStopped();
        var buffer: [512]u8 = undefined;
        var path_buffer: [512]u8 = undefined;
        const path = try profilePath(self.profile, try std.fmt.bufPrint(&buffer, "leases/{s}.json", .{self.id()}), &path_buffer);
        try self.manager.root.deleteFile(self.manager.io, path);
        self.released = true;
    }
    pub fn ensureStopped(self: Lease) !void {
        if (self.parsed.value.holder) |holder| if (process.state(self.manager.io, self.manager.gpa, try holder.identity()) != .gone) return error.LeaseHolderActive;
        const journal_dir = try self.manager.root.openDir(self.manager.io, "profile-journal", .{});
        defer journal_dir.close(self.manager.io);
        const journal: exec.Journal = .{ .dir = journal_dir, .io = self.manager.io, .gpa = self.manager.gpa };
        if (builtin.os.tag == .windows) {
            const observation = try journal.reconcile(self.id());
            if (!observation.safe_to_retry) return error.LeaseHolderActive;
            if (observation.process_state == .not_started) try self.ensureOwnerStopped();
        } else {
            const parsed = journal.read(self.id()) catch |err| switch (err) { error.FileNotFound => return self.ensureOwnerStopped(), else => return err };
            defer parsed.deinit();
            const entry = parsed.value;
            if (entry.process) |identity| {
                if (process.state(self.manager.io, self.manager.gpa, identity) != .gone) return error.LeaseHolderActive;
                for (entry.descendants) |descendant| if (process.state(self.manager.io, self.manager.gpa, descendant) != .gone) return error.LeaseHolderActive;
                const members = try process.groupMembers(self.manager.io, self.manager.gpa, identity.pid);
                defer self.manager.gpa.free(members);
                if (members.len != 0) return error.LeaseHolderActive;
            } else if (entry.phase != .completed) return error.LeaseHolderActive;
        }
    }
    fn ensureOwnerStopped(self: Lease) !void {
        const owner = try self.parsed.value.owner.identity();
        const caller = try process.current(self.manager.io, self.manager.gpa);
        if (owner.pid == caller.pid and owner.created == caller.created) return;
        // A lease with no launched-process journal may represent an open
        // executable held by its controller. Only that controller can end it
        // while alive; another client must prove the exact owner is gone.
        if (process.state(self.manager.io, self.manager.gpa, owner) != .gone) return error.LeaseHolderActive;
    }
    /// Frees the handle, not its durable retention record. Use release only
    /// when the resource/process has ended; dropping a handle is safe on crash.
    pub fn deinit(self: *Lease) void {
        self.parsed.deinit();
        self.manager.gpa.free(self.profile);
        self.* = undefined;
    }
};

pub const CollectionOptions = struct {
    /// Keep active plus this many generations total along its parent chain.
    /// Two allows one-step rollback. Set one for immediate old-generation GC.
    keep_generations: usize = 2,
    mode: store_module.CollectionMode = .apply,
};
pub const CollectionReport = struct {
    retained_generations: usize = 0,
    deleted_generations: usize = 0,
    retained_leases: usize = 0,
    retained_in_use: usize = 0,
    retained_blobs: usize = 0,
    deleted_blobs: usize = 0,
    candidate_blobs: usize = 0,
};

pub const Manager = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    /// Profile/workspace/journal root; core.Store may use a separate directory.
    /// All users collecting that store must use this Manager's root/lock.
    root: std.Io.Dir,
    store: store_module.Store,

    pub fn init(io: std.Io, gpa: std.mem.Allocator, root: std.Io.Dir, store: store_module.Store) Manager {
        return .{ .io = io, .gpa = gpa, .root = root, .store = store };
    }
    pub fn ensureLayout(self: Manager) !void {
        try self.store.ensureLayout();
        try self.root.createDirPath(self.io, "profiles");
        try self.root.createDirPath(self.io, "profile-workspaces");
        try self.root.createDirPath(self.io, "profile-journal");
    }
    pub fn lock(self: Manager) !std.Io.File {
        try self.ensureLayout();
        const file = try self.root.createFile(self.io, "profile.lock", .{ .truncate = false });
        errdefer file.close(self.io);
        try file.lock(self.io, .exclusive);
        return file;
    }
    pub fn unlock(self: Manager, file: std.Io.File) void { file.unlock(self.io); file.close(self.io); }

    /// Trusted local artifact publication; digest verification is not a trust
    /// decision. The caller establishes trust before calling publish/install.
    pub fn publish(self: Manager, value: artifact.Artifact) !digest.Digest {
        const file = try self.lock();
        defer self.unlock(file);
        return artifact.publish(self.store, value);
    }

    pub fn install(self: Manager, name: []const u8, selections: []const resolver.Selection, options: InstallOptions) !Generation {
        try validateProfile(name);
        const file = try self.lock();
        defer self.unlock(file);
        return self.installLocked(name, selections, options);
    }

    fn installLocked(self: Manager, name: []const u8, selections: []const resolver.Selection, options: InstallOptions) !Generation {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const packages = try a.alloc(Package, selections.len);
        var roots: std.ArrayList(digest.Digest) = .empty;
        var commands: std.ArrayList(Command) = .empty;
        for (options.owners, 0..) |owner, index| {
            for (options.owners[index + 1 ..]) |other| if (commandNamesEqual(owner.command, other.command)) return error.DuplicateCommandOwner;
        }
        for (selections, 0..) |selection, index| {
            if (selection.namespace.len == 0 or selection.namespace.len > 256 or !artifact.componentValid(selection.name)) return error.InvalidPackage;
            for (selections[0..index]) |previous| {
                if (std.mem.eql(u8, previous.namespace, selection.namespace) and std.mem.eql(u8, previous.name, selection.name)) return error.DuplicatePackage;
            }
            var version_buffer: [128]u8 = undefined;
            const object = try digest.Digest.parse(selection.artifact_digest);
            var text_buffer: [digest.Digest.text_length]u8 = undefined;
            packages[index] = .{ .namespace = selection.namespace, .name = selection.name, .version = try a.dupe(u8, selection.version.text(&version_buffer)), .artifact = try a.dupe(u8, object.text(&text_buffer)) };
            try artifact.appendUnique(a, &roots, object);
            const parsed = try artifact.read(self.store, a, object);
            const value = parsed.value;
            // Arena owns parsed data until the complete manifest is encoded.
            for (value.commands) |command| {
                const item: Command = .{ .name = command.name, .namespace = selection.namespace, .package = selection.name, .artifact = packages[index].artifact, .path = command.path, .arguments = command.arguments };
                var previous_index: ?usize = null;
                for (commands.items, 0..) |previous, position| if (commandNamesEqual(previous.name, item.name)) { previous_index = position; break; };
                if (previous_index) |position| {
                    const previous = commands.items[position];
                    const owner = ownerFor(options.owners, command.name) orelse {
                        if (options.collision) |diagnostic| fillCollision(diagnostic, previous, item);
                        return error.CommandCollision;
                    };
                    if (owns(owner, item)) commands.items[position] = item else if (!owns(owner, previous)) {
                        // A third declared owner is handled after all packages
                        // have been inspected; retain the first declaration.
                    }
                } else try commands.append(a, item);
            }
        }
        for (options.owners) |owner| {
            var found = false;
            for (packages) |package| {
                if (!std.mem.eql(u8, package.namespace, owner.namespace) or !std.mem.eql(u8, package.name, owner.package)) continue;
                const parsed = try artifact.read(self.store, a, try digest.Digest.parse(package.artifact));
                for (parsed.value.commands) |command| if (commandNamesEqual(command.name, owner.command)) {
                    found = true;
                    for (commands.items) |*item| if (commandNamesEqual(item.name, owner.command)) {
                        item.* = .{ .name = command.name, .namespace = package.namespace, .package = package.name, .artifact = package.artifact, .path = command.path, .arguments = command.arguments };
                    };
                };
            }
            if (!found) return error.InvalidCommandOwner;
        }
        std.mem.sort(Package, packages, {}, packageLess);
        std.mem.sort(Command, commands.items, {}, commandLess);
        const closure = try self.verifiedClosure(a, roots.items);
        const closure_text = try texts(a, closure);
        var active_generation = try self.activeLocked(name);
        defer if (active_generation) |*generation| generation.deinit();
        const id = try newId(a, self.io);
        const manifest: Manifest = .{
            .id = id,
            .parent = if (active_generation) |generation| generation.manifest().id else null,
            .packages = packages,
            .closure = closure_text,
            .commands = commands.items,
        };
        const bytes = try artifact.encode(a, manifest);
        var directory_buffer: [512]u8 = undefined;
        try self.root.createDirPath(self.io, try profilePath(name, "generations", &directory_buffer));
        try self.root.createDirPath(self.io, try profilePath(name, "leases", &directory_buffer));
        var temp_buffer: [512]u8 = undefined;
        const temporary = try std.fmt.bufPrint(&temp_buffer, "profiles/{s}/generations/.write-{s}", .{ name, id });
        {
            const generation_file = try self.root.createFile(self.io, temporary, .{ .exclusive = true });
            defer generation_file.close(self.io);
            try generation_file.writeStreamingAll(self.io, bytes);
            try checkpoint(options, .generation_written);
            try generation_file.sync(self.io);
            try checkpoint(options, .generation_flushed);
        }
        var final_buffer: [512]u8 = undefined;
        const final = try generationPath(name, id, &final_buffer);
        try self.root.renamePreserve(temporary, self.root, final, self.io);
        try checkpoint(options, .generation_published);
        try self.selectLocked(name, id, options);
        return self.readGenerationLocked(name, id);
    }

    fn selectLocked(self: Manager, name: []const u8, id: []const u8, options: InstallOptions) !void {
        var temp_buffer: [512]u8 = undefined;
        const temporary = try std.fmt.bufPrint(&temp_buffer, "profiles/{s}/.active-{s}", .{ name, id });
        {
            const pointer = try self.root.createFile(self.io, temporary, .{ .truncate = true });
            defer pointer.close(self.io);
            try pointer.writeStreamingAll(self.io, id);
            try pointer.writeStreamingAll(self.io, "\n");
            try checkpoint(options, .pointer_written);
            try pointer.sync(self.io);
            try checkpoint(options, .pointer_flushed);
        }
        var active_buffer: [512]u8 = undefined;
        try self.root.rename(temporary, self.root, try profilePath(name, "active", &active_buffer), self.io);
        try checkpoint(options, .pointer_replaced);
    }

    pub fn active(self: Manager, name: []const u8) !?Generation {
        try validateProfile(name);
        const file = try self.lock();
        defer self.unlock(file);
        return self.activeLocked(name);
    }
    fn activeLocked(self: Manager, name: []const u8) !?Generation {
        var buffer: [512]u8 = undefined;
        const bytes = self.root.readFileAlloc(self.io, try profilePath(name, "active", &buffer), self.gpa, .limited(128)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer self.gpa.free(bytes);
        if (bytes.len != 33 or bytes[32] != '\n') return error.InvalidActivePointer;
        return try self.readGenerationLocked(name, bytes[0..32]);
    }
    pub fn readGeneration(self: Manager, name: []const u8, id: []const u8) !Generation {
        try validateProfile(name);
        const file = try self.lock();
        defer self.unlock(file);
        return self.readGenerationLocked(name, id);
    }
    fn readGenerationLocked(self: Manager, name: []const u8, id: []const u8) !Generation {
        if (!idValid(id)) return error.InvalidGenerationId;
        var buffer: [512]u8 = undefined;
        const bytes = try self.root.readFileAlloc(self.io, try generationPath(name, id, &buffer), self.gpa, .limited(16 * 1024 * 1024));
        defer self.gpa.free(bytes);
        const parsed = try std.json.parseFromSlice(Manifest, self.gpa, bytes, .{ .allocate = .alloc_always });
        errdefer parsed.deinit();
        if (parsed.value.schema_version != 1 or !std.mem.eql(u8, parsed.value.id, id)) return error.InvalidGeneration;
        if (parsed.value.parent) |parent| if (!idValid(parent)) return error.InvalidGeneration;
        const encoded = try artifact.encode(self.gpa, parsed.value);
        defer self.gpa.free(encoded);
        if (!std.mem.eql(u8, bytes, encoded)) return error.GenerationNotCanonical;
        var roots: std.ArrayList(digest.Digest) = .empty;
        defer roots.deinit(self.gpa);
        for (parsed.value.packages) |package| {
            const object = try digest.Digest.parse(package.artifact);
            const descriptor = try artifact.read(self.store, self.gpa, object);
            descriptor.deinit();
            try artifact.appendUnique(self.gpa, &roots, object);
        }
        const closure = try self.verifiedClosure(self.gpa, roots.items);
        defer self.gpa.free(closure);
        if (closure.len != parsed.value.closure.len) return error.IncompleteClosure;
        for (closure, parsed.value.closure) |object, text| if (!object.eql(try digest.Digest.parse(text))) return error.IncompleteClosure;
        for (parsed.value.commands, 0..) |command, index| {
            if (!artifact.componentValid(command.name)) return error.InvalidGeneration;
            for (parsed.value.commands[0..index]) |previous| if (commandNamesEqual(previous.name, command.name)) return error.InvalidGeneration;
            var owner_found = false;
            for (parsed.value.packages) |package| {
                if (!std.mem.eql(u8, package.namespace, command.namespace) or !std.mem.eql(u8, package.name, command.package) or !std.mem.eql(u8, package.artifact, command.artifact)) continue;
                const descriptor = try artifact.read(self.store, self.gpa, try digest.Digest.parse(package.artifact));
                defer descriptor.deinit();
                const export_command = artifact.commandNamed(descriptor.value, command.name) orelse return error.InvalidGeneration;
                if (!std.mem.eql(u8, export_command.path, command.path) or export_command.arguments.len != command.arguments.len) return error.InvalidGeneration;
                for (export_command.arguments, command.arguments) |left, right| if (!std.mem.eql(u8, left, right)) return error.InvalidGeneration;
                owner_found = true;
            }
            if (!owner_found) return error.InvalidGeneration;
        }
        return .{ .parsed = parsed };
    }

    /// Omitting target selects the current generation's parent. Both package
    /// selection and command resolution switch through the same atomic pointer.
    pub fn rollback(self: Manager, name: []const u8, target: ?[]const u8) !Generation {
        try validateProfile(name);
        const file = try self.lock();
        defer self.unlock(file);
        var current = (try self.activeLocked(name)) orelse return error.ProfileNotInstalled;
        defer current.deinit();
        const id = target orelse current.manifest().parent orelse return error.NoPreviousGeneration;
        var generation = try self.readGenerationLocked(name, id);
        errdefer generation.deinit();
        try self.selectLocked(name, id, .{});
        return generation;
    }

    /// Creates a new selection without the package, never touches its source,
    /// and recomputes runtime reachability (including shared dependencies).
    pub fn remove(self: Manager, name: []const u8, namespace: []const u8, package_name: []const u8, options: InstallOptions) !Generation {
        try validateProfile(name);
        const file = try self.lock();
        defer self.unlock(file);
        var current = (try self.activeLocked(name)) orelse return error.ProfileNotInstalled;
        defer current.deinit();
        var selections: std.ArrayList(resolver.Selection) = .empty;
        defer selections.deinit(self.gpa);
        var found = false;
        for (current.manifest().packages) |package| {
            if (std.mem.eql(u8, package.namespace, namespace) and std.mem.eql(u8, package.name, package_name)) { found = true; continue; }
            try selections.append(self.gpa, .{ .namespace = package.namespace, .name = package.name, .version = try @import("../plan/version.zig").Version.parse(package.version), .artifact_digest = package.artifact });
        }
        if (!found) return error.PackageNotInstalled;
        return self.installLocked(name, selections.items, options);
    }

    /// A caller running a selected command acquires its lease and generation
    /// under one lock, so collection cannot remove the selection between reads.
    pub fn leaseActive(self: Manager, name: []const u8) !struct { generation: Generation, lease: Lease } {
        try validateProfile(name);
        const file = try self.lock();
        defer self.unlock(file);
        var generation = (try self.activeLocked(name)) orelse return error.ProfileNotInstalled;
        errdefer generation.deinit();
        const roots = try self.gpa.alloc(digest.Digest, generation.manifest().packages.len);
        defer self.gpa.free(roots);
        for (generation.manifest().packages, roots) |package, *root| root.* = try digest.Digest.parse(package.artifact);
        const lease = try self.acquireLeaseLocked(name, generation.manifest().id, roots, null);
        return .{ .generation = generation, .lease = lease };
    }

    /// Loads durable ownership after a client restart. release still performs
    /// real identity/group reconciliation; reading a record does not end it.
    pub fn readLease(self: Manager, name: []const u8, id: []const u8) !Lease {
        if (!artifact.componentValid(name) or !idValid(id)) return error.InvalidLease;
        const file = try self.lock();
        defer self.unlock(file);
        var buffer: [512]u8 = undefined;
        const path = try std.fmt.bufPrint(&buffer, "profiles/{s}/leases/{s}.json", .{ name, id });
        const bytes = try self.root.readFileAlloc(self.io, path, self.gpa, .limited(16 * 1024 * 1024));
        defer self.gpa.free(bytes);
        const parsed = try std.json.parseFromSlice(LeaseRecord, self.gpa, bytes, .{ .allocate = .alloc_always });
        errdefer parsed.deinit();
        const record = parsed.value;
        if (record.schema_version != 1 or !std.mem.eql(u8, record.id, id)) return error.InvalidLease;
        _ = try record.owner.identity();
        if (record.holder) |holder| _ = try holder.identity();
        const encoded = try artifact.encode(self.gpa, record);
        defer self.gpa.free(encoded);
        if (!std.mem.eql(u8, bytes, encoded)) return error.InvalidLease;
        for (record.closure) |text| {
            const blob = try self.store.readBlobAlloc(self.gpa, try digest.Digest.parse(text));
            self.gpa.free(blob);
        }
        return .{ .manager = self, .profile = try self.gpa.dupe(u8, name), .parsed = parsed };
    }

    pub fn acquireLease(self: Manager, name: []const u8, generation_id: ?[]const u8, roots: []const digest.Digest, holder: ?process.Identity) !Lease {
        if (!artifact.componentValid(name)) return error.InvalidProfileName;
        const file = try self.lock();
        defer self.unlock(file);
        return self.acquireLeaseLocked(name, generation_id, roots, holder);
    }
    fn acquireLeaseLocked(self: Manager, name: []const u8, generation_id: ?[]const u8, roots: []const digest.Digest, holder: ?process.Identity) !Lease {
        if (builtin.os.tag != .windows and builtin.os.tag != .linux) return error.ProfilePlatformUnavailable;
        const closure = try self.verifiedClosure(self.gpa, roots);
        defer self.gpa.free(closure);
        if (generation_id) |id| {
            var generation = try self.readGenerationLocked(name, id);
            defer generation.deinit();
            // A generation lease always includes its complete closure, even
            // when the caller requests only one of its packages as a root.
            for (generation.manifest().closure) |text| {
                const object = try digest.Digest.parse(text);
                var included = false;
                for (closure) |entry| if (entry.eql(object)) { included = true; break; };
                if (!included) return error.IncompleteLeaseClosure;
            }
        }
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const id = try newId(a, self.io);
        const record: LeaseRecord = .{
            .id = id,
            .generation = generation_id,
            .owner = try Owner.fromIdentity(a, try process.current(self.io, self.gpa)),
            .started_ms = @intCast(@divTrunc(std.Io.Timestamp.now(self.io, .real).nanoseconds, std.time.ns_per_ms)),
            .closure = try texts(a, closure),
            .holder = if (holder) |identity| try Owner.fromIdentity(a, identity) else null,
        };
        var buffer: [512]u8 = undefined;
        try self.root.createDirPath(self.io, try profilePath(name, "leases", &buffer));
        const path = try std.fmt.bufPrint(&buffer, "profiles/{s}/leases/{s}.json", .{ name, id });
        const bytes = try artifact.encode(a, record);
        try self.writeAtomic(path, bytes);
        const parsed = try std.json.parseFromSlice(LeaseRecord, self.gpa, bytes, .{ .allocate = .alloc_always });
        errdefer parsed.deinit();
        return .{ .manager = self, .profile = try self.gpa.dupe(u8, name), .parsed = parsed };
    }

    pub fn verifiedClosure(self: Manager, gpa: std.mem.Allocator, roots: []const digest.Digest) ![]digest.Digest {
        try artifact.verifyReferences(self.store, roots);
        const closure = try self.store.reachableFrom(gpa, roots);
        errdefer gpa.free(closure);
        for (closure) |object| {
            const bytes = try self.store.readBlobAlloc(gpa, object);
            gpa.free(bytes);
        }
        std.mem.sort(digest.Digest, closure, {}, digestLess);
        return closure;
    }

    pub fn writeAtomic(self: Manager, path: []const u8, bytes: []const u8) !void {
        var nonce: [16]u8 = undefined;
        self.io.random(&nonce);
        const temporary = try self.gpa.print("{s}.write-{s}", .{ path, std.fmt.bytesToHex(nonce, .lower) });
        defer self.gpa.free(temporary);
        defer self.root.deleteFile(self.io, temporary) catch {};
        {
            const file = try self.root.createFile(self.io, temporary, .{ .exclusive = true });
            defer file.close(self.io);
            try file.writeStreamingAll(self.io, bytes);
            try file.sync(self.io);
        }
        try self.root.rename(temporary, self.root, path, self.io);
    }

    /// Every profile participates: active history plus leases form the roots.
    /// Stale temp files are ignored. A durable lease is never implicitly
    /// expired, even when its owner crashed; journal reconciliation is required
    /// before an explicit release. Protected files are reported, not errors.
    pub fn collect(self: Manager, options: CollectionOptions) !CollectionReport {
        if (options.keep_generations == 0) return error.InvalidRetentionCount;
        const file = try self.lock();
        defer self.unlock(file);
        var report: CollectionReport = .{};
        var roots: std.ArrayList(digest.Digest) = .empty;
        defer roots.deinit(self.gpa);
        const profiles = try self.root.openDir(self.io, "profiles", .{ .iterate = true });
        defer profiles.close(self.io);
        var iterator = profiles.iterate();
        while (try iterator.next(self.io)) |entry| {
            if (entry.kind != .directory or !artifact.componentValid(entry.name)) continue;
            const name = entry.name;
            var kept: std.ArrayList([]const u8) = .empty;
            defer { for (kept.items) |id| self.gpa.free(id); kept.deinit(self.gpa); }
            var selected = try self.activeLocked(name);
            var count: usize = 0;
            while (selected) |*generation| {
                const manifest = generation.manifest();
                try appendId(self.gpa, &kept, manifest.id);
                for (manifest.closure) |text| try artifact.appendUnique(self.gpa, &roots, try digest.Digest.parse(text));
                count += 1;
                const parent = if (manifest.parent) |id| try self.gpa.dupe(u8, id) else null;
                generation.deinit();
                selected = null;
                if (parent) |id| {
                    defer self.gpa.free(id);
                    if (count < options.keep_generations) {
                        selected = self.readGenerationLocked(name, id) catch |err| switch (err) { error.FileNotFound => null, else => return err };
                    }
                }
            }
            var buffer: [512]u8 = undefined;
            if (self.root.openDir(self.io, try profilePath(name, "leases", &buffer), .{ .iterate = true })) |leases| {
                defer leases.close(self.io);
                var lease_iterator = leases.iterate();
                while (try lease_iterator.next(self.io)) |lease_file| {
                    if (lease_file.kind != .file or !std.mem.endsWith(u8, lease_file.name, ".json")) continue;
                    const bytes = try leases.readFileAlloc(self.io, lease_file.name, self.gpa, .limited(16 * 1024 * 1024));
                    defer self.gpa.free(bytes);
                    const parsed = try std.json.parseFromSlice(LeaseRecord, self.gpa, bytes, .{ .allocate = .alloc_always });
                    defer parsed.deinit();
                    if (parsed.value.schema_version != 1 or !idValid(parsed.value.id)) return error.InvalidLease;
                    if (parsed.value.generation) |id| try appendId(self.gpa, &kept, id);
                    for (parsed.value.closure) |text| try artifact.appendUnique(self.gpa, &roots, try digest.Digest.parse(text));
                    report.retained_leases += 1;
                }
            } else |err| if (err != error.FileNotFound) return err;
            const generations = self.root.openDir(self.io, try profilePath(name, "generations", &buffer), .{ .iterate = true }) catch |err| switch (err) { error.FileNotFound => continue, else => return err };
            defer generations.close(self.io);
            var names: std.ArrayList([]const u8) = .empty;
            defer { for (names.items) |id| self.gpa.free(id); names.deinit(self.gpa); }
            var generations_iterator = generations.iterate();
            while (try generations_iterator.next(self.io)) |generation| {
                if (generation.kind == .file and std.mem.endsWith(u8, generation.name, ".json") and idValid(generation.name[0 .. generation.name.len - 5])) try names.append(self.gpa, try self.gpa.dupe(u8, generation.name));
            }
            for (names.items) |filename| {
                var retain = false;
                for (kept.items) |id| if (std.mem.eql(u8, id, filename[0 .. filename.len - 5])) { retain = true; break; };
                if (retain) { report.retained_generations += 1; continue; }
                if (options.mode == .dry_run) continue;
                generations.deleteFile(self.io, filename) catch |err| switch (err) {
                    error.FileBusy, error.AccessDenied, error.PermissionDenied => {
                        report.retained_generations += 1;
                        report.retained_in_use += 1;
                        // A protected manifest must retain its referenced bytes.
                        var generation = try self.readGenerationLocked(name, filename[0 .. filename.len - 5]);
                        defer generation.deinit();
                        for (generation.manifest().closure) |text| try artifact.appendUnique(self.gpa, &roots, try digest.Digest.parse(text));
                        continue;
                    },
                    else => return err,
                };
                report.deleted_generations += 1;
            }
        }
        var blobs = try self.store.collect(self.gpa, roots.items, .dry_run);
        defer blobs.deinit();
        report.candidate_blobs = blobs.candidates.len;
        report.retained_blobs = blobs.retained_blobs;
        if (options.mode == .apply) for (blobs.candidates) |object| {
            var buffer: [128]u8 = undefined;
            self.store.dir.deleteFile(self.io, self.store.blobPath(object, &buffer)) catch |err| switch (err) {
                error.FileBusy, error.AccessDenied, error.PermissionDenied => { report.retained_in_use += 1; report.retained_blobs += 1; continue; },
                error.FileNotFound => continue,
                else => return err,
            };
            report.deleted_blobs += 1;
        };
        return report;
    }
};

fn checkpoint(options: InstallOptions, point: ActivationPoint) !void { if (options.checkpoint) |callback| try callback(options.context, point); }
fn validateProfile(name: []const u8) !void { if (!artifact.componentValid(name) or std.mem.eql(u8, name, "_transient")) return error.InvalidProfileName; }
fn profilePath(name: []const u8, tail: []const u8, buffer: []u8) ![]const u8 { return std.fmt.bufPrint(buffer, "profiles/{s}/{s}", .{ name, tail }); }
fn generationPath(name: []const u8, id: []const u8, buffer: []u8) ![]const u8 { return std.fmt.bufPrint(buffer, "profiles/{s}/generations/{s}.json", .{ name, id }); }
fn newId(gpa: std.mem.Allocator, io: std.Io) ![]u8 { var nonce: [16]u8 = undefined; io.random(&nonce); return gpa.dupe(u8, &std.fmt.bytesToHex(nonce, .lower)); }
fn idValid(id: []const u8) bool { if (id.len != 32) return false; for (id) |byte| if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return false; return true; }
fn digestLess(_: void, a: digest.Digest, b: digest.Digest) bool { return std.mem.lessThan(u8, &a.bytes, &b.bytes); }
fn packageLess(_: void, a: Package, b: Package) bool { const order = std.mem.order(u8, a.namespace, b.namespace); return if (order == .eq) std.mem.lessThan(u8, a.name, b.name) else order == .lt; }
fn commandLess(_: void, a: Command, b: Command) bool { return std.mem.lessThan(u8, a.name, b.name); }
fn commandNamesEqual(a: []const u8, b: []const u8) bool { return if (builtin.os.tag == .windows or builtin.os.tag == .macos) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b); }
fn ownerFor(owners: []const CommandOwner, name: []const u8) ?CommandOwner { for (owners) |owner| if (commandNamesEqual(owner.command, name)) return owner; return null; }
fn owns(owner: CommandOwner, command: Command) bool { return std.mem.eql(u8, owner.namespace, command.namespace) and std.mem.eql(u8, owner.package, command.package); }
fn fillCollision(output: *Collision, first: Command, second: Command) void {
    output.command_len = @min(first.name.len, output.command.len); @memcpy(output.command[0..output.command_len], first.name[0..output.command_len]);
    const first_text: []u8 = std.fmt.bufPrint(&output.first, "{s}/{s}", .{ first.namespace, first.package }) catch output.first[0..0];
    const second_text: []u8 = std.fmt.bufPrint(&output.second, "{s}/{s}", .{ second.namespace, second.package }) catch output.second[0..0];
    output.first_len = first_text.len;
    output.second_len = second_text.len;
}
fn texts(gpa: std.mem.Allocator, objects: []const digest.Digest) ![]const []const u8 {
    const result = try gpa.alloc([]const u8, objects.len);
    var initialized: usize = 0;
    errdefer { for (result[0..initialized]) |text| gpa.free(text); gpa.free(result); }
    for (objects, result) |object, *text| { var buffer: [digest.Digest.text_length]u8 = undefined; text.* = try gpa.dupe(u8, object.text(&buffer)); initialized += 1; }
    return result;
}
fn appendId(gpa: std.mem.Allocator, list: *std.ArrayList([]const u8), id: []const u8) !void {
    for (list.items) |existing| if (std.mem.eql(u8, existing, id)) return;
    const copy = try gpa.dupe(u8, id); errdefer gpa.free(copy); try list.append(gpa, copy);
}
