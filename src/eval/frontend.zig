//! Locked TS -> esbuild ESM -> source-only QuickJS -> schema-checked canonical
//! Project. All tools are explicit digest-verified executables with an empty
//! environment; recipe imports resolve only over the supplied immutable map.
const std = @import("std");
const builtin = @import("builtin");
const canonical = @import("../core/canonical.zig");
const digest = @import("../core/digest.zig");
const store = @import("../core/store.zig");
const engine = @import("engine.zig");
const schema = @import("schema.zig");
pub const Limits = engine.Limits;
pub const Digest = digest.Digest;

pub const Tool = struct { path: []const u8, sha256: Digest, identity: []const u8 };
const tsconfig_argument = "--tsconfig-raw={\"compilerOptions\":{\"useDefineForClassFields\":true}}";
fn pin(comptime hex: []const u8) Digest { @setEvalBranchQuota(10_000); return comptime Digest.parse("sha256:" ++ hex) catch unreachable; }
pub const Toolchain = struct {
    transformer: ?Tool = if (builtin.os.tag == .windows and builtin.cpu.arch == .x86_64) .{
        .path = "vendor/esbuild/win32-x64/esbuild.exe", .sha256 = pin("ff79bb8beb1ecde2a6c2f54a969e3be0015223b06b75593631947b16df94a09e"), .identity = "esbuild/0.25.10",
    } else if (builtin.os.tag == .linux and builtin.cpu.arch == .x86_64) .{
        .path = "vendor/esbuild/linux-x64/bin/esbuild", .sha256 = pin("b26b7502819ba76774dfd0b61f8c7d1ab8ee99482fca7b5970df746ce6042974"), .identity = "esbuild/0.25.10",
    } else null,
    node: ?Tool = if (builtin.os.tag == .windows and builtin.cpu.arch == .x86_64) .{
        .path = "vendor/node/win32-x64/node.exe", .sha256 = pin("c5ff4c736112dd483c750fd4149d30c8a116db1a49b8b3ec88be4b65e6c86c19"), .identity = "node/22.16.0",
    } else if (builtin.os.tag == .linux and builtin.cpu.arch == .x86_64) .{
        .path = "vendor/node/linux-x64/bin/node", .sha256 = pin("8142d37c6f2f372ef040419e7a111a6baf17df89f8078d02447d6c639ae20c1d"), .identity = "node/22.16.0",
    } else null,
    checker: ?Tool = .{
        .path = "vendor/typescript/lib/typescript.js", .sha256 = pin("3ae902c92cc44dace175c0e69e13a4b0899f6983c6121d76b9ab8dd5795e7675"), .identity = "typescript/5.9.3",
    },
};

/// Bytes may be provided directly, from an immutable blob, or from an explicitly
/// declared local path. The import loader itself never opens paths or store data.
pub const Source = union(enum) {
    bytes: []const u8,
    local: []const u8,
    blob: struct { repository: *const store.Store, object: Digest },
};
pub const LockedModule = struct { name: []const u8, source: Source, digest: Digest };
pub const TypeCheck = enum { not_requested, passed, failed, unavailable };
pub const Target = enum { es2020, es2019 };
pub const Options = struct {
    /// Caller-owned disposable staging directory. No recipe-selected paths.
    work_dir: []const u8,
    entry: []const u8 = "config.ts",
    tools: Toolchain = .{},
    limits: Limits = .{},
    target: Target = .es2020,
    require_type_check: bool = false,
    declared_inputs: canonical.Value = .{ .object = &.{} },
};
pub const Result = struct {
    declaration: canonical.Value,
    /// Canonical plan envelope {declaration, inputs}; this is the digest payload.
    canonical_plan: []u8,
    plan_digest: Digest,
    cache_key: Digest,
    cache_hit: bool,
    type_check: TypeCheck,
    pub fn deinit(self: Result, gpa: std.mem.Allocator) void { self.declaration.deinit(gpa); gpa.free(self.canonical_plan); }
};

