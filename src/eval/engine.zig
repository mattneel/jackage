//! Source-only QuickJS-NG execution. The C allocator is backed by the caller's
//! allocator, so normal ownership/leak checks include every VM allocation.
const std = @import("std");
const canonical = @import("../core/canonical.zig");
// @cImport was removed in the pinned compiler; these are its translate-c output.
pub const c = @import("quickjs");
pub const identity = "quickjs-ng/0.17.0/source-sha256:559bc4c420475e55c7ab4510adbc562f55d7524d75e8e89d79ce4bb02f5687d9";

pub const Limits = struct {
    heap_bytes: usize = 16 * 1024 * 1024,
    stack_bytes: usize = 256 * 1024,
    deadline_ms: u32 = 250,
    max_modules: usize = 64,
    max_source_bytes: usize = 1024 * 1024,
    max_nodes: usize = 100_000,
};
pub const Module = struct { name: [:0]const u8, javascript: [:0]const u8 };
pub const Error = error{ OutOfMemory, ResourceLimit, DeadlineExceeded, ModuleDenied, EvaluationFailed, ActiveValue, InvalidSource, UntrustedBytecode };

/// QuickJS-NG v0.17 serializes BC_VERSION (28) first. Reject binary/control
/// input rather than ever invoking JS_ReadObject; this API accepts source only.
pub fn validateSource(source: []const u8) Error!void {
    if (std.mem.startsWith(u8, source, "QJBC") or (source.len > 0 and source[0] == 28)) return error.UntrustedBytecode;
    for (source) |byte| if (byte < 32 and byte != '\t' and byte != '\n' and byte != '\r') return error.UntrustedBytecode;
    if (!std.unicode.utf8ValidateSlice(source)) return error.InvalidSource;
}

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '/' or name[0] == '.' or std.mem.indexOfAny(u8, name, "\\:\x00?#") != null) return false;
    var parts = std.mem.splitScalar(u8, name, '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    return true;
}

const Memory = struct {
    gpa: std.mem.Allocator,
    limit: usize,
    live: usize = 0,
    failed: bool = false,

    /// Per-allocation header: the requested size, so a free can account for the
    /// total block that was really allocated.
    const header_size = 16;

    fn fromOpaque(context: ?*anyopaque) *Memory { return @ptrCast(@alignCast(context)); }
    fn allocation(ptr: *const anyopaque) []align(16) u8 {
        const bytes: [*]align(16) u8 = @ptrFromInt(@intFromPtr(ptr) - header_size);
        const size: *const usize = @ptrCast(bytes);
        return bytes[0..size.* + header_size];
    }
    fn malloc(context: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
        const self = fromOpaque(context);
        const total = std.math.add(usize, size, header_size) catch { self.failed = true; return null; };
        if (total > self.limit -| self.live) { self.failed = true; return null; }
        const bytes = self.gpa.alignedAlloc(u8, .@"16", total) catch { self.failed = true; return null; };
        const header: *usize = @ptrCast(bytes.ptr);
        header.* = size;
        self.live += total;
        return bytes.ptr + header_size;
    }
    fn calloc(context: ?*anyopaque, count: usize, size: usize) callconv(.c) ?*anyopaque {
        const total = std.math.mul(usize, count, size) catch { fromOpaque(context).failed = true; return null; };
        const ptr = malloc(context, total) orelse return null;
        @memset(@as([*]u8, @ptrCast(ptr))[0..total], 0);
        return ptr;
    }
    fn free(context: ?*anyopaque, ptr: ?*anyopaque) callconv(.c) void {
        const actual = ptr orelse return;
        const self = fromOpaque(context);
        const bytes = allocation(actual);
        self.live -= bytes.len;
        self.gpa.free(bytes);
    }
    fn realloc(context: ?*anyopaque, ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
        const actual = ptr orelse return malloc(context, size);
        if (size == 0) { free(context, actual); return null; }
        const self = fromOpaque(context);
        const old = allocation(actual);
        const total = std.math.add(usize, size, header_size) catch { self.failed = true; return null; };
        if (total > self.limit -| (self.live - old.len)) { self.failed = true; return null; }
        const bytes = self.gpa.realloc(old, total) catch { self.failed = true; return null; };
        self.live = self.live - old.len + total;
        @as(*usize, @ptrCast(bytes.ptr)).* = size;
        return bytes.ptr + header_size;
    }
    fn usable(ptr: ?*const anyopaque) callconv(.c) usize { return if (ptr) |actual| allocation(actual).len - header_size else 0; }
    const callbacks: c.JSMallocFunctions = .{ .js_calloc = calloc, .js_malloc = malloc, .js_free = free, .js_realloc = realloc, .js_malloc_usable_size = usable };
};

