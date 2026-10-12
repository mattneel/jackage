//! Lockfile contract, validation, and locked-mode enforcement
//! (cases PLAN-005, PLAN-006, PLAN-007).
//!
//! The document matches the pack's proposed `lock.schema.json` shape: a
//! project, the configuration and plan digests it was resolved from, the
//! toolchains, the exact package selections, the bootstrap inputs, and the
//! declared environment perimeter. Validation refuses anything that is not an
//! exact identity, and locked mode returns the recorded selections instead of
//! resolving again - a newer version elsewhere never silently replaces a locked
//! one.
const std = @import("std");
const canonical = @import("../core/canonical.zig");
const digest = @import("../core/digest.zig");
const resolver = @import("resolver.zig");
const version = @import("version.zig");

pub const schema_version = 1;

pub const Toolchain = struct {
    name: []const u8,
    version: []const u8,
    artifact: []const u8,
    source_identity: []const u8,
};

pub const PlatformTuple = struct {
    os: []const u8,
    architecture: []const u8,
    abi: ?[]const u8 = null,
    minimum_version: ?[]const u8 = null,
    cpu_features: ?[][]const u8 = null,
};

pub const PackagePin = struct {
    repository_identity: []const u8,
    name: []const u8,
    version: []const u8,
    platform: PlatformTuple,
    artifact: []const u8,
    dependencies: [][]const u8,
};

pub const BootstrapInput = struct {
    name: []const u8,
    source_identity: []const u8,
    digest: []const u8,
};

pub const Error = error{
    InvalidLockfile,
    MissingInput,
    FloatingIdentity,
    LockedInputMissing,
    LockedDigestMismatch,
    LockChanged,
    UnknownDependency,
    InvalidDigest,
    InvalidVersion,
};

