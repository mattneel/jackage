const std = @import("std");
const eval = @import("frontend.zig");
const engine = @import("engine.zig");
const schema = @import("schema.zig");
const canonical = @import("../core/canonical.zig");
const digest = @import("../core/digest.zig");
const store = @import("../core/store.zig");
const gpa = std.testing.allocator;
const io = std.testing.io;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    path: []u8,
    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        return .{ .tmp = tmp, .path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path}) };
    }
    fn deinit(self: *Fixture) void { gpa.free(self.path); self.tmp.cleanup(); }
    fn options(self: Fixture) eval.Options { return .{ .work_dir = self.path }; }
};
fn locked(name: []const u8, source: []const u8) eval.LockedModule { return .{ .name = name, .source = .{ .bytes = source }, .digest = digest.ofBlob(source) }; }
const plain = "export default {name:'plain', inputs:{}, tasks:{}, packages:[]};";
fn run(source: []const u8, options: eval.Options, cache: ?*eval.Cache) !eval.Result { return eval.evaluate(gpa, io, &.{locked("config.ts", source)}, options, cache); }
fn expectName(result: eval.Result, expected: []const u8) !void {
    const name = schema.get(result.declaration, "name") orelse return error.MissingName;
    try std.testing.expect(name == .string);
    try std.testing.expectEqualStrings(expected, name.string);
}
// Unexpected success during a deliberate fault must still release the plan:
// assertion failures are evidence, not allocator leaks or panics.
fn expectRejected(expected: anyerror, outcome: anyerror!eval.Result) !void {
    if (outcome) |value| {
        value.deinit(gpa);
        std.debug.print("expected {s}, evaluated a plan\n", .{@errorName(expected)});
        return error.TestExpectedError;
    } else |actual| try std.testing.expectEqual(expected, actual);
}

test "m04/EVAL-001 transform real TypeScript" {
    std.debug.print("JCKG_EVIDENCE EVAL-001\n", .{});
    var fixture = try Fixture.init(); defer fixture.deinit();
    const source =
        \\import {defineProject, locked} from 'jackage';
        \\import {answer} from './helper.ts';
        \\import type {ImportedNote} from './jackage.d.ts';
        \\interface Recipe { readonly label: string; readonly value: number; }
        \\type Count = number;
        \\const count: Count = answer;
        \\const imported: ImportedNote = {label: 'typed'};
        \\const recipe: Recipe = {label: imported.label, value: count};
        \\export default defineProject({
        \\  name: `${recipe.label}-${recipe.value}`, inputs: {compiler: locked('compiler@1')},
        \\  tasks: {build: {tool: {input: 'compiler', path: 'bin/compiler'}, args: ['--version', ''], inputs: ['compiler'], outputs: ['out'], policy: 'development', execution: 'linux-x86_64', output: 'linux-x86_64'}},
        \\  packages: [{task: 'build', formats: ['tar']}],
        \\});
    ;
    var options = fixture.options(); options.require_type_check = true;
    const result = try eval.evaluate(gpa, io, &.{
        locked("config.ts", source),
        locked("helper.ts", "export const answer: number = 6 * 7;"),
        locked("jackage.d.ts", "export interface ImportedNote { readonly label: string; }"),
    }, options, null);
    defer result.deinit(gpa);
    try expectName(result, "typed-42");
    try std.testing.expectEqual(eval.TypeCheck.passed, result.type_check);
    try std.testing.expect(result.plan_digest.eql(digest.ofCanonicalBytes(.plan, result.canonical_plan)));
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(engine.c.JS_GetVersion()), "0.17.0") != null);
    const recovered = try run(plain, fixture.options(), null); defer recovered.deinit(gpa);
    try expectName(recovered, "plain");
}

