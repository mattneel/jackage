//! Secret redaction for public diagnostics (case CLI-010).
//!
//! Publication and trust work must never print credentials, and a URL that
//! carries credentials must be reported without them. Redaction is a second
//! line of defence: values are never placed in a structured document in the
//! first place.
const std = @import("std");

/// Credential shapes that are masked wherever they appear in output.
pub const Pattern = struct {
    label: []const u8,
    prefix: []const u8,
    /// Minimum number of following characters for the prefix to count as a
    /// credential rather than ordinary text.
    min_tail: usize,
};

pub const patterns = [_]Pattern{
    .{ .label = "github-token", .prefix = "ghp_", .min_tail = 16 },
    .{ .label = "github-token", .prefix = "gho_", .min_tail = 16 },
    .{ .label = "github-token", .prefix = "ghu_", .min_tail = 16 },
    .{ .label = "github-token", .prefix = "ghs_", .min_tail = 16 },
    .{ .label = "github-pat", .prefix = "github_pat_", .min_tail = 16 },
    .{ .label = "slack-token", .prefix = "xoxb-", .min_tail = 10 },
    .{ .label = "slack-token", .prefix = "xoxp-", .min_tail = 10 },
    .{ .label = "aws-access-key", .prefix = "AKIA", .min_tail = 16 },
    .{ .label = "openai-key", .prefix = "sk-", .min_tail = 16 },
    .{ .label = "bearer-token", .prefix = "Bearer ", .min_tail = 8 },
    .{ .label = "private-key", .prefix = "-----BEGIN", .min_tail = 8 },
};

pub const mask = "***";

/// Environment variable names whose values must never be echoed.
const secret_name_markers = [_][]const u8{
    "TOKEN", "SECRET", "PASSWORD", "PASSWD", "APIKEY", "API_KEY", "CREDENTIAL", "PRIVATE_KEY", "AUTH",
};

pub fn looksSecretName(name: []const u8) bool {
    var buffer: [128]u8 = undefined;
    if (name.len > buffer.len) return true;
    const upper = std.ascii.upperString(buffer[0..name.len], name);
    for (secret_name_markers) |marker| {
        if (std.mem.indexOf(u8, upper, marker) != null) return true;
    }
    return false;
}

fn isTokenChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or
        byte == '=' or byte == '/' or byte == '+' or byte == '~';
}

fn isUrlTerminator(byte: u8) bool {
    return byte == '/' or byte == '?' or byte == '#' or byte == ' ' or byte == '"' or
        byte == '\'' or byte == '>' or byte == '\n' or byte == '\r' or byte == '\t' or byte == ',';
}

/// Writes `text` with credentials removed.
///
/// Two transformations happen in one pass:
///   * the userinfo component of a URL (`scheme://user:secret@host`) becomes
///     `scheme://***@host`, keeping the host visible for diagnosis;
///   * credential-shaped tokens are replaced by `***` keeping their prefix.
pub fn redactInto(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    var index: usize = 0;
    while (index < text.len) {
        if (matchScheme(text, index)) |scheme_end| {
            const boundary = findUrlBoundary(text, scheme_end);
            const userinfo_end = std.mem.indexOfScalar(u8, text[scheme_end..boundary], '@');
            if (userinfo_end) |offset| {
                const at = scheme_end + offset;
                try writer.writeAll(text[index..scheme_end]);
                try writer.writeAll(mask);
                index = at;
                continue;
            }
        }
        if (matchPattern(text, index)) |pattern| {
            try writer.writeAll(pattern.prefix);
            index += pattern.prefix.len;
            while (index < text.len and isTokenChar(text[index])) index += 1;
            try writer.writeAll(mask);
            continue;
        }
        try writer.writeByte(text[index]);
        index += 1;
    }
}

fn matchScheme(text: []const u8, index: usize) ?usize {
    const separator = std.mem.indexOfPos(u8, text, index, "://");
    if (separator == null or separator.? != index) return null;
    return index + 3;
}

