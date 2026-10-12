//! Version policy for resolution (documented SemVer subset).
//!
//! The subset is deliberately small and fully specified here: three numeric
//! components, an optional dot-separated prerelease, no build metadata, and
//! three requirement forms (exact, caret, tilde) plus `*`. Prerelease versions
//! never satisfy a caret or tilde requirement, and are selected only by an
//! exact requirement, so a locked prerelease stays explicit.
const std = @import("std");

pub const Error = error{
    InvalidVersion,
    InvalidRequirement,
};

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
    /// Prerelease text without the leading `-`, borrowed from the parsed input.
    prerelease: []const u8 = "",

    pub fn parse(raw: []const u8) Error!Version {
        if (raw.len == 0) return error.InvalidVersion;
        if (std.mem.indexOfScalar(u8, raw, '+') != null) return error.InvalidVersion;

        var core = raw;
        var prerelease: []const u8 = "";
        if (std.mem.indexOfScalar(u8, raw, '-')) |separator| {
            core = raw[0..separator];
            prerelease = raw[separator + 1 ..];
            if (prerelease.len == 0) return error.InvalidVersion;
        }

        var components = std.mem.splitScalar(u8, core, '.');
        const major = parseComponent(components.next() orelse return error.InvalidVersion) orelse return error.InvalidVersion;
        const minor = parseComponent(components.next() orelse return error.InvalidVersion) orelse return error.InvalidVersion;
        const patch = parseComponent(components.next() orelse return error.InvalidVersion) orelse return error.InvalidVersion;
        if (components.next() != null) return error.InvalidVersion;

        for (prerelease) |byte| {
            const allowed = std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '-';
            if (!allowed) return error.InvalidVersion;
        }
        return .{ .major = major, .minor = minor, .patch = patch, .prerelease = prerelease };
    }

    fn parseComponent(raw: []const u8) ?u32 {
        if (raw.len == 0) return null;
        if (raw.len > 1 and raw[0] == '0') return null;
        for (raw) |byte| {
            if (!std.ascii.isDigit(byte)) return null;
        }
        return std.fmt.parseInt(u32, raw, 10) catch null;
    }

    pub fn text(self: Version, buffer: []u8) []const u8 {
        if (self.prerelease.len == 0) {
            return std.mem.print(buffer, "{d}.{d}.{d}", .{ self.major, self.minor, self.patch }) catch buffer[0..0];
        }
        return std.mem.print(buffer, "{d}.{d}.{d}-{s}", .{ self.major, self.minor, self.patch, self.prerelease }) catch buffer[0..0];
    }

    pub fn eql(a: Version, b: Version) bool {
        return a.major == b.major and a.minor == b.minor and a.patch == b.patch and
            std.mem.eql(u8, a.prerelease, b.prerelease);
    }

    pub fn compare(a: Version, b: Version) std.math.Order {
        if (a.major != b.major) return if (a.major < b.major) .lt else .gt;
        if (a.minor != b.minor) return if (a.minor < b.minor) .lt else .gt;
        if (a.patch != b.patch) return if (a.patch < b.patch) .lt else .gt;
        if (a.prerelease.len == 0 and b.prerelease.len == 0) return .eq;
        // A release version outranks any of its prereleases.
        if (a.prerelease.len == 0) return .gt;
        if (b.prerelease.len == 0) return .lt;
        return comparePrerelease(a.prerelease, b.prerelease);
    }
};

fn comparePrerelease(a: []const u8, b: []const u8) std.math.Order {
    var left = std.mem.splitScalar(u8, a, '.');
    var right = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const left_part = left.next();
        const right_part = right.next();
        if (left_part == null and right_part == null) return .eq;
        if (left_part == null) return .lt;
        if (right_part == null) return .gt;
        const left_text = left_part.?;
        const right_text = right_part.?;
        const left_number = std.fmt.parseInt(u32, left_text, 10) catch null;
        const right_number = std.fmt.parseInt(u32, right_text, 10) catch null;
        if (left_number != null and right_number != null) {
            if (left_number.? != right_number.?) {
                return if (left_number.? < right_number.?) .lt else .gt;
            }
            continue;
        }
        // Numeric identifiers rank below alphanumeric ones.
        if (left_number != null) return .lt;
        if (right_number != null) return .gt;
        switch (std.mem.order(u8, left_text, right_text)) {
            .lt => return .lt,
            .gt => return .gt,
            .eq => continue,
        }
    }
}

