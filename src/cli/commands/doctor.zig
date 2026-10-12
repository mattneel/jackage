//! `jckg doctor` — host, toolchain, audit, and capability report (cases
//! CLI-003, CLI-008, CLI-009, CLI-010).
//!
//! The report states what the machine is, what the pinned toolchain is, what
//! the checkout's audit found, and which capabilities a backend actually
//! enforces. Anything the command could not observe is named as unavailable
//! rather than omitted, and capabilities that are not enforced are printed as
//! `unavailable` with a release-blocking count.
const std = @import("std");
const context = @import("../context.zig");
const args = @import("../args.zig");
const exit_code = @import("../exit.zig");
const console = @import("../console.zig");
const cancel = @import("../../core/cancel.zig");
const capabilities = @import("../../core/capabilities.zig");
const exec = @import("../../exec/mod.zig");
const version = @import("../../core/version.zig");
const audit = @import("../../audit/mod.zig");
const redact = @import("../../core/redact.zig");

const CapabilityDocument = struct {
    name: []const u8,
    status: []const u8,
    evidence: []const u8,
    blocksRelease: bool,
};

pub const Report = struct {
    identity: version.BuildIdentity,
    host: audit.host.HostFacts,
    /// Pin text recorded in `.zigversion`, or null when it is not readable.
    recorded_pin: ?[]const u8,
    wrapper_present: bool,
    sources: audit.inventory.Inventory,
    inputs: audit.provenance.Provenance,
    protected_files_verified: bool,
    backend: capabilities.Backend,
    console_handler: bool,
    stdin_trigger: bool,
    repository_display: ?[]const u8,
    /// Names of the checkout inputs this observation could not read.
    degraded: ?[]const u8,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Report) void {
        version.deinitIdentity(self.gpa, self.identity);
        self.host.deinit();
        if (self.recorded_pin) |text| self.gpa.free(text);
        self.sources.deinit();
        self.inputs.deinit();
        if (self.repository_display) |display| self.gpa.free(display);
        if (self.degraded) |text| self.gpa.free(text);
        self.* = undefined;
    }

    /// Whether the compiler that built this binary is the pinned one. Null when
    /// the pin could not be read.
    pub fn pinMatches(self: Report) ?bool {
        const recorded = self.recorded_pin orelse return null;
        return std.mem.eql(u8, recorded, self.identity.build_zig_version);
    }
};

pub fn run(ctx: *context.Context, invocation: args.Invocation) !exit_code.Code {
    if (invocation.cancel_on_stdin and ctx.stdin == null) {
        const emitter = ctx.emitter(invocation.json);
        try emitter.errorReport(
            .usage,
            "--cancel-on-stdin needs a readable stdin, but none was supplied",
            "run the client with a pipe or redirected stdin",
        );
        return .usage;
    }

    if (invocation.watch) return watch(ctx, invocation);

    var report = try assemble(ctx, invocation);
    defer report.deinit();
    try writeReport(ctx, invocation, report, 0, false);
    return .success;
}