fn findUrlBoundary(text: []const u8, from: usize) usize {
    var index = from;
    while (index < text.len) : (index += 1) {
        if (isUrlTerminator(text[index])) break;
    }
    return index;
}

fn matchPattern(text: []const u8, index: usize) ?Pattern {
    for (patterns) |pattern| {
        if (!std.mem.startsWith(u8, text[index..], pattern.prefix)) continue;
        const tail_start = index + pattern.prefix.len;
        const tail = text[tail_start..];
        if (tail.len < pattern.min_tail) continue;
        var counted: usize = 0;
        while (counted < tail.len and isTokenChar(tail[counted])) counted += 1;
        if (counted < pattern.min_tail) continue;
        return pattern;
    }
    return null;
}

pub fn redactAlloc(gpa: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]u8 {
    var allocating: std.Io.Writer.Allocating = .init(gpa);
    errdefer allocating.deinit();
    redactInto(&allocating.writer, text) catch return error.OutOfMemory;
    return allocating.toOwnedSlice();
}

/// Redacts a URL for display, keeping scheme and host.
pub fn redactUrlAlloc(gpa: std.mem.Allocator, url: []const u8) std.mem.Allocator.Error![]u8 {
    return redactAlloc(gpa, url);
}

test "m01/CLI-010 keep secrets out of errors" {
    std.debug.print("JCKG_EVIDENCE CLI-010\n", .{});
    const gpa = std.testing.allocator;

    const with_credentials = "failed to reach https://octocat:ghp_abcdefghijklmnopqrstuvwx@github.com/org/repo.git";
    const redacted = try redactAlloc(gpa, with_credentials);
    defer gpa.free(redacted);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "ghp_abcdefghijklmnopqrstuvwx") == null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "octocat") == null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "***@github.com/org/repo.git") != null);

    const samples = [_][]const u8{
        "export GITHUB_TOKEN=ghp_1234567890abcdefghij",
        "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9",
        "aws AKIAIOSFODNN7EXAMPLE key",
        "slack xoxb-1234567890-abcdefghij",
        "pat github_pat_11ABCDEFG0123456789",
    };
    for (samples) |sample| {
        const cleaned = try redactAlloc(gpa, sample);
        defer gpa.free(cleaned);
        try std.testing.expect(std.mem.indexOf(u8, cleaned, mask) != null);
        try std.testing.expect(std.mem.indexOf(u8, cleaned, "1234567890abcdefghij") == null);
        try std.testing.expect(std.mem.indexOf(u8, cleaned, "AKIAIOSFODNN7EXAMPLE") == null);
        try std.testing.expect(std.mem.indexOf(u8, cleaned, "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9") == null);
        try std.testing.expect(std.mem.indexOf(u8, cleaned, "github_pat_11ABCDEFG0123456789") == null);
    }

    // Negative-or-recovery: ordinary text is preserved byte for byte, and a
    // short lookalike is not treated as a credential.
    const ordinary = "repository https://example.invalid/org/repo.git is not enrolled; run jckg repo add";
    const untouched = try redactAlloc(gpa, ordinary);
    defer gpa.free(untouched);
    try std.testing.expectEqualStrings(ordinary, untouched);

    const lookalike = "ghp_short";
    const kept = try redactAlloc(gpa, lookalike);
    defer gpa.free(kept);
    try std.testing.expectEqualStrings(lookalike, kept);

    try std.testing.expect(looksSecretName("JCKG_GITHUB_TOKEN"));
    try std.testing.expect(looksSecretName("AWS_SECRET_ACCESS_KEY"));
    try std.testing.expect(looksSecretName("NPM_PASSWORD"));
    try std.testing.expect(looksSecretName("SIGNING_PRIVATE_KEY"));
    try std.testing.expect(!looksSecretName("PATH"));
    try std.testing.expect(!looksSecretName("TEMP"));
    try std.testing.expect(!looksSecretName("JCKG_STORE_ROOT"));
}
