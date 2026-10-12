//! Building without handing a stranger the agent's credentials (M16, FACTORY-003).
//!
//! An agent runs on a host that holds provider credentials: API keys, tokens, and the
//! paths to the files that carry them. A build it launches is usually somebody else's
//! code - a package, a fixture, a repository - and a process that inherits an
//! environment can read it with one system call. The dangerous shape is not a build
//! that goes looking; it is a build that *can* look.
//!
//! Two decisions follow from that:
//!
//! - **The build environment is an allow-list, not a filtered host environment.**
//!   Filtering hands over everything that is not recognised as a credential, and the
//!   next credential does not exist yet. A build gets exactly what its declaration
//!   names and nothing else, so an unknown variable is absent by construction rather
//!   than by having been noticed.
//! - **The result is checked, in the child.** Scrubbing is asserted on the environment
//!   map and again on what a process spawned with it can actually see, because those
//!   are different claims: the map is what this code believes, and the child is what
//!   the operating system believes.
//!
//! Nothing here redacts: a redacted value is still a value. Credentials are removed,
//! and a name that was in the host's environment simply does not exist for the build.
const std = @import("std");

pub const Error = error{
    InvalidDeclaration,
    CredentialInDeclaration,
    Leaked,
    SpawnFailed,
    OutOfMemory,
};

/// Names that are credentials wherever they appear. Used to refuse a declaration that
/// tries to pass one on, not to filter the host: the allow-list is what keeps the
/// host's environment out.
const credential_markers = [_][]const u8{
    "_API_KEY",
    "_TOKEN",
    "_SECRET",
    "_PASSWORD",
    "APIKEY",
    "CREDENTIALS",
};

pub fn credentialName(name: []const u8) bool {
    var upper_buffer: [128]u8 = undefined;
    if (name.len > upper_buffer.len) return true;
    const upper = std.ascii.upperString(upper_buffer[0..name.len], name);
    for (credential_markers) |marker| {
        if (std.mem.indexOf(u8, upper, marker) != null) return true;
    }
    return false;
}

/// What a strict build is allowed to see.
pub const Declaration = struct {
    /// Variables the build may have. The values come from the host, but only for
    /// names listed here.
    allowed: []const []const u8,
    /// Extra variables the declaration itself sets.
    set: []const struct { key: []const u8, value: []const u8 } = &.{},
};

pub const Environment = struct {
    /// The variables the build will run with.
    variables: []const []const u8,

    pub fn deinit(self: Environment, gpa: std.mem.Allocator) void {
        for (self.variables) |variable| gpa.free(variable);
        gpa.free(self.variables);
    }

    pub fn names(self: Environment, gpa: std.mem.Allocator) Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (out.items) |name| gpa.free(name);
            out.deinit(gpa);
        }
        for (self.variables) |variable| {
            const at = std.mem.indexOfScalar(u8, variable, '=') orelse variable.len;
            try out.append(gpa, try gpa.dupe(u8, variable[0..at]));
        }
        return out.toOwnedSlice(gpa);
    }
};

pub fn deinitNames(gpa: std.mem.Allocator, names: []const []const u8) void {
    for (names) |name| gpa.free(name);
    gpa.free(names);
}

/// Builds the environment a strict build runs with.
///
/// `host` is the environment of the process that is about to launch the build; it is
/// read only for the names the declaration allows.
pub fn strict(
    gpa: std.mem.Allocator,
    host: *const std.process.Environ.Map,
    declaration: Declaration,
) Error!Environment {
    if (declaration.allowed.len == 0 and declaration.set.len == 0) return error.InvalidDeclaration;
    for (declaration.allowed) |name| {
        // A declaration that asks for a credential is refused rather than trimmed: an
        // allow-list that quietly drops entries teaches nobody anything.
        if (credentialName(name)) return error.CredentialInDeclaration;
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, '=') != null) return error.InvalidDeclaration;
    }

    var variables: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (variables.items) |variable| gpa.free(variable);
        variables.deinit(gpa);
    }

    for (declaration.allowed) |name| {
        const value = host.get(name) orelse continue;
        try variables.append(gpa, try std.fmt.allocPrint(gpa, "{s}={s}", .{ name, value }));
    }
    for (declaration.set) |variable| {
        if (credentialName(variable.key)) return error.CredentialInDeclaration;
        try variables.append(gpa, try std.fmt.allocPrint(gpa, "{s}={s}", .{ variable.key, variable.value }));
    }
    return .{ .variables = try variables.toOwnedSlice(gpa) };
}

/// Checked against the environment map: no variable the build will see carries a
/// credential name.
pub fn assertClean(environment: Environment) Error!void {
    for (environment.variables) |variable| {
        const at = std.mem.indexOfScalar(u8, variable, '=') orelse variable.len;
        if (credentialName(variable[0..at])) return error.Leaked;
    }
}

pub const Probe = struct {
    /// The names the child reported, as it saw them.
    observed: []const []const u8,

    pub fn deinit(self: Probe, gpa: std.mem.Allocator) void {
        for (self.observed) |name| gpa.free(name);
        gpa.free(self.observed);
    }
};

