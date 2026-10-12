//! Evaluating what a plugin is allowed to touch (M13, PLUGIN-009).
//!
//! A plugin declares its authority in its manifest: these filesystem paths, in this
//! mode, and these named credentials. A request that is not covered by a declaration
//! fails. The interesting part is that "covered" is narrow on purpose:
//!
//! - a declaration names a path *and* a mode, so read access is not write access;
//! - containment is decided on normalized paths, so `declared/../../etc` is not
//!   inside `declared`;
//! - nothing is expanded automatically - a request that is almost covered is a
//!   refusal, not a prompt that defaults to yes, and a wildcard declaration is
//!   itself refused so an "allow everything" manifest cannot be written at all.
//!
//! Refusing here costs a manifest edit. Granting by accident costs the user's
//! machine, and the difference is not worth a convenience feature.
const std = @import("std");

pub const Error = error{
    UndeclaredPath,
    UndeclaredMode,
    UndeclaredCredential,
    WildcardDeclaration,
    CannotExpand,
    InvalidRequest,
    OutOfMemory,
};

pub const Mode = enum { read, write };

/// One declared filesystem permission: a path and the access granted beneath it.
pub const FilesystemGrant = struct {
    path: []const u8,
    modes: []const Mode,
};

pub const Manifest = struct {
    filesystem: []const FilesystemGrant = &.{},
    credentials: []const []const u8 = &.{},
};

pub const Request = union(enum) {
    filesystem: struct {
        path: []const u8,
        mode: Mode,
    },
    credential: []const u8,
};

pub const Decision = struct {
    /// The declaration that covered the request, for the record. A decision that
    /// cannot name its basis is not auditable.
    basis: []const u8,
};

const MAX_PATH = 4096;

fn normalize(buffer: []u8, path: []const u8) Error![]u8 {
    if (path.len == 0 or path.len > MAX_PATH) return error.InvalidRequest;
    var parts: [128][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (count == 0) return error.InvalidRequest;
            count -= 1;
            continue;
        }
        if (count == parts.len) return error.InvalidRequest;
        parts[count] = part;
        count += 1;
    }
    if (count == 0) return error.InvalidRequest;
    var len: usize = 0;
    for (parts[0..count], 0..) |part, index| {
        if (index > 0) {
            buffer[len] = '/';
            len += 1;
        }
        if (len + part.len > MAX_PATH) return error.InvalidRequest;
        @memcpy(buffer[len .. len + part.len], part);
        len += part.len;
    }
    return buffer[0..len];
}

fn contains(root: []const u8, candidate: []const u8) bool {
    if (candidate.len < root.len) return false;
    if (!std.mem.eql(u8, candidate[0..root.len], root)) return false;
    return candidate.len == root.len or candidate[root.len] == '/';
}

/// Evaluates one request against a manifest, granting only what is declared.
pub fn evaluate(gpa: std.mem.Allocator, manifest: Manifest, request: Request) Error!Decision {
    _ = gpa;

    // A wildcard declaration is refused outright: there is no manifest for which
    // every request is covered, so none may be written.
    for (manifest.filesystem) |grant| {
        if (std.mem.eql(u8, grant.path, "*") or std.mem.eql(u8, grant.path, "/")) {
            return error.WildcardDeclaration;
        }
    }
    for (manifest.credentials) |name| {
        if (std.mem.eql(u8, name, "*")) return error.WildcardDeclaration;
    }

    switch (request) {
        .credential => |name| {
            for (manifest.credentials) |declared| {
                if (std.mem.eql(u8, declared, name)) return .{ .basis = declared };
            }
            return error.UndeclaredCredential;
        },
        .filesystem => |asked| {
            var request_buffer: [MAX_PATH]u8 = undefined;
            const normalized_request = try normalize(&request_buffer, asked.path);

            for (manifest.filesystem) |grant| {
                var grant_buffer: [MAX_PATH]u8 = undefined;
                const normalized_grant = try normalize(&grant_buffer, grant.path);
                if (!contains(normalized_grant, normalized_request)) continue;
                // The path is inside a declaration; whether the *mode* is granted is
                // a separate question, and this is where a read declaration is kept
                // from quietly becoming a write one.
                for (grant.modes) |mode| {
                    if (mode == asked.mode) return .{ .basis = grant.path };
                }
                // Covered by path but not by mode: the refusal names the mode, so the
                // caller learns it needs a declaration rather than a different path.
                return error.UndeclaredMode;
            }
            return error.UndeclaredPath;
        },
    }
}