test "m04/EVAL-002 separate semantic type checks" {
    std.debug.print("JCKG_EVIDENCE EVAL-002\n", .{});
    var fixture = try Fixture.init(); defer fixture.deinit();
    const source = "const count: number = 'wrong'; export default {name:String(count), inputs:{}, tasks:{}, packages:[]};";
    const transformed = try run(source, fixture.options(), null); defer transformed.deinit(gpa);
    try expectName(transformed, "wrong");
    try std.testing.expectEqual(eval.TypeCheck.not_requested, transformed.type_check);
    const snapshots: []const eval.Snapshot = &.{.{ .name = "config.ts", .source = source, .digest = digest.ofBlob(source) }};
    try std.testing.expectEqual(eval.TypeCheck.failed, try eval.typeCheck(gpa, io, snapshots, fixture.options()));
    var required = fixture.options(); required.require_type_check = true;
    try expectRejected(error.TypeCheckFailed, run(source, required, null));
    required.tools.node = null;
    try std.testing.expectEqual(eval.TypeCheck.unavailable, try eval.typeCheck(gpa, io, snapshots, required));
    try expectRejected(error.TypeCheckUnavailable, run(plain, required, null));
    required.tools = .{};
    const recovery = try run(plain, required, null); defer recovery.deinit(gpa);
    try std.testing.expectEqual(eval.TypeCheck.passed, recovery.type_check);
}

test "m04/EVAL-003 resolve exact locked imports" {
    std.debug.print("JCKG_EVIDENCE EVAL-003\n", .{});
    var fixture = try Fixture.init(); defer fixture.deinit();
    const helper = "export const name: string = 'locked-artifact';";
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "helper.ts", .data = helper });
    const helper_path = try std.fs.path.join(gpa, &.{fixture.path, "helper.ts"}); defer gpa.free(helper_path);
    const source = "import {name} from './helper.ts'; export default {name, inputs:{}, tasks:{}, packages:[]};";
    const local: eval.LockedModule = .{ .name = "helper.ts", .source = .{ .local = helper_path }, .digest = digest.ofBlob(helper) };
    const result = try eval.evaluate(gpa, io, &.{ locked("config.ts", source), local }, fixture.options(), null); defer result.deinit(gpa);
    try expectName(result, "locked-artifact");
    const repository = store.Store.init(io, gpa, fixture.tmp.dir);
    const object = try repository.importBytes(helper, digest.ofBlob(helper));
    const blob: eval.LockedModule = .{ .name = "helper.ts", .source = .{ .blob = .{ .repository = &repository, .object = object } }, .digest = object };
    const stored = try eval.evaluate(gpa, io, &.{ blob, locked("config.ts", source) }, fixture.options(), null); defer stored.deinit(gpa);
    try std.testing.expectEqualStrings(result.canonical_plan, stored.canonical_plan);
    var altered = local; altered.digest = digest.ofBlob("not the artifact");
    try expectRejected(error.SourceIntegrityMismatch, eval.evaluate(gpa, io, &.{ locked("config.ts", source), altered }, fixture.options(), null));
    try expectRejected(error.ModuleDenied, run(source, fixture.options(), null));
    const bare = "import {name} from 'pinned-package'; export default {name, inputs:{}, tasks:{}, packages:[]};";
    const package = try eval.evaluate(gpa, io, &.{ locked("config.ts", bare), locked("pinned-package", helper) }, fixture.options(), null); defer package.deinit(gpa);
    try expectName(package, "locked-artifact");
}

test "m04/EVAL-004 deny undeclared imports before loader access" {
    std.debug.print("JCKG_EVIDENCE EVAL-004\n", .{});
    var fixture = try Fixture.init(); defer fixture.deinit();
    const forbidden: []const []const u8 = &.{ "https://example.invalid/secret.ts", "/host/secret.ts", "C:/host/secret.ts", "../secret.ts", "./nested/../../secret.ts", "node:fs", "unlocked-package" };
    for (forbidden) |specifier| {
        const source = try std.fmt.allocPrint(gpa, "import '{s}'; {s}", .{ specifier, plain }); defer gpa.free(source);
        try expectRejected(error.ModuleDenied, run(source, fixture.options(), null));
        const dynamic = try std.fmt.allocPrint(gpa, "await import('{s}'); {s}", .{ specifier, plain }); defer gpa.free(dynamic);
        try expectRejected(error.ModuleDenied, run(dynamic, fixture.options(), null));
    }
    // The normalizer/loader expose no file, process or network interface.
    const okay = try run(plain, fixture.options(), null); defer okay.deinit(gpa);
    try expectName(okay, "plain");
}