pub const Lockfile = struct {
    project: []const u8,
    configuration_digest: []const u8,
    plan_digest: []const u8,
    toolchains: []Toolchain,
    packages: []PackagePin,
    bootstrap: []BootstrapInput,
    environment_perimeter: [][]const u8,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Lockfile) void {
        const gpa = self.gpa;
        gpa.free(self.project);
        gpa.free(self.configuration_digest);
        gpa.free(self.plan_digest);
        for (self.toolchains) |toolchain| {
            gpa.free(toolchain.name);
            gpa.free(toolchain.version);
            gpa.free(toolchain.artifact);
            gpa.free(toolchain.source_identity);
        }
        gpa.free(self.toolchains);
        for (self.packages) |package_env| {
            gpa.free(package_env.repository_identity);
            gpa.free(package_env.name);
            gpa.free(package_env.version);
            gpa.free(package_env.platform.os);
            gpa.free(package_env.platform.architecture);
            if (package_env.platform.abi) |text| gpa.free(text);
            if (package_env.platform.minimum_version) |text| gpa.free(text);
            if (package_env.platform.cpu_features) |features| {
                for (features) |feature| gpa.free(feature);
                gpa.free(features);
            }
            gpa.free(package_env.artifact);
            for (package_env.dependencies) |dependency| gpa.free(dependency);
            gpa.free(package_env.dependencies);
        }
        gpa.free(self.packages);
        for (self.bootstrap) |entry| {
            gpa.free(entry.name);
            gpa.free(entry.source_identity);
            gpa.free(entry.digest);
        }
        gpa.free(self.bootstrap);
        for (self.environment_perimeter) |entry| gpa.free(entry);
        gpa.free(self.environment_perimeter);
        self.* = undefined;
    }

    /// Canonical document, ready to be written and hashed.
    pub fn toCanonical(self: Lockfile, gpa: std.mem.Allocator) std.mem.Allocator.Error!canonical.Value {
        const toolchains = try gpa.alloc(canonical.Value, self.toolchains.len);
        for (self.toolchains, 0..) |toolchain, index| {
            const fields = try gpa.alloc(canonical.Entry, 4);
            fields[0] = .{ .key = try gpa.dupe(u8, "artifact"), .value = .{ .string = try gpa.dupe(u8, toolchain.artifact) } };
            fields[1] = .{ .key = try gpa.dupe(u8, "name"), .value = .{ .string = try gpa.dupe(u8, toolchain.name) } };
            fields[2] = .{ .key = try gpa.dupe(u8, "sourceIdentity"), .value = .{ .string = try gpa.dupe(u8, toolchain.source_identity) } };
            fields[3] = .{ .key = try gpa.dupe(u8, "version"), .value = .{ .string = try gpa.dupe(u8, toolchain.version) } };
            toolchains[index] = .{ .object = fields };
        }

        const packages = try gpa.alloc(canonical.Value, self.packages.len);
        for (self.packages, 0..) |package_env, index| {
            var platform_fields: std.ArrayList(canonical.Entry) = .empty;
            defer platform_fields.deinit(gpa);
            try platform_fields.append(gpa, .{ .key = try gpa.dupe(u8, "architecture"), .value = .{ .string = try gpa.dupe(u8, package_env.platform.architecture) } });
            if (package_env.platform.abi) |text| {
                try platform_fields.append(gpa, .{ .key = try gpa.dupe(u8, "abi"), .value = .{ .string = try gpa.dupe(u8, text) } });
            }
            if (package_env.platform.cpu_features) |features| {
                const values = try gpa.alloc(canonical.Value, features.len);
                for (features, 0..) |feature, feature_index| {
                    values[feature_index] = .{ .string = try gpa.dupe(u8, feature) };
                }
                try platform_fields.append(gpa, .{ .key = try gpa.dupe(u8, "cpuFeatures"), .value = .{ .array = values } });
            }
            if (package_env.platform.minimum_version) |text| {
                try platform_fields.append(gpa, .{ .key = try gpa.dupe(u8, "minimumVersion"), .value = .{ .string = try gpa.dupe(u8, text) } });
            }
            try platform_fields.append(gpa, .{ .key = try gpa.dupe(u8, "os"), .value = .{ .string = try gpa.dupe(u8, package_env.platform.os) } });
            std.mem.sort(canonical.Entry, platform_fields.items, {}, lessEntry);

            const dependencies = try gpa.alloc(canonical.Value, package_env.dependencies.len);
            for (package_env.dependencies, 0..) |dependency, dependency_index| {
                dependencies[dependency_index] = .{ .string = try gpa.dupe(u8, dependency) };
            }

            const fields = try gpa.alloc(canonical.Entry, 6);
            fields[0] = .{ .key = try gpa.dupe(u8, "artifact"), .value = .{ .string = try gpa.dupe(u8, package_env.artifact) } };
            fields[1] = .{ .key = try gpa.dupe(u8, "dependencies"), .value = .{ .array = dependencies } };
            fields[2] = .{ .key = try gpa.dupe(u8, "name"), .value = .{ .string = try gpa.dupe(u8, package_env.name) } };
            fields[3] = .{ .key = try gpa.dupe(u8, "platform"), .value = .{ .object = try platform_fields.toOwnedSlice(gpa) } };
            fields[4] = .{ .key = try gpa.dupe(u8, "repositoryIdentity"), .value = .{ .string = try gpa.dupe(u8, package_env.repository_identity) } };
            fields[5] = .{ .key = try gpa.dupe(u8, "version"), .value = .{ .string = try gpa.dupe(u8, package_env.version) } };
            packages[index] = .{ .object = fields };
        }

        const bootstrap = try gpa.alloc(canonical.Value, self.bootstrap.len);
        for (self.bootstrap, 0..) |entry, index| {
            const fields = try gpa.alloc(canonical.Entry, 3);
            fields[0] = .{ .key = try gpa.dupe(u8, "digest"), .value = .{ .string = try gpa.dupe(u8, entry.digest) } };
            fields[1] = .{ .key = try gpa.dupe(u8, "name"), .value = .{ .string = try gpa.dupe(u8, entry.name) } };
            fields[2] = .{ .key = try gpa.dupe(u8, "sourceIdentity"), .value = .{ .string = try gpa.dupe(u8, entry.source_identity) } };
            bootstrap[index] = .{ .object = fields };
        }

        const perimeter = try gpa.alloc(canonical.Value, self.environment_perimeter.len);
        for (self.environment_perimeter, 0..) |entry, index| {
            perimeter[index] = .{ .string = try gpa.dupe(u8, entry) };
        }

        const fields = try gpa.alloc(canonical.Entry, 8);
        fields[0] = .{ .key = try gpa.dupe(u8, "bootstrap"), .value = .{ .array = bootstrap } };
        fields[1] = .{ .key = try gpa.dupe(u8, "configurationDigest"), .value = .{ .string = try gpa.dupe(u8, self.configuration_digest) } };
        fields[2] = .{ .key = try gpa.dupe(u8, "environmentPerimeter"), .value = .{ .array = perimeter } };
        fields[3] = .{ .key = try gpa.dupe(u8, "packages"), .value = .{ .array = packages } };
        fields[4] = .{ .key = try gpa.dupe(u8, "planDigest"), .value = .{ .string = try gpa.dupe(u8, self.plan_digest) } };
        fields[5] = .{ .key = try gpa.dupe(u8, "project"), .value = .{ .string = try gpa.dupe(u8, self.project) } };
        fields[6] = .{ .key = try gpa.dupe(u8, "schemaVersion"), .value = .{ .integer = schema_version } };
        fields[7] = .{ .key = try gpa.dupe(u8, "toolchains"), .value = .{ .array = toolchains } };
        var document = canonical.Value{ .object = fields };
        canonical.canonicalize(&document);
        return document;
    }

    pub fn encode(self: Lockfile, gpa: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        const value = try self.toCanonical(gpa);
        defer value.deinit(gpa);
        return canonical.encodeAlloc(gpa, value);
    }
};