/// Only inert, already schema-checked plans are cached. No bytecode crosses the
/// API, and lock integrity and declared-input validation still run on a hit.
pub const Cache = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    const Entry = struct { key: Digest, plan: []u8, checked: TypeCheck };
    pub fn init(gpa: std.mem.Allocator) Cache { return .{ .gpa = gpa }; }
    pub fn deinit(self: *Cache) void { for (self.entries.items) |entry| self.gpa.free(entry.plan); self.entries.deinit(self.gpa); }
    fn lookup(self: *const Cache, key: Digest) ?Entry { for (self.entries.items) |entry| if (entry.key.eql(key)) return entry; return null; }
    fn insert(self: *Cache, key: Digest, plan: []const u8, checked: TypeCheck) !void {
        const copy = try self.gpa.dupe(u8, plan);
        errdefer self.gpa.free(copy);
        try self.entries.append(self.gpa, .{ .key = key, .plan = copy, .checked = checked });
    }
};

pub const Snapshot = struct { name: []const u8, source: []const u8, digest: Digest };
fn snapshotLess(_: void, a: Snapshot, b: Snapshot) bool { return std.mem.lessThan(u8, a.name, b.name); }
fn hashField(hash: *digest.Sha256, bytes: []const u8) void {
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, @intCast(bytes.len), .little);
    hash.update(&len); hash.update(bytes);
}
fn hashTool(hash: *digest.Sha256, tool: ?Tool) void {
    if (tool) |value| { hashField(hash, value.identity); hashField(hash, &value.sha256.bytes); } else hashField(hash, "unavailable");
}
/// `sources` must be sorted by name (the frontend snapshots and sorts them).
/// The engine argument makes engine upgrades explicit to cache callers/tests.
pub fn cacheKey(engine_identity: []const u8, sources: []const Snapshot, options: Options, input_bytes: []const u8) Digest {
    var hash = digest.Sha256.init(.{});
    hash.update("jckg:evaluator-cache:v1\x00");
    hashField(&hash, engine_identity);
    hashTool(&hash, options.tools.transformer);
    hashTool(&hash, options.tools.node); hashTool(&hash, options.tools.checker);
    hashField(&hash, @embedFile("sdk.js")); hashField(&hash, @embedFile("sdk.d.ts"));
    hashField(&hash, @embedFile("checker.cjs"));
    hashField(&hash, "esm;loader=ts;charset=utf8;log=error;top-level-await=true;schema=project-v1;source-only");
    hashField(&hash, tsconfig_argument);
    hashField(&hash, @tagName(options.target));
    hashField(&hash, if (options.require_type_check) "type-check-required" else "transform-only");
    var limits: [8 * 6]u8 = undefined;
    for ([_]u64{ options.limits.heap_bytes, options.limits.stack_bytes, options.limits.deadline_ms, options.limits.max_modules, options.limits.max_source_bytes, options.limits.max_nodes }, 0..) |number, index| std.mem.writeInt(u64, limits[index * 8 ..][0..8], number, .little);
    hashField(&hash, &limits);
    hashField(&hash, options.entry); hashField(&hash, input_bytes);
    for (sources) |source| { hashField(&hash, source.name); hashField(&hash, &source.digest.bytes); }
    var result: Digest = undefined; hash.final(&result.bytes); return result;
}

fn verifyTool(io: std.Io, tool: Tool) !bool {
    // A path with separators is required: never search the host PATH.
    if (std.mem.indexOfAny(u8, tool.path, "/\\") == null) return error.ToolIntegrityMismatch;
    const file = std.Io.Dir.cwd().openFile(io, tool.path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => return false,
        else => return err,
    };
    defer file.close(io);
    var reader = file.reader(io, &.{});
    var buffer: [16 * 1024]u8 = undefined;
    var hash = digest.Sha256.init(.{});
    var total: usize = 0;
    while (true) {
        const count = reader.interface.readSliceShort(&buffer) catch return reader.err orelse error.ToolReadFailed;
        if (count == 0) break;
        total += count;
        if (total > 128 * 1024 * 1024) return error.ToolIntegrityMismatch;
        hash.update(buffer[0..count]);
    }
    var actual: Digest = undefined;
    hash.final(&actual.bytes);
    if (!actual.eql(tool.sha256)) return error.ToolIntegrityMismatch;
    return true;
}
fn runTool(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !std.process.RunResult {
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    return std.process.run(gpa, io, .{
        .argv = argv, .environ_map = &env,
        .stdout_limit = .limited(4 * 1024 * 1024), .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(15_000) } },
    });
}
fn passed(term: std.process.Child.Term) bool { return switch (term) { .exited => |code| code == 0, else => false }; }

