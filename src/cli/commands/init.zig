//! `jckg init` — create project declarations without clobbering files
//! (cases CLI-006, CLI-007).
//!
//! Existing files are never overwritten silently: a conflict is reported and
//! nothing changes. Replacing a declaration is a destructive local action, so
//! it needs either a terminal or an explicit `--yes`, and a non-interactive
//! caller without it gets a policy error instead of a prompt or an overwrite.
const std = @import("std");
const context = @import("../context.zig");
const args = @import("../args.zig");
const exit_code = @import("../exit.zig");
const policy = @import("../../core/policy.zig");

pub const declaration_name = "jackage.ts";

/// Written only when the file does not exist (or an authorized replacement was
/// requested). `locked(...)` inputs are deliberately absent: this template
/// invents no pins.
pub const declaration_template =
    \\// Jackage project declaration.
    \\//
    \\// The "jackage" module is a builtin authoring SDK supplied by the Jackage
    \\// evaluator; it is not an npm package. Declarations are data: the evaluator
    \\// sees no filesystem, process, or network API.
    \\import { defineProject, source } from "jackage";
    \\
    \\export default defineProject({
    \\  name: "PROJECT_NAME",
    \\  inputs: {
    \\    src: source({
    \\      root: ".",
    \\      include: ["src/**", "build.zig", "build.zig.zon", "scripts/**"],
    \\      exclude: [".git/**", ".zig-cache/**", "zig-out/**", ".jackage/**", ".env*"],
    \\    }),
    \\  },
    \\  // Tasks and packages are added once their tools are declared as inputs.
    \\  tasks: {},
    \\  packages: [],
    \\});
    \\
;

pub const Action = enum {
    created,
    unchanged,
    replaced,
    conflicted,
    denied,

    pub fn text(self: Action) []const u8 {
        return switch (self) {
            .created => "created",
            .unchanged => "unchanged",
            .replaced => "replaced",
            .conflicted => "conflicted",
            .denied => "denied",
        };
    }
};

pub const Report = struct {
    directory: []const u8,
    file: []const u8,
    action: Action,
    message: []const u8,
};

pub fn run(ctx: *context.Context, invocation: args.Invocation) !exit_code.Code {
    const emitter = ctx.emitter(invocation.json);
    const directory_path = invocation.directory orelse ".";
    const dir = if (invocation.directory) |path| blk: {
        // `jckg init --directory <new>` is the documented way to start a
        // project, so the directory is created when it does not exist yet.
        // Creating it is idempotent and never touches existing files.
        ctx.cwd.createDirPath(ctx.io, path) catch {};
        break :blk ctx.cwd.openDir(ctx.io, path, .{}) catch {
            try emitter.errorReport(
                .infrastructure,
                "cannot open the target directory",
                "the directory could not be created or is not readable",
            );
            return .infrastructure;
        };
    } else ctx.cwd;
    defer if (invocation.directory != null) dir.close(ctx.io);

    const exists = if (dir.statFile(ctx.io, declaration_name, .{})) |_| true else |_| false;

    if (exists and !invocation.force) {
        try emitter.jsonLine(.{
            .schemaVersion = 1,
            .kind = "init",
            .status = "conflict",
            .directory = directory_path,
            .files = &.{.{ .path = declaration_name, .action = Action.conflicted.text() }},
            .message = "the declaration already exists; nothing was changed",
        });
        try emitter.human("{s} already exists; nothing was changed.\n", .{declaration_name});
        try emitter.human("Re-run with --force to replace it (that needs --yes or a terminal).\n", .{});
        return .policy;
    }

    if (exists and invocation.force) {
        const request = policy.Request{
            .kind = .project_file_replacement,
            .description = "replace " ++ declaration_name,
        };
        switch (policy.decide(.{ .interactive = ctx.interactive, .assume_yes = invocation.assume_yes }, request)) {
            .approved => {},
            .would_prompt => {},
            .denied => |reason| {
                const message = try policy.describeDenial(ctx.gpa, request, reason);
                defer ctx.gpa.free(message);
                try emitter.jsonLine(.{
                    .schemaVersion = 1,
                    .kind = "init",
                    .status = "denied",
                    .directory = directory_path,
                    .files = &.{.{ .path = declaration_name, .action = Action.denied.text() }},
                });
                try emitter.errorReport(.policy, message, "nothing was changed");
                return .policy;
            },
        }
    }

    const project_name = std.fs.path.basename(std.fs.path.resolve(ctx.gpa, &.{directory_path}) catch directory_path);
    const content = try renderDeclaration(ctx.gpa, project_name);
    defer ctx.gpa.free(content);

    dir.writeFile(ctx.io, .{ .sub_path = declaration_name, .data = content }) catch {
        try emitter.errorReport(.infrastructure, "cannot write the declaration", "the file could not be written");
        return .infrastructure;
    };

    const action: Action = if (exists) .replaced else .created;
    try emitter.jsonLine(.{
        .schemaVersion = 1,
        .kind = "init",
        .status = action.text(),
        .directory = directory_path,
        .files = &.{.{ .path = declaration_name, .action = action.text() }},
    });
    try emitter.human("{s} {s}\n", .{ declaration_name, action.text() });
    return .success;
}

/// Fills the template in with the project name derived from the target
/// directory. Only the placeholder is substituted; nothing else is rewritten.
pub fn renderDeclaration(gpa: std.mem.Allocator, project_name: []const u8) ![]u8 {
    const placeholder = "PROJECT_NAME";
    const position = std.mem.indexOf(u8, declaration_template, placeholder) orelse return gpa.dupe(u8, declaration_template);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.writeAll(declaration_template[0..position]);
    try out.writer.writeAll(project_name);
    try out.writer.writeAll(declaration_template[position + placeholder.len ..]);
    return out.toOwnedSlice();
}