fn lessEntry(_: void, a: canonical.Entry, b: canonical.Entry) bool {
    return std.mem.lessThan(u8, a.key, b.key);
}

/// Identities that are labels, not identities: they cannot be locked.
pub fn isFloating(identity: []const u8) bool {
    const floating = [_][]const u8{ "master", "main", "latest", "HEAD", "head", "trunk", "nightly", "*", "" };
    for (floating) |label| {
        if (std.ascii.eqlIgnoreCase(identity, label)) return true;
    }
    return false;
}

/// Validates that every required input carries an exact identity and a
/// provenance boundary.
pub fn validate(lock: Lockfile) Error!void {
    if (lock.project.len == 0) return error.MissingInput;
    _ = digest.Digest.parse(lock.configuration_digest) catch return error.InvalidDigest;
    _ = digest.Digest.parse(lock.plan_digest) catch return error.InvalidDigest;
    if (lock.environment_perimeter.len == 0) return error.MissingInput;

    for (lock.toolchains) |toolchain| {
        if (toolchain.name.len == 0 or toolchain.version.len == 0) return error.MissingInput;
        if (isFloating(toolchain.source_identity)) return error.FloatingIdentity;
        _ = digest.Digest.parse(toolchain.artifact) catch return error.InvalidDigest;
    }

    for (lock.packages) |package_env| {
        if (package_env.repository_identity.len == 0 or package_env.name.len == 0) return error.MissingInput;
        if (isFloating(package_env.repository_identity)) return error.FloatingIdentity;
        if (isFloating(package_env.version)) return error.FloatingIdentity;
        _ = version.Version.parse(package_env.version) catch return error.InvalidVersion;
        if (package_env.platform.os.len == 0 or package_env.platform.architecture.len == 0) return error.MissingInput;
        _ = digest.Digest.parse(package_env.artifact) catch return error.InvalidDigest;
        for (package_env.dependencies) |dependency| {
            if (dependency.len == 0) return error.MissingInput;
            var found = false;
            for (lock.packages) |candidate| {
                if (std.mem.eql(u8, candidate.name, dependency)) found = true;
            }
            if (!found) return error.UnknownDependency;
        }
    }

    for (lock.bootstrap) |entry| {
        if (entry.name.len == 0) return error.MissingInput;
        if (isFloating(entry.source_identity)) return error.FloatingIdentity;
        _ = digest.Digest.parse(entry.digest) catch return error.InvalidDigest;
    }
}

/// Refuses a locked run whose configuration or plan no longer matches.
pub fn checkLockedMode(lock: Lockfile, configuration_digest: []const u8, plan_digest: []const u8) Error!void {
    if (!std.mem.eql(u8, lock.configuration_digest, configuration_digest)) return error.LockChanged;
    if (!std.mem.eql(u8, lock.plan_digest, plan_digest)) return error.LockChanged;
}