fn checkerHostTool() Tool {
    return .{ .path = "src/eval/checker.cjs", .sha256 = digest.ofBlob(@embedFile("checker.cjs")), .identity = "jckg-compiler-host-v1" };
}
fn checkingAvailable(io: std.Io, tools: Toolchain) !bool {
    const node = tools.node orelse return false;
    const checker = tools.checker orelse return false;
    return try verifyTool(io, node) and try verifyTool(io, checker) and try verifyTool(io, checkerHostTool());
}

/// A separate semantic stage. An unavailable checker is never a passing check.
pub fn typeCheck(gpa: std.mem.Allocator, io: std.Io, sources: []const Snapshot, options: Options) !TypeCheck {
    if (!try checkingAvailable(io, options.tools)) return .unavailable;
    return typeCheckVerified(gpa, io, sources, options);
}
fn typeCheckVerified(gpa: std.mem.Allocator, io: std.Io, sources: []const Snapshot, options: Options) !TypeCheck {
    const node = options.tools.node orelse return .unavailable;
    const checker = options.tools.checker orelse return .unavailable;
    const ModuleJob = struct { name: []const u8, source: []const u8 };
    const modules = try gpa.alloc(ModuleJob, sources.len);
    defer gpa.free(modules);
    for (modules, sources) |*module, source| module.* = .{ .name = source.name, .source = source.source };
    const job = try std.json.Stringify.valueAlloc(gpa, .{ .modules = modules, .sdk = @embedFile("sdk.d.ts") }, .{});
    defer gpa.free(job);
    try std.Io.Dir.cwd().createDirPath(io, options.work_dir);
    const job_path = try std.fs.path.join(gpa, &.{ options.work_dir, "typecheck.json" });
    defer gpa.free(job_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = job_path, .data = job });
    const run = runTool(gpa, io, &.{ node.path, checkerHostTool().path, checker.path, job_path }) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => return .unavailable,
        error.StreamTooLong => return error.ResourceLimit,
        else => return err,
    };
    defer gpa.free(run.stdout); defer gpa.free(run.stderr);
    return if (passed(run.term)) .passed else .failed;
}

fn fromCached(gpa: std.mem.Allocator, entry: Cache.Entry, key: Digest) !Result {
    var diagnostic: canonical.Diagnostic = .{};
    const plan = try canonical.parse(gpa, entry.plan, &diagnostic);
    defer plan.deinit(gpa);
    const declaration = schema.get(plan, "declaration") orelse return error.InvalidDeclaration;
    try schema.validate(declaration);
    const copy = try declaration.clone(gpa);
    errdefer copy.deinit(gpa);
    return .{ .declaration = copy, .canonical_plan = try gpa.dupe(u8, entry.plan), .plan_digest = digest.ofCanonicalBytes(.plan, entry.plan), .cache_key = key, .cache_hit = true, .type_check = entry.checked };
}