const State = struct {
    io: std.Io,
    deadline: i96,
    modules: []const Module,
    memory: *Memory,
    timed_out: bool = false,
    denied: bool = false,
    fn fromOpaque(context: ?*anyopaque) *State { return @ptrCast(@alignCast(context)); }
    fn interrupt(_: ?*c.JSRuntime, context: ?*anyopaque) callconv(.c) c_int {
        const self = fromOpaque(context);
        if (std.Io.Timestamp.now(self.io, .awake).nanoseconds >= self.deadline) {
            self.timed_out = true;
            return 1;
        }
        return 0;
    }
    fn failure(self: *State) Error {
        if (self.timed_out) return error.DeadlineExceeded;
        if (self.denied) return error.ModuleDenied;
        if (self.memory.failed) return error.ResourceLimit;
        return error.EvaluationFailed;
    }
    fn deny(self: *State, ctx: ?*c.JSContext) [*c]u8 {
        self.denied = true;
        _ = c.JS_ThrowTypeError(ctx, "undeclared or forbidden module import");
        return null;
    }
    // This resolver does no I/O. It can name only an already supplied module.
    fn normalize(ctx: ?*c.JSContext, base_c: [*c]const u8, spec_c: [*c]const u8, context: ?*anyopaque) callconv(.c) [*c]u8 {
        const self = fromOpaque(context);
        const base = std.mem.span(base_c);
        const spec = std.mem.span(spec_c);
        if (spec.len == 0 or spec[0] == '/' or std.mem.indexOfAny(u8, spec, "\\:\x00?#") != null) return self.deny(ctx);
        var buffer: [4096]u8 = undefined;
        const resolved: []const u8 = if (std.mem.startsWith(u8, spec, "./")) blk: {
            const slash = std.mem.lastIndexOfScalar(u8, base, '/');
            const dir = if (slash) |at| base[0 .. at + 1] else "";
            if (dir.len + spec.len - 2 > buffer.len) return self.deny(ctx);
            @memcpy(buffer[0..dir.len], dir);
            @memcpy(buffer[dir.len..][0 .. spec.len - 2], spec[2..]);
            break :blk buffer[0 .. dir.len + spec.len - 2];
        } else spec;
        if (!validName(resolved)) return self.deny(ctx);
        for (self.modules) |module| if (std.mem.eql(u8, module.name, resolved)) return c.js_strndup(ctx, module.name.ptr, module.name.len);
        return self.deny(ctx);
    }
    fn load(ctx: ?*c.JSContext, name_c: [*c]const u8, context: ?*anyopaque) callconv(.c) ?*c.JSModuleDef {
        const self = fromOpaque(context);
        const name = std.mem.span(name_c);
        for (self.modules) |module| {
            if (!std.mem.eql(u8, name, module.name)) continue;
            const value = c.JS_Eval(ctx, module.javascript.ptr, module.javascript.len, module.name.ptr, c.JS_EVAL_TYPE_MODULE | c.JS_EVAL_FLAG_COMPILE_ONLY);
            if (c.JS_IsException(value)) return null;
            // QuickJS owns the compiled module through its runtime module list.
            return @ptrCast(c.JS_VALUE_GET_PTR(value));
        }
        _ = self.deny(ctx);
        return null;
    }
};