/// The exact selections recorded in the lock, checked against available
/// metadata. A newer version in the pool changes nothing: the locked version
/// and artifact are what the run uses.
pub fn lockedResolution(
    gpa: std.mem.Allocator,
    lock: Lockfile,
    pool: []const resolver.Candidate,
) (Error || std.mem.Allocator.Error)!resolver.Resolution {
    const selections = try gpa.alloc(resolver.Selection, lock.packages.len);
    errdefer gpa.free(selections);

    for (lock.packages, 0..) |package_env, index| {
        const locked_version = version.Version.parse(package_env.version) catch return error.InvalidVersion;
        var found: ?resolver.Candidate = null;
        for (pool) |candidate| {
            if (!std.mem.eql(u8, candidate.namespace, package_env.repository_identity)) continue;
            if (!std.mem.eql(u8, candidate.name, package_env.name)) continue;
            if (version.Version.compare(candidate.version, locked_version) != .eq) continue;
            found = candidate;
        }
        const candidate = found orelse return error.LockedInputMissing;
        if (!std.mem.eql(u8, candidate.artifact_digest, package_env.artifact)) return error.LockedDigestMismatch;
        selections[index] = .{
            .namespace = package_env.repository_identity,
            .name = package_env.name,
            .version = locked_version,
            .artifact_digest = package_env.artifact,
        };
    }
    return .{ .selections = selections, .gpa = gpa };
}

// ---------------------------------------------------------------------------
// Fixture lockfile
// ---------------------------------------------------------------------------

pub const fixture_configuration_digest = "sha256:1111111111111111111111111111111111111111111111111111111111111111";
pub const fixture_plan_digest = "sha256:2222222222222222222222222222222222222222222222222222222222222222";

fn fixtureLock(gpa: std.mem.Allocator) !Lockfile {
    const toolchains = try gpa.alloc(Toolchain, 3);
    toolchains[0] = .{
        .name = try gpa.dupe(u8, "zig"),
        .version = try gpa.dupe(u8, "0.18.0-dev.146+35accc06e"),
        .artifact = try gpa.dupe(u8, "sha256:ec5d64aae44b54ce8425ecd7b40f1fa5c8061d1dc80939b02ed036513d69ae67"),
        .source_identity = try gpa.dupe(u8, "ziglang.org/builds/zig-x86_64-windows-0.18.0-dev.146"),
    };
    toolchains[1] = .{
        .name = try gpa.dupe(u8, "quickjs-ng"),
        .version = try gpa.dupe(u8, "0.10.1"),
        .artifact = try gpa.dupe(u8, "sha256:3333333333333333333333333333333333333333333333333333333333333333"),
        .source_identity = try gpa.dupe(u8, "github.com/quickjs-ng/quickjs@v0.10.1"),
    };
    toolchains[2] = .{
        .name = try gpa.dupe(u8, "typescript-transformer"),
        .version = try gpa.dupe(u8, "1.0.0"),
        .artifact = try gpa.dupe(u8, "sha256:4444444444444444444444444444444444444444444444444444444444444444"),
        .source_identity = try gpa.dupe(u8, "registry.npmjs.org/esbuild/0.25.0"),
    };

    const packages = try gpa.alloc(PackagePin, 2);
    const app_dependencies = try gpa.alloc([]const u8, 1);
    app_dependencies[0] = try gpa.dupe(u8, "lib");
    packages[0] = .{
        .repository_identity = try gpa.dupe(u8, resolver.fixture_namespace),
        .name = try gpa.dupe(u8, "app"),
        .version = try gpa.dupe(u8, "1.1.0"),
        .platform = .{
            .os = try gpa.dupe(u8, "linux"),
            .architecture = try gpa.dupe(u8, "x86_64"),
            .abi = try gpa.dupe(u8, "gnu"),
        },
        .artifact = try gpa.dupe(u8, "sha256:aa00000000000000000000000000000000000000000000000000000000000002"),
        .dependencies = app_dependencies,
    };
    packages[1] = .{
        .repository_identity = try gpa.dupe(u8, resolver.fixture_namespace),
        .name = try gpa.dupe(u8, "lib"),
        .version = try gpa.dupe(u8, "1.1.0"),
        .platform = .{
            .os = try gpa.dupe(u8, "linux"),
            .architecture = try gpa.dupe(u8, "x86_64"),
            .abi = try gpa.dupe(u8, "gnu"),
        },
        .artifact = try gpa.dupe(u8, "sha256:bb00000000000000000000000000000000000000000000000000000000000002"),
        .dependencies = try gpa.alloc([]const u8, 0),
    };

    const bootstrap = try gpa.alloc(BootstrapInput, 1);
    bootstrap[0] = .{
        .name = try gpa.dupe(u8, "zig-toolchain-archive"),
        .source_identity = try gpa.dupe(u8, "ziglang.org/builds/zig-x86_64-windows-0.18.0-dev.146"),
        .digest = try gpa.dupe(u8, "sha256:ec5d64aae44b54ce8425ecd7b40f1fa5c8061d1dc80939b02ed036513d69ae67"),
    };

    const perimeter = try gpa.alloc([]const u8, 2);
    perimeter[0] = try gpa.dupe(u8, "windows-10.0.26200-x86_64");
    perimeter[1] = try gpa.dupe(u8, "winsdk-10.0.26100");

    return .{
        .project = try gpa.dupe(u8, "jackage"),
        .configuration_digest = try gpa.dupe(u8, fixture_configuration_digest),
        .plan_digest = try gpa.dupe(u8, fixture_plan_digest),
        .toolchains = toolchains,
        .packages = packages,
        .bootstrap = bootstrap,
        .environment_perimeter = perimeter,
        .gpa = gpa,
    };
}