test "m04/EVAL-005 deny ambient effects and host secrets" {
    std.debug.print("JCKG_EVIDENCE EVAL-005\n", .{});
    var fixture = try Fixture.init(); defer fixture.deinit();
    for ([_][]const u8{ "Date.now();", "Math.random();", "performance.now();", "performance.timeOrigin;", "process.env.JCKG_SECRET;", "process.execPath;", "require('fs').readFileSync('/secret');", "process.spawn('command');" }) |effect| {
        const source = try std.fmt.allocPrint(gpa, "{s} {s}", .{effect, plain}); defer gpa.free(source);
        try expectRejected(error.EvaluationFailed, run(source, fixture.options(), null));
    }
    const probe = "export default {name:[typeof Date, typeof Math.random, typeof performance, typeof process, typeof require, typeof os, typeof std, typeof fetch].join(','), inputs:{}, tasks:{}, packages:[]};";
    const result = try run(probe, fixture.options(), null); defer result.deinit(gpa);
    try expectName(result, "undefined,undefined,undefined,undefined,undefined,undefined,undefined,undefined");
    try std.testing.expect(std.mem.indexOf(u8, result.canonical_plan, "JCKG_SECRET") == null);
    const explicit = "import {inputs} from 'jackage'; export default {name:String(inputs.label), inputs:{}, tasks:{}, packages:[]};";
    var input_entries = [_]canonical.Entry{.{ .key = "label", .value = .{ .string = "declared-public-value" } }};
    var options = fixture.options(); options.declared_inputs = .{ .object = &input_entries };
    const declared = try run(explicit, options, null); defer declared.deinit(gpa);
    try expectName(declared, "declared-public-value");
}

test "m04/EVAL-006 produce repeatable canonical plans" {
    std.debug.print("JCKG_EVIDENCE EVAL-006\n", .{});
    var first_fixture = try Fixture.init(); defer first_fixture.deinit();
    var second_fixture = try Fixture.init(); defer second_fixture.deinit();
    // Contradictory ambient tsconfigs must never influence the pinned transform.
    try first_fixture.tmp.dir.writeFile(io, .{ .sub_path = "tsconfig.json", .data = "{\"compilerOptions\":{\"useDefineForClassFields\":false}}" });
    try second_fixture.tmp.dir.writeFile(io, .{ .sub_path = "tsconfig.json", .data = "{\"compilerOptions\":{\"useDefineForClassFields\":true}}" });
    const source =
        \\import {inputs} from 'jackage';
        \\class Base { set label(value: string) { throw new Error('ambient class-field assignment'); } }
        \\class Recipe extends Base { label: string = String(inputs.label); }
        \\export default {packages:[], tasks:{}, inputs:{}, name:new Recipe().label};
    ;
    var entries = [_]canonical.Entry{.{ .key = "label", .value = .{ .string = "repeatable" } }};
    var first_options = first_fixture.options(); first_options.declared_inputs = .{ .object = &entries };
    var second_options = second_fixture.options(); second_options.declared_inputs = .{ .object = &entries };
    const first = try run(source, first_options, null); defer first.deinit(gpa);
    const second = try run(source, second_options, null); defer second.deinit(gpa);
    try expectName(first, "repeatable");
    try expectName(second, "repeatable");
    try std.testing.expectEqualStrings(first.canonical_plan, second.canonical_plan);
    try std.testing.expect(first.plan_digest.eql(second.plan_digest));
    try std.testing.expect(first.cache_key.eql(second.cache_key));
    entries[0].value = .{ .string = "changed-input" };
    const changed = try run(source, second_options, null); defer changed.deinit(gpa);
    try std.testing.expect(!first.plan_digest.eql(changed.plan_digest));
}

test "m04/EVAL-007 interrupt infinite evaluation without publishing" {
    std.debug.print("JCKG_EVIDENCE EVAL-007\n", .{});
    var fixture = try Fixture.init(); defer fixture.deinit();
    var options = fixture.options(); options.limits.deadline_ms = 40;
    var cache = eval.Cache.init(gpa); defer cache.deinit();
    const start = std.Io.Timestamp.now(io, .awake);
    try expectRejected(error.DeadlineExceeded, run("while(true) {} " ++ plain, options, &cache));
    const elapsed = start.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();
    try std.testing.expect(elapsed < 2000);
    try std.testing.expectEqual(@as(usize, 0), cache.entries.items.len);
    const recovery = try run(plain, fixture.options(), &cache); defer recovery.deinit(gpa);
    try expectName(recovery, "plain");
}