const sandbox_source =
    \\Object.defineProperty(globalThis, 'Date', {value: undefined, writable: false, configurable: false});
    \\Object.defineProperty(globalThis, 'performance', {value: undefined, writable: false, configurable: false});
    \\Object.defineProperty(Math, 'random', {value: undefined});
    \\Object.freeze(Math);
    \\Object.freeze(JSON);
    \\Object.defineProperty(globalThis, 'JSON', {value: JSON, writable: false, configurable: false});
    \\Object.defineProperty(Number.prototype, 'toLocaleString', {value: undefined});
    \\Object.defineProperty(String.prototype, 'toLocaleLowerCase', {value: undefined});
    \\Object.defineProperty(String.prototype, 'toLocaleUpperCase', {value: undefined});
    \\Object.defineProperty(Array.prototype, 'toLocaleString', {value: undefined});
    \\Object.freeze(Object.prototype); Object.freeze(Array.prototype);
;

fn freeDescriptor(ctx: *c.JSContext, desc: c.JSPropertyDescriptor) void {
    c.JS_FreeValue(ctx, desc.value); c.JS_FreeValue(ctx, desc.getter); c.JS_FreeValue(ctx, desc.setter);
}
fn dataDescriptor(ctx: *c.JSContext, value: c.JSValue, atom: c.JSAtom) Error!c.JSPropertyDescriptor {
    var desc: c.JSPropertyDescriptor = undefined;
    if (c.JS_GetOwnProperty(ctx, &desc, value, atom) != 1) return error.ActiveValue;
    if ((desc.flags & c.JS_PROP_TMASK) == c.JS_PROP_GETSET or !c.JS_IsUndefined(desc.getter) or !c.JS_IsUndefined(desc.setter)) {
        freeDescriptor(ctx, desc);
        return error.ActiveValue;
    }
    return desc;
}