fn watch(ctx: *context.Context, invocation: args.Invocation) !exit_code.Code {
    const stdin_trigger = if (invocation.cancel_on_stdin) context.startStdinWatcher(ctx) else false;

    const io_local = ctx.io;
    const deadline_ns: ?u64 = if (invocation.deadline_ms) |milliseconds|
        milliseconds * std.time.ns_per_ms
    else
        null;

    const Stepper = struct {
        ctx: *context.Context,
        invocation: args.Invocation,
        stdin_trigger: bool,
        completed: u64 = 0,
        failure: ?exit_code.Code = null,

        fn step(self: *@This(), iteration: u64) bool {
            var report = assemble(self.ctx, self.invocation) catch {
                self.failure = .infrastructure;
                return false;
            };
            defer report.deinit();
            self.completed = iteration + 1;
            writeReport(self.ctx, self.invocation, report, iteration, self.stdin_trigger) catch {
                self.failure = .infrastructure;
                return false;
            };
            return true;
        }
    };

    var stepper = Stepper{ .ctx = ctx, .invocation = invocation, .stdin_trigger = stdin_trigger };
    const loop: cancel.Loop = .{
        .token = ctx.cancel_token,
        .clock = cancel.clockForIo(&io_local),
        .max_iterations = 1_000_000,
        .deadline_ns = deadline_ns,
    };
    const outcome = loop.run(&stepper, Stepper.step);
    if (stepper.failure) |code| return code;

    const emitter = ctx.emitter(invocation.json);
    try emitter.jsonLine(.{
        .schemaVersion = 1,
        .kind = "summary",
        .event = "summary",
        .status = if (outcome.stop == .canceled) "canceled" else "completed",
        .stopReason = switch (outcome.stop) {
            .completed => "iteration-limit",
            .canceled => if (stdin_trigger) "stdin" else "interrupt",
            .deadline => "deadline",
        },
        .reports = stepper.completed,
        .iterations = outcome.iterations,
        .elapsedMs = outcome.elapsed_ns / std.time.ns_per_ms,
    });
    try emitter.human("stopped after {d} reports ({s})\n", .{
        stepper.completed,
        switch (outcome.stop) {
            .completed => "iteration limit",
            .canceled => "canceled",
            .deadline => "deadline",
        },
    });
    return if (outcome.stop == .canceled) .canceled else .success;
}

fn assemble(ctx: *context.Context, invocation: args.Invocation) !Report {
    const identity = try version.buildIdentity(ctx.gpa);
    errdefer version.deinitIdentity(ctx.gpa, identity);

    const host_facts = try audit.host.detect(ctx.io, ctx.gpa);
    errdefer {
        var facts = host_facts;
        facts.deinit();
    }

    var degraded: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer degraded.deinit();

    const recorded_pin: ?[]const u8 = ctx.cwd.readFileAlloc(ctx.io, ".zigversion", ctx.gpa, .unlimited) catch null;
    errdefer if (recorded_pin) |text| ctx.gpa.free(text);
    if (recorded_pin == null) try degraded.writer.writeAll(" .zigversion");

    var sources = audit.inventory.scan(ctx.io, ctx.gpa, ctx.cwd, audit.source_root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => blk: {
            try degraded.writer.print(" {s}/", .{audit.source_root});
            break :blk try audit.inventory.empty(ctx.gpa);
        },
    };
    errdefer sources.deinit();

    var inputs = audit.provenance.inspect(ctx.io, ctx.gpa, ctx.cwd) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => blk: {
            try degraded.writer.writeAll(" build.zig.zon");
            break :blk try audit.provenance.empty(ctx.gpa);
        },
    };
    errdefer inputs.deinit();

    const protected_files_verified = verifyPreservation(ctx) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => blk: {
            try degraded.writer.writeAll(" preservation-record");
            break :blk false;
        },
    };

    const wrapper_present = if (ctx.cwd.statFile(ctx.io, "scripts/zig.ps1", .{})) |_| true else |_| false;
    if (!wrapper_present) try degraded.writer.writeAll(" scripts/zig.ps1");

    var repository_display: ?[]const u8 = null;
    errdefer if (repository_display) |display| ctx.gpa.free(display);
    if (invocation.repo) |url| repository_display = try redact.redactUrlAlloc(ctx.gpa, url);

    const notes = degraded.written();
    const degraded_text: ?[]const u8 = if (notes.len == 0) null else try ctx.gpa.dupe(u8, notes);

    return .{
        .identity = identity,
        .host = host_facts,
        .recorded_pin = if (recorded_pin) |text| try ctx.gpa.dupe(u8, std.mem.trim(u8, text, " \t\r\n")) else null,
        .wrapper_present = wrapper_present,
        .sources = sources,
        .inputs = inputs,
        .protected_files_verified = protected_files_verified,
        .backend = exec.nativeBackend(),
        .console_handler = console.isInstalled(),
        .stdin_trigger = ctx.stdin != null,
        .repository_display = repository_display,
        .degraded = degraded_text,
        .gpa = ctx.gpa,
    };
}

