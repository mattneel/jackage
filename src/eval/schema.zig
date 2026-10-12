//! Validation of the pure authoring SDK's Project contract after inert extraction.
const std = @import("std");
const canonical = @import("../core/canonical.zig");
const Value = canonical.Value;
pub const Error = error{InvalidDeclaration};

pub fn get(value: Value, key: []const u8) ?Value {
    if (value != .object) return null;
    for (value.object) |entry| if (std.mem.eql(u8, key, entry.key)) return entry.value;
    return null;
}
fn field(value: Value, key: []const u8) Error!Value { return get(value, key) orelse error.InvalidDeclaration; }
fn text(value: Value) Error![]const u8 { if (value != .string or value.string.len == 0) return error.InvalidDeclaration; return value.string; }
fn fields(value: Value, allowed: []const []const u8) Error!void {
    if (value != .object or value.object.len != allowed.len) return error.InvalidDeclaration;
    for (value.object) |entry| {
        for (allowed) |key| { if (std.mem.eql(u8, key, entry.key)) break; } else return error.InvalidDeclaration;
    }
}
fn strings(value: Value) Error!void {
    if (value != .array) return error.InvalidDeclaration;
    for (value.array) |item| if (item != .string) return error.InvalidDeclaration;
}
fn member(value: Value, choices: []const []const u8) Error!void {
    const word = try text(value);
    for (choices) |choice| if (std.mem.eql(u8, word, choice)) return;
    return error.InvalidDeclaration;
}
const platforms: []const []const u8 = &.{ "windows-x86_64", "windows-aarch64", "linux-x86_64", "linux-aarch64", "macos-x86_64", "macos-aarch64" };

pub fn validate(value: Value) Error!void {
    try fields(value, &.{ "name", "inputs", "tasks", "packages" });
    _ = try text(try field(value, "name"));
    const inputs = try field(value, "inputs");
    if (inputs != .object) return error.InvalidDeclaration;
    for (inputs.object) |entry| {
        if (entry.key.len == 0) return error.InvalidDeclaration;
        const kind = try text(try field(entry.value, "kind"));
        if (std.mem.eql(u8, kind, "locked")) {
            try fields(entry.value, &.{ "kind", "name" });
            _ = try text(try field(entry.value, "name"));
        } else if (std.mem.eql(u8, kind, "source")) {
            try fields(entry.value, &.{ "kind", "root", "include", "exclude" });
            _ = try text(try field(entry.value, "root"));
            try strings(try field(entry.value, "include"));
            try strings(try field(entry.value, "exclude"));
        } else return error.InvalidDeclaration;
    }
    const tasks = try field(value, "tasks");
    if (tasks != .object) return error.InvalidDeclaration;
    for (tasks.object) |entry| {
        if (entry.key.len == 0) return error.InvalidDeclaration;
        const task = entry.value;
        try fields(task, &.{ "tool", "args", "inputs", "outputs", "policy", "execution", "output" });
        const tool = try field(task, "tool");
        try fields(tool, &.{ "input", "path" });
        const input = try text(try field(tool, "input"));
        if (get(inputs, input) == null) return error.InvalidDeclaration;
        _ = try text(try field(tool, "path"));
        try strings(try field(task, "args"));
        const task_inputs = try field(task, "inputs");
        try strings(task_inputs);
        for (task_inputs.array) |item| if (get(inputs, item.string) == null) return error.InvalidDeclaration;
        try strings(try field(task, "outputs"));
        try member(try field(task, "policy"), &.{ "development", "release" });
        try member(try field(task, "execution"), platforms);
        try member(try field(task, "output"), platforms);
    }
    const packages = try field(value, "packages");
    if (packages != .array) return error.InvalidDeclaration;
    for (packages.array) |package| {
        try fields(package, &.{ "task", "formats" });
        const task = try text(try field(package, "task"));
        if (get(tasks, task) == null) return error.InvalidDeclaration;
        const formats = try field(package, "formats");
        if (formats != .array or formats.array.len == 0) return error.InvalidDeclaration;
        for (formats.array) |format| try member(format, &.{ "zip", "tar", "oci", "deb", "rpm", "msix", "pkg", "ext4", "vhdx" });
    }
}