test "m04/EVAL-008 bound heap allocation and release engine resources" {
    std.debug.print("JCKG_EVIDENCE EVAL-008\n", .{});
    var fixture = try Fixture.init(); defer fixture.deinit();
    var options = fixture.options(); options.limits.heap_bytes = 1024 * 1024;
    var cache = eval.Cache.init(gpa); defer cache.deinit();
    for (0..3) |_| try expectRejected(error.ResourceLimit, run("const allocation = new Array(2000000).fill(7); " ++ plain, options, &cache));
    try std.testing.expectEqual(@as(usize, 0), cache.entries.items.len);
    const recovery = try run(plain, fixture.options(), null); defer recovery.deinit(gpa);
    try expectName(recovery, "plain");
    // std.testing.allocator backs all VM callbacks; runner leak checks include
    // repeated memory failures, every C resource and the following recovery.
}

test "m04/EVAL-009 reject active values without invoking callbacks" {
    std.debug.print("JCKG_EVIDENCE EVAL-009\n", .{});
    var fixture = try Fixture.init(); defer fixture.deinit();
    const rejected: []const []const u8 = &.{
        "export default {name:()=> 'callback', inputs:{}, tasks:{}, packages:[]};",
        "export default {name:Symbol('secret'), inputs:{}, tasks:{}, packages:[]};",
        "const p={name:'cycle',inputs:{},tasks:{},packages:[]}; p.inputs.self=p; export default p;",
        "export default {get name(){while(true){}}, inputs:{}, tasks:{}, packages:[]};",
        "const p=Object.assign(Object.create({trick:1}),{name:'prototype',inputs:{},tasks:{},packages:[]}); export default p;",
        "const p=Object.assign(Object.create(null),{name:'prototype',inputs:{},tasks:{},packages:[]}); export default p;",
        "export default new Promise(()=>{});",
        "export default Promise.resolve({name:'resolved',inputs:{},tasks:{},packages:[]});",
        "export default new Proxy({name:'proxy',inputs:{},tasks:{},packages:[]},{ownKeys(){while(true){}},getPrototypeOf(){while(true){}}});",
        "const p={name:'symbol-key',inputs:{},tasks:{},packages:[]}; p[Symbol('hidden')]=1; export default p;",
        "const p={name:'hidden',inputs:{},tasks:{},packages:[]}; Object.defineProperty(p,'hidden',{get(){while(true){}}}); export default p;",
        "export default {name:'json',inputs:{},tasks:{},packages:[],toJSON(){while(true){}}};",
        "export default {name:'float',inputs:{x:1.5},tasks:{},packages:[]};",
        "export default {name:'negative-zero',inputs:{x:-0},tasks:{},packages:[]};",
        "export default {name:'unsafe',inputs:{x:9007199254740992},tasks:{},packages:[]};",
        "export default {name:'\\ud800',inputs:{},tasks:{},packages:[]};",
        "await new Promise(()=>{}); export default {name:'pending',inputs:{},tasks:{},packages:[]};",
        "const p={name:'class',inputs:new Uint8Array(1),tasks:{},packages:[]}; Object.setPrototypeOf(p.inputs,Object.prototype); export default p;",
    };
    for (rejected) |source| try expectRejected(error.ActiveValue, run(source, fixture.options(), null));
    try expectRejected(error.InvalidDeclaration, run("export default {name:42,inputs:{},tasks:{},packages:[]};", fixture.options(), null));
    const recovery = try run(plain, fixture.options(), null); defer recovery.deinit(gpa);
    try expectName(recovery, "plain");
}