pub fn evaluate(gpa: std.mem.Allocator, io: std.Io, locked: []const LockedModule, options: Options, cache: ?*Cache) !Result {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const temp = arena.allocator();
    if (locked.len == 0 or locked.len >= options.limits.max_modules) return error.ResourceLimit;
    const snapshots = try temp.alloc(Snapshot, locked.len);
    var total_source: usize = 0;
    for (locked, snapshots, 0..) |module, *snapshot, index| {
        if (!engine.validName(module.name) or std.mem.eql(u8, module.name, "jackage")) return error.ModuleDenied;
        for (locked[0..index]) |previous| if (std.mem.eql(u8, module.name, previous.name)) return error.ModuleDenied;
        const remaining = options.limits.max_source_bytes - total_source;
        const bytes = switch (module.source) {
            .bytes => |bytes| bytes,
            .local => |path| std.Io.Dir.cwd().readFileAlloc(io, path, temp, .limited(remaining +| 1)) catch |err| switch (err) {
                error.StreamTooLong => return error.ResourceLimit,
                else => return err,
            },
            .blob => |blob| blk: {
                if (!module.digest.eql(blob.object)) return error.SourceIntegrityMismatch;
                // Store.readBlobAlloc is intentionally unlimited; read this
                // declared blob via its store-owned path with the source bound.
                // The common digest check below verifies both the lock and blob.
                var path_buffer: [128]u8 = undefined;
                const path = blob.repository.blobPath(blob.object, &path_buffer);
                break :blk blob.repository.dir.readFileAlloc(blob.repository.io, path, temp, .limited(remaining +| 1)) catch |err| switch (err) {
                    error.StreamTooLong => return error.ResourceLimit,
                    else => return err,
                };
            },
        };
        if (bytes.len > remaining) return error.ResourceLimit;
        total_source += bytes.len;
        try engine.validateSource(bytes);
        if (!digest.ofBlob(bytes).eql(module.digest)) return error.SourceIntegrityMismatch;
        snapshot.* = .{ .name = module.name, .source = bytes, .digest = module.digest };
    }
    std.mem.sort(Snapshot, snapshots, {}, snapshotLess);
    for (snapshots) |snapshot| { if (std.mem.eql(u8, snapshot.name, options.entry)) break; } else return error.ModuleDenied;
    // Round-trip through the strict canonical parser to validate caller-supplied
    // values too (including safe integers, Unicode and duplicate object keys).
    if (options.declared_inputs != .object) return error.InvalidDeclaration;
    const raw_inputs = try canonical.encodeAlloc(temp, options.declared_inputs);
    var diagnostic: canonical.Diagnostic = .{};
    var declared = try canonical.parse(temp, raw_inputs, &diagnostic);
    canonical.canonicalize(&declared);
    const input_bytes = try canonical.encodeAlloc(temp, declared);
    const key = cacheKey(engine.identity, snapshots, options, input_bytes);
    // Verify native artifacts even on hits; a changed or missing binary cannot
    // inherit a result under the pinned identity it no longer implements.
    const transformer = options.tools.transformer orelse return error.TransformerUnavailable;
    if (!try verifyTool(io, transformer)) return error.TransformerUnavailable;
    if (options.require_type_check and !try checkingAvailable(io, options.tools)) return error.TypeCheckUnavailable;
    if (cache) |local| if (local.lookup(key)) |entry| return fromCached(gpa, entry, key);
    const checked: TypeCheck = if (options.require_type_check) try typeCheckVerified(temp, io, snapshots, options) else .not_requested;
    switch (checked) { .failed => return error.TypeCheckFailed, .unavailable => return error.TypeCheckUnavailable, else => {} }
    try std.Io.Dir.cwd().createDirPath(io, options.work_dir);
    const modules = try temp.alloc(engine.Module, snapshots.len + 1);
    for (snapshots, modules[0..snapshots.len], 0..) |snapshot, *module, index| {
        const basename = try std.fmt.allocPrint(temp, "transform-{d}.ts", .{index});
        const path = try std.fs.path.join(temp, &.{ options.work_dir, basename });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = snapshot.source });
        const target = try std.fmt.allocPrint(temp, "--target={s}", .{@tagName(options.target)});
        const run = runTool(temp, io, &.{ transformer.path, path, "--loader:.ts=ts", "--format=esm", target, "--supported:top-level-await=true", tsconfig_argument, "--charset=utf8", "--log-level=error" }) catch |err| switch (err) {
            error.StreamTooLong => return error.ResourceLimit,
            else => return err,
        };
        if (!passed(run.term)) return error.TransformFailed;
        module.* = .{ .name = try temp.dupeSentinel(u8, snapshot.name, 0), .javascript = try temp.dupeSentinel(u8, run.stdout, 0) };
    }
    const input_literal = try canonical.encodeAlloc(temp, .{ .string = input_bytes });
    const sdk = try std.fmt.allocPrintSentinel(temp, "{s}\nexport const inputs = Object.freeze(JSON.parse({s}));", .{ @embedFile("sdk.js"), input_literal }, 0);
    modules[snapshots.len] = .{ .name = "jackage", .javascript = sdk };
    const declaration = try engine.evaluate(gpa, io, modules, options.entry, options.limits);
    errdefer declaration.deinit(gpa);
    try schema.validate(declaration);
    const declaration_bytes = try canonical.encodeAlloc(temp, declaration);
    const plan = try std.fmt.allocPrint(gpa, "{{\"declaration\":{s},\"inputs\":{s}}}", .{ declaration_bytes, input_bytes });
    errdefer gpa.free(plan);
    if (cache) |local| try local.insert(key, plan, checked);
    return .{ .declaration = declaration, .canonical_plan = plan, .plan_digest = digest.ofCanonicalBytes(.plan, plan), .cache_key = key, .cache_hit = false, .type_check = checked };
}