const Extractor = struct {
    gpa: std.mem.Allocator,
    ctx: *c.JSContext,
    object_proto: c.JSValue,
    array_proto: c.JSValue,
    object_class: c.JSClassID,
    state: *State,
    nodes_left: usize,
    ancestors: [128]?*anyopaque = undefined,
    fn string(self: *Extractor, value: c.JSValue) Error![]u8 {
        var utf16_len: usize = 0;
        const utf16 = c.JS_ToCStringLenUTF16(self.ctx, &utf16_len, value);
        if (utf16 == null) return self.state.failure();
        defer c.JS_FreeCStringUTF16(self.ctx, utf16);
        var index: usize = 0;
        while (index < utf16_len) : (index += 1) {
            if (utf16[index] >= 0xd800 and utf16[index] <= 0xdbff) {
                index += 1;
                if (index >= utf16_len or utf16[index] < 0xdc00 or utf16[index] > 0xdfff) return error.ActiveValue;
            } else if (utf16[index] >= 0xdc00 and utf16[index] <= 0xdfff) return error.ActiveValue;
        }
        var len: usize = 0;
        const text = c.JS_ToCStringLen(self.ctx, &len, value);
        if (text == null) return self.state.failure();
        defer c.JS_FreeCString(self.ctx, text);
        return self.gpa.dupe(u8, text[0..len]);
    }
    fn extract(self: *Extractor, value: c.JSValue, depth: usize) Error!canonical.Value {
        if (depth >= self.ancestors.len or self.nodes_left == 0) return error.ResourceLimit;
        if (State.interrupt(null, self.state) != 0) return error.DeadlineExceeded;
        self.nodes_left -= 1;
        if (c.JS_IsNull(value)) return .null;
        if (c.JS_IsBool(value)) return .{ .boolean = c.JS_ToBool(self.ctx, value) == 1 };
        if (c.JS_IsNumber(value)) {
            var number: f64 = 0;
            if (c.JS_ToFloat64(self.ctx, &number, value) != 0) return self.state.failure();
            if (!std.math.isFinite(number) or @trunc(number) != number or @abs(number) > @as(f64, @floatFromInt(canonical.max_safe_integer)) or (number == 0 and std.math.signbit(number))) return error.ActiveValue;
            return .{ .integer = @intFromFloat(number) };
        }
        if (c.JS_IsString(value)) return .{ .string = try self.string(value) };
        if (!c.JS_IsObject(value) or c.JS_IsProxy(value) or c.JS_IsFunction(self.ctx, value) or c.JS_IsPromise(value)) return error.ActiveValue;
        const ptr = c.JS_VALUE_GET_PTR(value);
        for (self.ancestors[0..depth]) |ancestor| if (ancestor == ptr) return error.ActiveValue;
        self.ancestors[depth] = ptr;
        const is_array = c.JS_IsArray(value);
        if (!is_array and c.JS_GetClassID(value) != self.object_class) return error.ActiveValue;
        const proto = c.JS_GetPrototype(self.ctx, value);
        defer c.JS_FreeValue(self.ctx, proto);
        const expected = if (is_array) self.array_proto else self.object_proto;
        if (!c.JS_IsObject(proto) or c.JS_VALUE_GET_PTR(proto) != c.JS_VALUE_GET_PTR(expected)) return error.ActiveValue;
        var props: [*c]c.JSPropertyEnum = null;
        var count: u32 = 0;
        if (c.JS_GetOwnPropertyNames(self.ctx, &props, &count, value, c.JS_GPN_STRING_MASK | c.JS_GPN_SYMBOL_MASK) != 0) return self.state.failure();
        defer c.JS_FreePropertyEnum(self.ctx, props, count);
        if (count > self.nodes_left + 1) return error.ResourceLimit;
        if (is_array) {
            const atom = c.JS_NewAtom(self.ctx, "length");
            defer c.JS_FreeAtom(self.ctx, atom);
            const length_desc = try dataDescriptor(self.ctx, value, atom);
            defer freeDescriptor(self.ctx, length_desc);
            var length: i64 = 0;
            if (!c.JS_IsNumber(length_desc.value) or c.JS_ToInt64(self.ctx, &length, length_desc.value) != 0 or length < 0 or length > self.nodes_left) return error.ResourceLimit;
            if (@as(u64, @intCast(length)) + 1 != count) return error.ActiveValue;
            const items = try self.gpa.alloc(canonical.Value, @intCast(length));
            var filled: usize = 0;
            errdefer { for (items[0..filled]) |item| item.deinit(self.gpa); self.gpa.free(items); }
            for (items, 0..) |*item, at| {
                const item_atom = c.JS_NewAtomUInt32(self.ctx, @intCast(at));
                defer c.JS_FreeAtom(self.ctx, item_atom);
                const desc = try dataDescriptor(self.ctx, value, item_atom);
                defer freeDescriptor(self.ctx, desc);
                item.* = try self.extract(desc.value, depth + 1);
                filled += 1;
            }
            return .{ .array = items };
        }
        const entries = try self.gpa.alloc(canonical.Entry, count);
        var filled: usize = 0;
        errdefer { for (entries[0..filled]) |entry| { self.gpa.free(entry.key); entry.value.deinit(self.gpa); } self.gpa.free(entries); }
        for (entries, 0..) |*entry, at| {
            const key_value = c.JS_AtomToValue(self.ctx, props[at].atom);
            defer c.JS_FreeValue(self.ctx, key_value);
            if (!c.JS_IsString(key_value)) return error.ActiveValue;
            const desc = try dataDescriptor(self.ctx, value, props[at].atom);
            defer freeDescriptor(self.ctx, desc);
            if (desc.flags & c.JS_PROP_ENUMERABLE == 0) return error.ActiveValue;
            const key = try self.string(key_value);
            errdefer self.gpa.free(key);
            if (std.mem.eql(u8, key, "__proto__") or std.mem.eql(u8, key, "prototype") or std.mem.eql(u8, key, "constructor")) return error.ActiveValue;
            entry.* = .{ .key = key, .value = try self.extract(desc.value, depth + 1) };
            filled += 1;
        }
        return .{ .object = entries };
    }
};