test "m04/EVAL-010 refuse real untrusted engine bytecode" {
    std.debug.print("JCKG_EVIDENCE EVAL-010\n", .{});
    var fixture = try Fixture.init(); defer fixture.deinit();
    const c = engine.c;
    const runtime = c.JS_NewRuntime() orelse return error.OutOfMemory; defer c.JS_FreeRuntime(runtime);
    const ctx = c.JS_NewContext(runtime) orelse return error.OutOfMemory; defer c.JS_FreeContext(ctx);
    const compiled = c.JS_Eval(ctx, plain, plain.len, "config.ts", c.JS_EVAL_TYPE_MODULE | c.JS_EVAL_FLAG_COMPILE_ONLY); defer c.JS_FreeValue(ctx, compiled);
    try std.testing.expect(!c.JS_IsException(compiled));
    var size: usize = 0;
    const bytes = c.JS_WriteObject(ctx, &size, compiled, c.JS_WRITE_OBJ_BYTECODE);
    try std.testing.expect(bytes != null);
    if (bytes == null) return error.OutOfMemory;
    defer c.js_free(ctx, bytes);
    try std.testing.expect(size > 5);
    var options = fixture.options(); options.tools.transformer = null;
    try expectRejected(error.UntrustedBytecode, run(bytes[0..size], options, null));
    try expectRejected(error.UntrustedBytecode, run("QJBC\x00untrusted", options, null));
    const recovery = try run(plain, fixture.options(), null); defer recovery.deinit(gpa);
    try expectName(recovery, "plain");
}

test "m04/EVAL-011 key cache by engine transformer options and sources" {
    std.debug.print("JCKG_EVIDENCE EVAL-011\n", .{});
    var fixture = try Fixture.init(); defer fixture.deinit();
    var cache = eval.Cache.init(gpa); defer cache.deinit();
    const initial = try run(plain, fixture.options(), &cache); defer initial.deinit(gpa);
    try std.testing.expect(!initial.cache_hit);
    const hit = try run(plain, fixture.options(), &cache); defer hit.deinit(gpa);
    try std.testing.expect(hit.cache_hit);
    try std.testing.expectEqualStrings(initial.canonical_plan, hit.canonical_plan);
    var options = fixture.options(); options.target = .es2019;
    const option_miss = try run(plain, options, &cache); defer option_miss.deinit(gpa);
    try std.testing.expect(!option_miss.cache_hit);
    const source_miss = try run("export default {name:'new-source',inputs:{},tasks:{},packages:[]};", fixture.options(), &cache); defer source_miss.deinit(gpa);
    try std.testing.expect(!source_miss.cache_hit);
    try expectName(source_miss, "new-source");
    const snapshots: []const eval.Snapshot = &.{.{ .name = "config.ts", .source = plain, .digest = digest.ofBlob(plain) }};
    const key = eval.cacheKey(engine.identity, snapshots, fixture.options(), "{}");
    try std.testing.expect(!key.eql(eval.cacheKey("quickjs-ng/a-different-locked-engine", snapshots, fixture.options(), "{}")));
    options = fixture.options();
    var transformer = options.tools.transformer orelse return error.TransformerUnavailable;
    transformer.identity = "esbuild/a-different-version"; options.tools.transformer = transformer;
    try std.testing.expect(!key.eql(eval.cacheKey(engine.identity, snapshots, options, "{}")));
    transformer.sha256 = digest.ofBlob("different binary"); options.tools.transformer = transformer;
    try std.testing.expect(!key.eql(eval.cacheKey(engine.identity, snapshots, options, "{}")));
    options = fixture.options(); options.require_type_check = true;
    try std.testing.expect(!key.eql(eval.cacheKey(engine.identity, snapshots, options, "{}")));
    options = fixture.options(); options.limits.heap_bytes += 1;
    try std.testing.expect(!key.eql(eval.cacheKey(engine.identity, snapshots, options, "{}")));
    try std.testing.expect(!key.eql(eval.cacheKey(engine.identity, snapshots, fixture.options(), "{\"declared\":1}")));
    options = fixture.options();
    transformer = options.tools.transformer orelse return error.TransformerUnavailable;
    transformer.sha256 = digest.ofBlob("tampered tool"); options.tools.transformer = transformer;
    try expectRejected(error.ToolIntegrityMismatch, run(plain, options, &cache));
}