fn verifyPreservation(ctx: *context.Context) !bool {
    const text = try ctx.cwd.readFileAlloc(ctx.io, audit.manifest_path, ctx.gpa, .unlimited);
    defer ctx.gpa.free(text);
    var record = try audit.manifest.parse(ctx.gpa, text);
    defer record.deinit();
    audit.manifest.verify(ctx.io, ctx.cwd, record) catch return false;
    return true;
}

/// Renders a backend's measured capability table for the report.
///
/// A status is copied verbatim from the backend: the report must not look more
/// confident than the measurement is.
pub fn capabilityDocuments(gpa: std.mem.Allocator, backend: capabilities.Backend) ![]CapabilityDocument {
    const entries = try gpa.alloc(CapabilityDocument, backend.capabilities.len);
    for (backend.capabilities, 0..) |capability, index| {
        entries[index] = .{
            .name = capability.name,
            .status = capability.status.text(),
            .evidence = capability.evidence,
            .blocksRelease = capability.blocks_release,
        };
    }
    return entries;
}

fn writeReport(
    ctx: *context.Context,
    invocation: args.Invocation,
    report: Report,
    iteration: u64,
    stdin_trigger: bool,
) !void {
    const emitter = ctx.emitter(invocation.json);
    var target_buffer: [32]u8 = undefined;
    const target = report.host.target().format(&target_buffer);

    const entries = try capabilityDocuments(ctx.gpa, report.backend);
    defer ctx.gpa.free(entries);

    try emitter.jsonLine(.{
        .schemaVersion = 1,
        .kind = if (iteration == 0) "doctor" else "event",
        .event = if (iteration == 0) null else "doctor",
        .iteration = iteration,
        .identity = .{ .product = report.identity.product, .version = report.identity.version },
        .host = .{
            .os = report.host.os.text(),
            .architecture = report.host.arch.text(),
            .target = target,
            .logicalCpus = report.host.logical_cpus,
            .pageSizeMin = report.host.page_size_min,
            .pageSizeMax = report.host.page_size_max,
            .executable = report.host.executable_path,
        },
        .toolchain = .{
            .recorded = report.recorded_pin,
            .buildZigVersion = report.identity.build_zig_version,
            .matches = report.pinMatches(),
            .wrapperPresent = report.wrapper_present,
        },
        .source = .{
            .root = audit.source_root,
            .fileCount = report.sources.files.len,
            .testBlocks = report.sources.totalTestBlocks(),
        },
        .provenance = .{
            .dependencies = report.inputs.dependencyCount(),
            .projectLicense = report.inputs.project_license,
            .licenseFiles = report.inputs.license_files,
        },
        .preservation = .{ .recordVerified = report.protected_files_verified, .recordPath = audit.manifest_path },
        .repository = .{ .requested = report.repository_display },
        .cancellation = .{ .consoleHandler = report.console_handler, .stdinTrigger = stdin_trigger },
        .degraded = report.degraded,
        .capabilities = .{
            .backend = report.backend.name,
            .family = report.backend.family,
            .isolationBoundary = report.backend.isolation_boundary,
            .releaseBlocking = report.backend.releaseBlockingCount(),
            .entries = entries,
        },
    });

    try emitter.human("jackage {s} doctor\n", .{report.identity.version});
    try emitter.human("host      {s} ({d} cpus, page {d}..{d})\n", .{
        target,
        report.host.logical_cpus,
        report.host.page_size_min,
        report.host.page_size_max,
    });
    try emitter.human("toolchain pinned {s}, built with {s}, match {s}, wrapper {s}\n", .{
        report.recorded_pin orelse "(unknown)",
        report.identity.build_zig_version,
        if (report.pinMatches()) |matches| (if (matches) "yes" else "NO") else "unknown",
        if (report.wrapper_present) "present" else "missing",
    });
    try emitter.human("source    {d} files, {d} test blocks under {s}/\n", .{
        report.sources.files.len,
        report.sources.totalTestBlocks(),
        audit.source_root,
    });
    try emitter.human("audit     protected files {s}, declared dependencies {d}, project licence {s}\n", .{
        if (report.protected_files_verified) "verified" else "unavailable",
        report.inputs.dependencyCount(),
        report.inputs.project_license orelse "none declared",
    });
    if (report.degraded) |notes| {
        try emitter.human("degraded  inputs not readable here:{s}\n", .{notes});
    }
    try emitter.human("backend   {s} ({s}); boundary: {s}\n", .{
        report.backend.name,
        report.backend.family,
        report.backend.isolation_boundary,
    });
    for (report.backend.capabilities) |capability| {
        try emitter.human("  {s:<24} {s:<11} {s}\n", .{
            capability.name,
            capability.status.text(),
            capability.evidence,
        });
    }
    try emitter.human("release-blocking capabilities: {d}\n", .{report.backend.releaseBlockingCount()});
    if (report.repository_display) |display| {
        try emitter.human("repository {s} (credentials redacted; no transport backend is enrolled yet)\n", .{display});
    }
}