pub const Requirement = union(enum) {
    /// Exactly this version.
    exact: Version,
    /// Same major, and same minor while major is zero.
    caret: Version,
    /// Same major and minor.
    tilde: Version,
    /// Any version, including a prerelease.
    any,

    pub fn parse(raw: []const u8) Error!Requirement {
        if (raw.len == 0) return error.InvalidRequirement;
        if (std.mem.eql(u8, raw, "*")) return .any;
        if (raw[0] == '^') return .{ .caret = Version.parse(raw[1..]) catch return error.InvalidRequirement };
        if (raw[0] == '~') return .{ .tilde = Version.parse(raw[1..]) catch return error.InvalidRequirement };
        return .{ .exact = Version.parse(raw) catch return error.InvalidRequirement };
    }

    pub fn text(self: Requirement, buffer: []u8) []const u8 {
        return switch (self) {
            .any => "*",
            .exact => |version| std.mem.print(buffer, "{s}", .{version.text(buffer[buffer.len / 2 ..])}) catch buffer[0..0],
            .caret => |version| blk: {
                var inner: [32]u8 = undefined;
                break :blk std.mem.print(buffer, "^{s}", .{version.text(&inner)}) catch buffer[0..0];
            },
            .tilde => |version| blk: {
                var inner: [32]u8 = undefined;
                break :blk std.mem.print(buffer, "~{s}", .{version.text(&inner)}) catch buffer[0..0];
            },
        };
    }

    /// Whether `version` satisfies this requirement.
    pub fn satisfiedBy(self: Requirement, version: Version) bool {
        return switch (self) {
            .any => true,
            .exact => |wanted| wanted.eql(version),
            .caret => |base| caretSatisfied(base, version),
            .tilde => |base| tildeSatisfied(base, version),
        };
    }
};

fn caretSatisfied(base: Version, version: Version) bool {
    if (base.prerelease.len != 0) return base.eql(version);
    if (version.prerelease.len != 0) return false;
    if (version.compare(base) == .lt) return false;
    if (base.major > 0) return version.major == base.major;
    if (base.minor > 0) return version.major == 0 and version.minor == base.minor;
    return version.major == 0 and version.minor == 0 and version.patch == base.patch;
}

fn tildeSatisfied(base: Version, version: Version) bool {
    if (base.prerelease.len != 0) return base.eql(version);
    if (version.prerelease.len != 0) return false;
    if (version.compare(base) == .lt) return false;
    return version.major == base.major and version.minor == base.minor;
}

test "m05/version parsing and precedence" {
    var buffer: [64]u8 = undefined;

    const stable = try Version.parse("1.2.3");
    try std.testing.expectEqualStrings("1.2.3", stable.text(&buffer));
    const prerelease = try Version.parse("1.2.3-alpha.1");
    try std.testing.expectEqualStrings("1.2.3-alpha.1", prerelease.text(&buffer));

    try std.testing.expectEqual(std.math.Order.lt, Version.compare(try Version.parse("1.2.3"), try Version.parse("1.2.4")));
    try std.testing.expectEqual(std.math.Order.lt, Version.compare(try Version.parse("1.2.3-alpha"), try Version.parse("1.2.3")));
    try std.testing.expectEqual(std.math.Order.lt, Version.compare(try Version.parse("1.2.3-alpha.1"), try Version.parse("1.2.3-alpha.2")));
    try std.testing.expectEqual(std.math.Order.lt, Version.compare(try Version.parse("1.2.3-alpha.1"), try Version.parse("1.2.3-alpha.beta")));
    try std.testing.expectEqual(std.math.Order.eq, Version.compare(try Version.parse("2.0.0"), try Version.parse("2.0.0")));

    try std.testing.expectError(error.InvalidVersion, Version.parse("1.2"));
    try std.testing.expectError(error.InvalidVersion, Version.parse("1.2.3.4"));
    try std.testing.expectError(error.InvalidVersion, Version.parse("01.2.3"));
    try std.testing.expectError(error.InvalidVersion, Version.parse("1.2.3+build"));
    try std.testing.expectError(error.InvalidVersion, Version.parse(""));
}

test "m05/requirement satisfaction" {
    var buffer: [64]u8 = undefined;
    const exact = try Requirement.parse("1.2.3");
    try std.testing.expect(exact.satisfiedBy(try Version.parse("1.2.3")));
    try std.testing.expect(!exact.satisfiedBy(try Version.parse("1.2.4")));
    try std.testing.expectEqualStrings("1.2.3", exact.text(&buffer));

    const caret = try Requirement.parse("^1.2.3");
    try std.testing.expect(caret.satisfiedBy(try Version.parse("1.9.0")));
    try std.testing.expect(!caret.satisfiedBy(try Version.parse("2.0.0")));
    try std.testing.expect(!caret.satisfiedBy(try Version.parse("1.2.2")));
    // A prerelease never satisfies a caret requirement.
    try std.testing.expect(!caret.satisfiedBy(try Version.parse("1.3.0-rc.1")));
    // A prerelease base only matches itself.
    const caret_pre = try Requirement.parse("^1.2.3-rc.1");
    try std.testing.expect(caret_pre.satisfiedBy(try Version.parse("1.2.3-rc.1")));
    try std.testing.expect(!caret_pre.satisfiedBy(try Version.parse("1.2.3")));

    const tilde = try Requirement.parse("~1.2.3");
    try std.testing.expect(tilde.satisfiedBy(try Version.parse("1.2.9")));
    try std.testing.expect(!tilde.satisfiedBy(try Version.parse("1.3.0")));

    const any = try Requirement.parse("*");
    try std.testing.expect(any.satisfiedBy(try Version.parse("0.0.1")));
    try std.testing.expectEqualStrings("*", any.text(&buffer));

    try std.testing.expectError(error.InvalidRequirement, Requirement.parse("^"));
    try std.testing.expectError(error.InvalidRequirement, Requirement.parse(""));
}