test "m05/PLAN-005 lock complete inputs" {
    std.debug.print("JCKG_EVIDENCE PLAN-005\n", .{});
    const gpa = std.testing.allocator;

    var lock = try fixtureLock(gpa);
    defer lock.deinit();

    // A complete lock validates: every tool, source input, evaluator module and
    // platform boundary carries an exact identity.
    try validate(lock);

    // It round-trips through canonical bytes with the proposed schema shape.
    const encoded = try lock.encode(gpa);
    defer gpa.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"schemaVersion\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"toolchains\":[{") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"environmentPerimeter\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"sourceIdentity\":\"github.com/quickjs-ng/quickjs@v0.10.1\"") != null);

    const second = try lock.encode(gpa);
    defer gpa.free(second);
    try std.testing.expectEqualStrings(encoded, second);

    // Negative-or-recovery: each missing identity is refused.
    var missing_boundary = try fixtureLock(gpa);
    defer missing_boundary.deinit();
    gpa.free(missing_boundary.environment_perimeter[0]);
    gpa.free(missing_boundary.environment_perimeter[1]);
    gpa.free(missing_boundary.environment_perimeter);
    missing_boundary.environment_perimeter = try gpa.alloc([]const u8, 0);
    try std.testing.expectError(error.MissingInput, validate(missing_boundary));

    var bad_digest = try fixtureLock(gpa);
    defer bad_digest.deinit();
    gpa.free(bad_digest.toolchains[0].artifact);
    bad_digest.toolchains[0].artifact = try gpa.dupe(u8, "sha256:short");
    try std.testing.expectError(error.InvalidDigest, validate(bad_digest));

    var unknown_dependency = try fixtureLock(gpa);
    defer unknown_dependency.deinit();
    gpa.free(unknown_dependency.packages[0].dependencies[0]);
    unknown_dependency.packages[0].dependencies[0] = try gpa.dupe(u8, "not-in-the-lock");
    try std.testing.expectError(error.UnknownDependency, validate(unknown_dependency));
}

test "m05/PLAN-006 refuse floating locked input" {
    std.debug.print("JCKG_EVIDENCE PLAN-006\n", .{});
    const gpa = std.testing.allocator;

    try std.testing.expect(isFloating("master"));
    try std.testing.expect(isFloating("latest"));
    try std.testing.expect(isFloating("HEAD"));
    try std.testing.expect(isFloating(""));
    try std.testing.expect(!isFloating("v1.2.3"));
    try std.testing.expect(!isFloating("github.com/acme/lib@9f1c2d3"));
    try std.testing.expect(!isFloating("0.18.0-dev.146+35accc06e"));

    // A locked source that only says `master` is refused by validation.
    var floating_source = try fixtureLock(gpa);
    defer floating_source.deinit();
    gpa.free(floating_source.bootstrap[0].source_identity);
    floating_source.bootstrap[0].source_identity = try gpa.dupe(u8, "master");
    try std.testing.expectError(error.FloatingIdentity, validate(floating_source));

    var floating_toolchain = try fixtureLock(gpa);
    defer floating_toolchain.deinit();
    gpa.free(floating_toolchain.toolchains[1].source_identity);
    floating_toolchain.toolchains[1].source_identity = try gpa.dupe(u8, "latest");
    try std.testing.expectError(error.FloatingIdentity, validate(floating_toolchain));

    var floating_package = try fixtureLock(gpa);
    defer floating_package.deinit();
    gpa.free(floating_package.packages[1].version);
    floating_package.packages[1].version = try gpa.dupe(u8, "latest");
    try std.testing.expectError(error.FloatingIdentity, validate(floating_package));

    // Negative-or-recovery: the same document with an exact identity validates,
    // so the refusal is about the identity and not about the document shape.
    var exact = try fixtureLock(gpa);
    defer exact.deinit();
    try validate(exact);
}