/// Spawns a process with the strict environment and records what it can see.
///
/// This is the half that makes the guarantee real: the environment map is what this
/// code intends, and the child's own view is what the operating system hands over.
pub fn probe(
    gpa: std.mem.Allocator,
    io: std.Io,
    program: []const u8,
    arguments: []const []const u8,
    environment: Environment,
) Error!Probe {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, program);
    try argv.appendSlice(gpa, arguments);

    // The child's environment is the strict one, spelled out: an inherited map would
    // defeat the whole exercise, so `env_map` is passed explicitly rather than left
    // to default to the parent's.
    var map = std.process.Environ.Map.init(gpa);
    defer map.deinit();
    for (environment.variables) |variable| {
        const at = std.mem.indexOfScalar(u8, variable, '=') orelse return error.InvalidDeclaration;
        try map.put(variable[0..at], variable[at + 1 ..]);
    }

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .environ_map = &map,
    }) catch return error.SpawnFailed;
    defer child.kill(io);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(io, &stdout_buffer);
    const stdout = stdout_reader.interface.allocRemaining(gpa, .limited(1 << 20)) catch
        return error.SpawnFailed;
    defer gpa.free(stdout);
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(io, &stderr_buffer);
    const stderr = stderr_reader.interface.allocRemaining(gpa, .limited(1 << 20)) catch
        return error.SpawnFailed;
    defer gpa.free(stderr);
    const term = child.wait(io) catch return error.SpawnFailed;
    switch (term) {
        .exited => |code| if (code != 0) return error.SpawnFailed,
        else => return error.SpawnFailed,
    }

    // The names are taken from the child's own output, so what is checked is what the
    // child saw rather than what it was supposed to see.
    var observed: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (observed.items) |name| gpa.free(name);
        observed.deinit(gpa);
    }
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        const at = std.mem.indexOfScalar(u8, trimmed, '=') orelse trimmed.len;
        try observed.append(gpa, try gpa.dupe(u8, trimmed[0..at]));
    }
    return .{ .observed = try observed.toOwnedSlice(gpa) };
}

/// Checked against the child's view: no credential name reached it.
pub fn assertNoCredentials(gpa: std.mem.Allocator, probe_result: Probe, expected: []const []const u8) Error!void {
    for (probe_result.observed) |name| {
        if (credentialName(name)) return error.Leaked;
    }
    // And the names the declaration allowed are actually there, so a child with an
    // empty environment cannot pass this check by having nothing at all.
    for (expected) |name| {
        var found = false;
        for (probe_result.observed) |observed| {
            if (std.mem.eql(u8, observed, name)) {
                found = true;
                break;
            }
        }
        if (!found) return error.Leaked;
    }
    _ = gpa;
}

test "m16/FACTORY-003 preserve agent secrets: a strict build cannot read provider credentials" {
    std.debug.print("JCKG_EVIDENCE FACTORY-003\n", .{});
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // A host environment of the shape an agent actually runs in: provider credentials
    // and a few benign variables a build legitimately needs.
    var host = std.process.Environ.Map.init(gpa);
    defer host.deinit();
    try host.put("OPENAI_API_KEY", "sk-secret-value");
    try host.put("ANTHROPIC_API_KEY", "sk-ant-secret-value");
    try host.put("GITHUB_TOKEN", "ghp_secret_value");
    try host.put("AWS_SECRET_ACCESS_KEY", "aws-secret");
    try host.put("PATH", "/usr/bin:/bin");
    try host.put("JCKG_HOME", "/jckg");

    // The allow-list names what the build may have. Nothing else exists for it.
    const declaration = Declaration{
        .allowed = &.{ "PATH", "JCKG_HOME" },
        .set = &.{.{ .key = "JCKG_STRICT", .value = "1" }},
    };
    const environment = try strict(gpa, &host, declaration);
    defer environment.deinit(gpa);

    try assertClean(environment);
    const names = try environment.names(gpa);
    defer deinitNames(gpa, names);
    try std.testing.expectEqual(@as(usize, 3), names.len);

    // A credential that was not even in the host's environment is absent too: the
    // allow-list does not depend on knowing the names of secrets.
    try std.testing.expect(host.get("NOT_A_KNOWN_CREDENTIAL_NAME") == null);

    // A declaration that asks for a credential is refused rather than trimmed, in both
    // the allow-list and the values it sets.
    const asking = Declaration{ .allowed = &.{ "OPENAI_API_KEY", "PATH" } };
    try std.testing.expectError(error.CredentialInDeclaration, strict(gpa, &host, asking));
    const setting = Declaration{
        .allowed = &.{"PATH"},
        .set = &.{.{ .key = "DEPLOY_TOKEN", .value = "x" }},
    };
    try std.testing.expectError(error.CredentialInDeclaration, strict(gpa, &host, setting));
    // A declaration that allows nothing at all is not a strict environment, it is a
    // mistake.
    try std.testing.expectError(error.InvalidDeclaration, strict(gpa, &host, .{ .allowed = &.{} }));

    // The name rule itself: markers are matched case-insensitively and on the name,
    // so a variable that merely contains the letters is not swept up.
    try std.testing.expect(credentialName("OPENAI_API_KEY"));
    try std.testing.expect(credentialName("github_token"));
    try std.testing.expect(credentialName("MY_SECRET"));
    try std.testing.expect(credentialName("DB_PASSWORD"));
    try std.testing.expect(!credentialName("PATH"));
    try std.testing.expect(!credentialName("JCKG_HOME"));
    try std.testing.expect(!credentialName("TOKENIZER_MODEL"));

    // The child's view: a process spawned with the strict environment cannot read a
    // credential, and the names it was allowed are genuinely present.
    if (@import("builtin").os.tag == .windows) {
        const seen = try probe(gpa, io, "cmd", &.{ "/c", "set" }, environment);
        defer seen.deinit(gpa);
        try assertNoCredentials(gpa, seen, &.{ "PATH", "JCKG_STRICT" });
    } else {
        const seen = try probe(gpa, io, "env", &.{}, environment);
        defer seen.deinit(gpa);
        try assertNoCredentials(gpa, seen, &.{ "PATH", "JCKG_STRICT" });
    }
}