test "m13/PLUGIN-009 constrain plugin authority: undeclared requests fail without expansion" {
    std.debug.print("JCKG_EVIDENCE PLUGIN-009\n", .{});
    const gpa = std.testing.allocator;

    const read_only = [_]Mode{.read};
    const read_write = [_]Mode{ .read, .write };
    const manifest = Manifest{
        .filesystem = &.{
            .{ .path = "C:/src/myproject/src", .modes = &read_only },
            .{ .path = "/home/me/.jackage/cache", .modes = &read_write },
        },
        .credentials = &.{"github-token"},
    };

    // Declared path and declared mode: granted, and the decision names its basis.
    const granted = try evaluate(gpa, manifest, .{ .filesystem = .{ .path = "C:/src/myproject/src/main.zig", .mode = .read } });
    try std.testing.expectEqualStrings("C:/src/myproject/src", granted.basis);
    _ = try evaluate(gpa, manifest, .{ .filesystem = .{ .path = "/home/me/.jackage/cache/zig/abc", .mode = .write } });
    _ = try evaluate(gpa, manifest, .{ .credential = "github-token" });

    // A path outside every declaration is refused.
    try std.testing.expectError(
        error.UndeclaredPath,
        evaluate(gpa, manifest, .{ .filesystem = .{ .path = "C:/Users/me/.ssh/id_rsa", .mode = .read } }),
    );

    // Covered by path but not by mode: read was declared, write is not, and write is
    // not inferred from read.
    try std.testing.expectError(
        error.UndeclaredMode,
        evaluate(gpa, manifest, .{ .filesystem = .{ .path = "C:/src/myproject/src/main.zig", .mode = .write } }),
    );

    // A path that reaches outside the declaration through `..` is not inside it.
    try std.testing.expectError(
        error.UndeclaredPath,
        evaluate(gpa, manifest, .{ .filesystem = .{ .path = "C:/src/myproject/src/../../secrets", .mode = .read } }),
    );
    try std.testing.expectError(
        error.UndeclaredPath,
        evaluate(gpa, manifest, .{ .filesystem = .{ .path = "/home/me/.jackage/cache/../../../../etc/shadow", .mode = .read } }),
    );

    // An undeclared credential is refused, and so is a wildcard declaration - there
    // is no manifest for which every request is covered.
    try std.testing.expectError(error.UndeclaredCredential, evaluate(gpa, manifest, .{ .credential = "aws-root" }));
    const wildcard_fs = Manifest{ .filesystem = &.{.{ .path = "*", .modes = &read_write }} };
    try std.testing.expectError(
        error.WildcardDeclaration,
        evaluate(gpa, wildcard_fs, .{ .filesystem = .{ .path = "C:/anything", .mode = .read } }),
    );
    const wildcard_cred = Manifest{ .credentials = &.{"*"} };
    try std.testing.expectError(error.WildcardDeclaration, evaluate(gpa, wildcard_cred, .{ .credential = "anything" }));

    // A sibling directory sharing a prefix is not inside the declaration.
    try std.testing.expectError(
        error.UndeclaredPath,
        evaluate(gpa, manifest, .{ .filesystem = .{ .path = "C:/src/myproject/src-other/x", .mode = .read } }),
    );

    // An empty manifest grants nothing at all.
    try std.testing.expectError(
        error.UndeclaredPath,
        evaluate(gpa, .{}, .{ .filesystem = .{ .path = "C:/src/myproject/src/main.zig", .mode = .read } }),
    );
    try std.testing.expectError(error.UndeclaredCredential, evaluate(gpa, .{}, .{ .credential = "github-token" }));
}
