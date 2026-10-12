//! Round-tripping a built archive through the product's own validator
//! (M10, PACK-004).
//!
//! Two writers exist (ZIP for distribution, tar for trees); the thing that makes
//! them trustworthy is that the *product* can read back what they wrote and arrive
//! at the same tree identity. This test builds a tar with the declared metadata
//! policy, extracts it through `trust/archive.zig` - the same validator the
//! download path uses - and compares the resulting tree digest with the digest of
//! the tree that was declared.
//!
//! A truncated archive is asserted to be refused, because "round-trips" is only
//! meaningful if the validator also rejects what is not a valid archive.
//!
//! **Scope, measured rather than assumed:** the product validator accepts regular
//! files and directories; it refuses symbolic links (`error.UnsupportedEntry`),
//! because it was written for the download path where links were out of scope. So
//! the round trip here covers the validator's supported set - including the
//! executable bit, which is part of tree identity - and symbolic links are covered
//! by the tar writer's own case (PACK-003), which builds and asserts them. The
//! validator's link limitation is recorded rather than papered over, and widening
//! it is a change to `trust/archive.zig` with its own M07 evidence to re-run.
const std = @import("std");
const tar = @import("tar.zig");
const archive = @import("../trust/archive.zig");
const tree_module = @import("../core/tree.zig");
const digest = @import("../core/digest.zig");

fn digestText(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &raw, .{});
    const hex = std.fmt.bytesToHex(raw, .lower);
    return std.fmt.allocPrint(gpa, "sha256:{s}", .{hex});
}

test "m10/PACK-004 round-trip tree: extraction reproduces the declared tree identity" {
    std.debug.print("JCKG_EVIDENCE PACK-004\n", .{});
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const root_path = "zig-out/jckg-roundtrip";
    cwd.deleteTree(io, root_path) catch {};
    defer cwd.deleteTree(io, root_path) catch {};
    var parent = try cwd.createDirPathOpen(io, root_path, .{ .open_options = .{ .iterate = true } });
    defer parent.close(io);

    // A tree with the shapes the case names, declared in the order the archive
    // requires.
    const file_bytes = "client payload\n";
    const executable_bytes = "#!/bin/sh\necho jckg\n";
    const declaration = [_]tar.Entry{
        .{ .name = "bin", .kind = .directory },
        .{ .name = "bin/jckg", .kind = .file, .data = executable_bytes, .mode = 0o755 },
        .{ .name = "share/doc/COPYING", .kind = .file, .data = file_bytes, .mode = 0o644 },
    };

    const archive_bytes = try tar.buildAlloc(gpa, &declaration, .{});
    defer gpa.free(archive_bytes);

    // Extraction through the product validator, which is the download path's own
    // reader rather than a test-only parser.
    var extraction = try archive.extractBytes(gpa, io, archive_bytes, parent, "tree", .{});
    defer extraction.deinit();

    // The declared tree, built from the same declaration, with digests over the
    // declared bytes and the executable bit carried as a boolean.
    const executable_digest = try digestText(gpa, executable_bytes);
    defer gpa.free(executable_digest);
    const file_digest = try digestText(gpa, file_bytes);
    defer gpa.free(file_digest);
    // Implicit directories are part of the extracted identity: the validator
    // records the directories a file's path implies, which is why "share" and
    // "share/doc" appear here although the declaration did not name them.
    const entries = [_]tree_module.Entry{
        .{ .path = "bin", .kind = .directory },
        .{ .path = "bin/jckg", .kind = .file, .digest = executable_digest, .byte_length = executable_bytes.len, .executable = true },
        .{ .path = "share", .kind = .directory },
        .{ .path = "share/doc", .kind = .directory },
        .{ .path = "share/doc/COPYING", .kind = .file, .digest = file_digest, .byte_length = file_bytes.len, .executable = false },
    };
    var expected = tree_module.Tree{ .gpa = gpa, .entries = @constCast(&entries) };
    try expected.validate();
    const expected_digest = try expected.digestOf(gpa);

    var expected_buffer: [digest.Digest.text_length]u8 = undefined;
    var actual_buffer: [digest.Digest.text_length]u8 = undefined;
    try std.testing.expectEqualStrings(
        expected_digest.text(&expected_buffer),
        extraction.tree_digest.text(&actual_buffer),
    );

    // The validator also reports what it read, so the round trip is not merely
    // "some digest matched": every declared entry survived, and the executable bit
    // - which is part of tree identity - came through.
    try std.testing.expectEqual(@as(usize, 5), extraction.tree.entries.len);
    var saw_executable = false;
    for (extraction.tree.entries) |entry| {
        if (std.mem.eql(u8, entry.path, "bin/jckg")) {
            try std.testing.expect(entry.executable);
            try std.testing.expectEqual(executable_bytes.len, entry.byte_length.?);
            saw_executable = true;
        }
        if (std.mem.eql(u8, entry.path, "share/doc/COPYING")) {
            try std.testing.expect(!entry.executable);
        }
    }
    try std.testing.expect(saw_executable);

    // Negative-or-recovery: a truncated archive is refused rather than extracted
    // into a tree that looks plausible.
    try std.testing.expectError(
        error.TruncatedArchive,
        archive.extractBytes(gpa, io, archive_bytes[0 .. archive_bytes.len - 700], parent, "truncated", .{}),
    );
}