test "m05/PLAN-007 honor locked mode" {
    std.debug.print("JCKG_EVIDENCE PLAN-007\n", .{});
    const gpa = std.testing.allocator;

    var lock = try fixtureLock(gpa);
    defer lock.deinit();
    const before = try lock.encode(gpa);
    defer gpa.free(before);

    // Metadata later offers a newer lib; the locked run still selects 1.1.0.
    const newer_pool = resolver.fixture_pool ++ [_]resolver.Candidate{
        .{
            .namespace = resolver.fixture_namespace,
            .name = "lib",
            .version = .{ .major = 1, .minor = 2, .patch = 0 },
            .artifact_digest = "sha256:bb00000000000000000000000000000000000000000000000000000000000009",
        },
    };

    var resolution = try lockedResolution(gpa, lock, &newer_pool);
    defer resolution.deinit();
    const lib = resolution.find(resolver.fixture_namespace, "lib") orelse return error.MissingSelection;
    // The locked 1.1.0 is selected even though the pool now offers 1.2.0.
    try std.testing.expectEqual(@as(u32, 1), lib.version.major);
    try std.testing.expectEqual(@as(u32, 1), lib.version.minor);
    try std.testing.expectEqual(@as(u32, 0), lib.version.patch);
    try std.testing.expectEqualStrings("sha256:bb00000000000000000000000000000000000000000000000000000000000002", lib.artifact_digest);

    // The lock itself is untouched by a locked run.
    const after = try lock.encode(gpa);
    defer gpa.free(after);
    try std.testing.expectEqualStrings(before, after);

    // A configuration or plan change is a lock change, not a re-resolution.
    try checkLockedMode(lock, fixture_configuration_digest, fixture_plan_digest);
    try std.testing.expectError(
        error.LockChanged,
        checkLockedMode(lock, "sha256:9999999999999999999999999999999999999999999999999999999999999999", fixture_plan_digest),
    );
    try std.testing.expectError(
        error.LockChanged,
        checkLockedMode(lock, fixture_configuration_digest, "sha256:9999999999999999999999999999999999999999999999999999999999999999"),
    );

    // Negative-or-recovery: a locked artifact that no longer exists, or that
    // changed digest, is reported instead of being silently re-resolved.
    const missing_pool = [_]resolver.Candidate{
        .{
            .namespace = resolver.fixture_namespace,
            .name = "app",
            .version = .{ .major = 1, .minor = 1, .patch = 0 },
            .artifact_digest = "sha256:aa00000000000000000000000000000000000000000000000000000000000002",
        },
    };
    try std.testing.expectError(error.LockedInputMissing, lockedResolution(gpa, lock, &missing_pool));

    const changed_pool = [_]resolver.Candidate{
        .{
            .namespace = resolver.fixture_namespace,
            .name = "app",
            .version = .{ .major = 1, .minor = 1, .patch = 0 },
            .artifact_digest = "sha256:aa00000000000000000000000000000000000000000000000000000000000007",
        },
        .{
            .namespace = resolver.fixture_namespace,
            .name = "lib",
            .version = .{ .major = 1, .minor = 1, .patch = 0 },
            .artifact_digest = "sha256:bb00000000000000000000000000000000000000000000000000000000000002",
        },
    };
    try std.testing.expectError(error.LockedDigestMismatch, lockedResolution(gpa, lock, &changed_pool));
}