test "m01/CLI-008 diagnose honestly" {
    std.debug.print("JCKG_EVIDENCE CLI-008\n", .{});
    const gpa = std.testing.allocator;

    // The report publishes the executor's *measured* table, not a placeholder.
    const backend = exec.nativeBackend();
    try std.testing.expectEqualStrings("native-process", backend.name);
    try std.testing.expectEqualStrings("execution", backend.family);
    try std.testing.expect(backend.isolation_boundary.len > 0);
    try std.testing.expect(backend.capabilities.len > 0);

    // Nothing may claim enforcement: no adversarial conformance test exists
    // yet, on any platform.
    try std.testing.expectEqual(@as(usize, 0), backend.countOf(.enforced));

    // The native backend cannot isolate filesystem or network access wherever
    // it runs, and those entries stay release-blocking.
    for ([_][]const u8{ "filesystem.isolation", "network.isolation" }) |name| {
        const capability = backend.find(name) orelse return error.MissingCapability;
        try std.testing.expectEqual(capabilities.Status.unavailable, capability.status);
        try std.testing.expect(capability.blocks_release);
        try std.testing.expect(!capability.status.canBecomeReleaseSupport());
    }

    // Every entry is named and carries evidence; an unavailable capability can
    // never count as release support.
    for (backend.capabilities) |capability| {
        try std.testing.expect(capability.name.len > 0);
        try std.testing.expect(capability.evidence.len > 0);
        if (capability.status == .unavailable and capability.blocks_release) {
            try std.testing.expect(!capability.status.canBecomeReleaseSupport());
        }
    }

    // Policy refuses a strict requirement instead of downgrading it: isolation
    // is refused, an unknown name is refused, and - because nothing is
    // `enforced` - so is every capability the backend does report.
    try std.testing.expectError(error.CapabilityUnavailable, exec.requireCapabilities(&.{"filesystem.isolation"}));
    try std.testing.expectError(error.CapabilityUnavailable, exec.requireCapabilities(&.{"network.isolation"}));
    try std.testing.expectError(error.CapabilityUnavailable, exec.requireCapabilities(&.{"no.such.capability"}));
    for (backend.capabilities) |capability| {
        try std.testing.expectError(error.CapabilityUnavailable, exec.requireCapabilities(&.{capability.name}));
    }

    // The rendered documents carry exactly the measured statuses, so a report
    // can never look more confident than the backend is.
    const documents = try capabilityDocuments(gpa, backend);
    defer gpa.free(documents);
    try std.testing.expectEqual(backend.capabilities.len, documents.len);
    for (documents, backend.capabilities) |document, capability| {
        try std.testing.expectEqualStrings(capability.name, document.name);
        try std.testing.expectEqualStrings(capability.status.text(), document.status);
        try std.testing.expectEqualStrings(capability.evidence, document.evidence);
        try std.testing.expectEqual(capability.blocks_release, document.blocksRelease);
        try std.testing.expect(!std.mem.eql(u8, document.status, "enforced"));
    }
}