pub fn evaluate(gpa: std.mem.Allocator, io: std.Io, modules: []const Module, entry: []const u8, limits: Limits) Error!canonical.Value {
    if (modules.len == 0 or modules.len > limits.max_modules or limits.deadline_ms == 0 or limits.heap_bytes == 0 or limits.stack_bytes == 0) return error.ResourceLimit;
    var total: usize = 0;
    for (modules, 0..) |module, at| {
        if (!validName(module.name)) return error.ModuleDenied;
        try validateSource(module.javascript);
        total = std.math.add(usize, total, module.javascript.len) catch return error.ResourceLimit;
        if (total > limits.max_source_bytes) return error.ResourceLimit;
        for (modules[0..at]) |previous| if (std.mem.eql(u8, previous.name, module.name)) return error.ModuleDenied;
    }
    var memory: Memory = .{ .gpa = gpa, .limit = limits.heap_bytes };
    const runtime = c.JS_NewRuntime2(&Memory.callbacks, &memory) orelse return error.ResourceLimit;
    defer c.JS_FreeRuntime(runtime);
    // The allocator enforces the exact live-byte ceiling including headers and
    // runtime setup. It also records failures that scripts could otherwise catch.
    c.JS_SetMaxStackSize(runtime, limits.stack_bytes);
    c.JS_SetCanBlock(runtime, false);
    var state: State = .{ .io = io, .deadline = std.Io.Timestamp.now(io, .awake).nanoseconds + @as(i96, limits.deadline_ms) * std.time.ns_per_ms, .modules = modules, .memory = &memory };
    c.JS_SetInterruptHandler(runtime, State.interrupt, &state);
    c.JS_SetModuleLoaderFunc(runtime, State.normalize, State.load, &state);
    const ctx = c.JS_NewContext(runtime) orelse return state.failure();
    defer c.JS_FreeContext(ctx);
    const setup = c.JS_Eval(ctx, sandbox_source, sandbox_source.len, "jackage-sandbox", c.JS_EVAL_TYPE_GLOBAL);
    defer c.JS_FreeValue(ctx, setup);
    if (c.JS_IsException(setup)) return state.failure();
    const object = c.JS_NewObject(ctx);
    defer c.JS_FreeValue(ctx, object);
    const array = c.JS_NewArray(ctx);
    defer c.JS_FreeValue(ctx, array);
    if (c.JS_IsException(object) or c.JS_IsException(array)) return state.failure();
    const object_proto = c.JS_GetPrototype(ctx, object);
    defer c.JS_FreeValue(ctx, object_proto);
    const array_proto = c.JS_GetPrototype(ctx, array);
    defer c.JS_FreeValue(ctx, array_proto);
    for (modules) |module| {
        if (!std.mem.eql(u8, module.name, entry)) continue;
        const compiled = c.JS_Eval(ctx, module.javascript.ptr, module.javascript.len, module.name.ptr, c.JS_EVAL_TYPE_MODULE | c.JS_EVAL_FLAG_COMPILE_ONLY);
        if (c.JS_IsException(compiled)) return state.failure();
        const module_ptr: *c.JSModuleDef = @ptrCast(c.JS_VALUE_GET_PTR(compiled));
        const completion = c.JS_EvalFunction(ctx, compiled);
        defer c.JS_FreeValue(ctx, completion);
        if (c.JS_IsException(completion)) return state.failure();
        // Jobs are evaluation, not extraction: resolve dynamic imports through
        // the same locked map and enforce the deadline even on microtask loops.
        while (c.JS_IsJobPending(runtime)) {
            if (State.interrupt(runtime, &state) != 0) return state.failure();
            var job_context: ?*c.JSContext = null;
            if (c.JS_ExecutePendingJob(runtime, &job_context) < 0) return state.failure();
            if (state.denied or memory.failed) return state.failure();
        }
        if (c.JS_IsPromise(completion)) switch (c.JS_PromiseState(ctx, completion)) {
            c.JS_PROMISE_PENDING => return error.ActiveValue,
            c.JS_PROMISE_REJECTED => return state.failure(),
            else => {},
        };
        if (state.timed_out or memory.failed or state.denied) return state.failure();
        const namespace = c.JS_GetModuleNamespace(ctx, module_ptr);
        defer c.JS_FreeValue(ctx, namespace);
        if (c.JS_IsException(namespace)) return state.failure();
        const value = c.JS_GetPropertyStr(ctx, namespace, "default");
        defer c.JS_FreeValue(ctx, value);
        if (c.JS_IsException(value)) return state.failure();
        var extractor: Extractor = .{ .gpa = gpa, .ctx = ctx, .object_proto = object_proto, .array_proto = array_proto, .object_class = c.JS_GetClassID(object), .state = &state, .nodes_left = limits.max_nodes };
        var result = try extractor.extract(value, 0);
        canonical.canonicalize(&result);
        return result;
    }
    return error.ModuleDenied;
}
