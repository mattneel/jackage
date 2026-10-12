//! Canonical JSON for Jackage identities (`jckg-json-v1`).
//!
//! The encoder is deliberately independent of the standard library's JSON
//! writer: identities must be stable byte for byte across versions, and the
//! accepted value domain is narrower than JSON (no floats, no negative zero,
//! no integer beyond the safe range, no unpaired surrogate, no duplicate key,
//! no normalization). The parser rejects any input outside that domain.
const std = @import("std");

pub const max_safe_integer: i64 = 9007199254740991;

pub const Error = error{
    UnexpectedEndOfInput,
    SyntaxError,
    DuplicateKey,
    FloatNotAllowed,
    NegativeZero,
    UnsafeInteger,
    UnpairedSurrogate,
    InvalidUnicode,
    UnsupportedValue,
    UnsortedObject,
    NestingTooDeep,
    OutOfMemory,
};

pub const Diagnostic = struct {
    code: Error = error.SyntaxError,
    /// Byte offset of the problem in the raw input.
    offset: usize = 0,
    detail: []const u8 = "",
};

pub const Entry = struct {
    key: []const u8,
    value: Value,
};

pub const Value = union(enum) {
    null,
    boolean: bool,
    integer: i64,
    string: []const u8,
    array: []Value,
    object: []Entry,

    pub fn deinit(self: Value, gpa: std.mem.Allocator) void {
        switch (self) {
            .string => |text| gpa.free(text),
            .array => |items| {
                for (items) |item| item.deinit(gpa);
                gpa.free(items);
            },
            .object => |entries| {
                for (entries) |entry| {
                    gpa.free(entry.key);
                    entry.value.deinit(gpa);
                }
                gpa.free(entries);
            },
            else => {},
        }
    }

    /// Deep copy, so a caller can own a canonical value it did not build.
    pub fn clone(self: Value, gpa: std.mem.Allocator) std.mem.Allocator.Error!Value {
        return switch (self) {
            .null => .null,
            .boolean => |flag| .{ .boolean = flag },
            .integer => |number| .{ .integer = number },
            .string => |text| .{ .string = try gpa.dupe(u8, text) },
            .array => |items| blk: {
                const copy = try gpa.alloc(Value, items.len);
                var filled: usize = 0;
                errdefer {
                    for (copy[0..filled]) |item| item.deinit(gpa);
                    gpa.free(copy);
                }
                for (items, 0..) |item, index| {
                    copy[index] = try item.clone(gpa);
                    filled += 1;
                }
                break :blk .{ .array = copy };
            },
            .object => |entries| blk: {
                const copy = try gpa.alloc(Entry, entries.len);
                var filled: usize = 0;
                errdefer {
                    for (copy[0..filled]) |entry| {
                        gpa.free(entry.key);
                        entry.value.deinit(gpa);
                    }
                    gpa.free(copy);
                }
                for (entries, 0..) |entry, index| {
                    copy[index] = .{ .key = try gpa.dupe(u8, entry.key), .value = try entry.value.clone(gpa) };
                    filled += 1;
                }
                break :blk .{ .object = copy };
            },
        };
    }
};

fn entryLessThan(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.key, b.key);
}

/// Sorts object keys by their UTF-8 bytes, recursively. Arrays keep order.
pub fn canonicalize(value: *Value) void {
    switch (value.*) {
        .array => |items| for (items) |*item| canonicalize(item),
        .object => |entries| {
            std.mem.sort(Entry, entries, {}, entryLessThan);
            for (entries) |*entry| canonicalize(&entry.value);
        },
        else => {},
    }
}

pub fn isCanonical(value: Value) bool {
    return switch (value) {
        .array => |items| for (items) |item| {
            if (!isCanonical(item)) break false;
        } else true,
        .object => |entries| blk: {
            var previous: ?[]const u8 = null;
            for (entries) |entry| {
                if (previous) |key| {
                    if (!std.mem.lessThan(u8, key, entry.key)) break :blk false;
                }
                if (!isCanonical(entry.value)) break :blk false;
                previous = entry.key;
            }
            break :blk true;
        },
        else => true,
    };
}

const hex_digits = "0123456789abcdef";

fn encodeString(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    for (text) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            0x08 => try writer.writeAll("\\b"),
            '\t' => try writer.writeAll("\\t"),
            '\n' => try writer.writeAll("\\n"),
            0x0c => try writer.writeAll("\\f"),
            '\r' => try writer.writeAll("\\r"),
            0x00...0x07, 0x0b, 0x0e...0x1f => {
                try writer.writeAll("\\u00");
                try writer.writeByte(hex_digits[byte >> 4]);
                try writer.writeByte(hex_digits[byte & 0xf]);
            },
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

/// Writes the canonical encoding of `value`.
///
/// Object entries must already be sorted (see `canonicalize`); an unsorted
/// object is an error rather than something this function silently repairs,
/// because a silent repair would hide a caller that computed an identity from
/// a differently ordered value.
pub fn encode(value: Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .boolean => |flag| try writer.writeAll(if (flag) "true" else "false"),
        .integer => |number| try writer.print("{d}", .{number}),
        .string => |text| try encodeString(writer, text),
        .array => |items| {
            try writer.writeByte('[');
            for (items, 0..) |item, index| {
                if (index != 0) try writer.writeByte(',');
                try encode(item, writer);
            }
            try writer.writeByte(']');
        },
        .object => |entries| {
            try writer.writeByte('{');
            for (entries, 0..) |entry, index| {
                if (index != 0) try writer.writeByte(',');
                try encodeString(writer, entry.key);
                try writer.writeByte(':');
                try encode(entry.value, writer);
            }
            try writer.writeByte('}');
        },
    }
}

pub fn encodeAlloc(gpa: std.mem.Allocator, value: Value) std.mem.Allocator.Error![]u8 {
    var allocating: std.Io.Writer.Allocating = .init(gpa);
    errdefer allocating.deinit();
    encode(value, &allocating.writer) catch return error.OutOfMemory;
    return allocating.toOwnedSlice();
}

const max_depth = 128;

const Parser = struct {
    text: []const u8,
    index: usize = 0,
    gpa: std.mem.Allocator,
    diagnostic: *Diagnostic,

    fn fail(self: *Parser, code: Error, detail: []const u8) Error {
        self.diagnostic.* = .{ .code = code, .offset = self.index, .detail = detail };
        return code;
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.index < self.text.len) : (self.index += 1) {
            switch (self.text[self.index]) {
                ' ', '\t', '\n', '\r' => {},
                else => return,
            }
        }
    }

    fn peek(self: *Parser) ?u8 {
        if (self.index >= self.text.len) return null;
        return self.text[self.index];
    }

    fn parseValue(self: *Parser, depth: usize) Error!Value {
        if (depth > max_depth) return self.fail(error.NestingTooDeep, "value nests deeper than the accepted limit");
        self.skipWhitespace();
        const byte = self.peek() orelse return self.fail(error.UnexpectedEndOfInput, "value expected");
        return switch (byte) {
            'n' => self.parseLiteral("null", .null),
            't' => self.parseLiteral("true", .{ .boolean = true }),
            'f' => self.parseLiteral("false", .{ .boolean = false }),
            '"' => .{ .string = try self.parseString() },
            '[' => self.parseArray(depth),
            '{' => self.parseObject(depth),
            '-', '0'...'9' => self.parseNumber(),
            else => self.fail(error.SyntaxError, "unexpected character where a value was expected"),
        };
    }

    fn parseLiteral(self: *Parser, literal: []const u8, value: Value) Error!Value {
        if (!std.mem.startsWith(u8, self.text[self.index..], literal)) {
            return self.fail(error.SyntaxError, "unknown literal");
        }
        self.index += literal.len;
        return value;
    }

    fn parseNumber(self: *Parser) Error!Value {
        const start = self.index;
        while (self.index < self.text.len) : (self.index += 1) {
            switch (self.text[self.index]) {
                '-', '+', '.', 'e', 'E', '0'...'9' => {},
                else => break,
            }
        }
        const raw = self.text[start..self.index];
        if (raw.len == 0) return self.fail(error.SyntaxError, "empty number");
        if (std.mem.indexOfAny(u8, raw, ".eE") != null) {
            return self.fail(error.FloatNotAllowed, "floating point values are outside the canonical domain");
        }
        if (std.mem.eql(u8, raw, "-0")) return self.fail(error.NegativeZero, "negative zero is not a canonical value");
        // JSON integer grammar: -?(0|[1-9][0-9]*). `parseInt` alone would
        // accept spellings such as "01" or "1-2".
        var cursor: usize = 0;
        if (raw[0] == '-') cursor = 1;
        if (cursor >= raw.len) return self.fail(error.SyntaxError, "malformed integer");
        if (raw[cursor] == '0' and raw.len - cursor > 1) {
            return self.fail(error.SyntaxError, "leading zeros are not valid JSON");
        }
        for (raw[cursor..]) |digit| {
            if (!std.ascii.isDigit(digit)) return self.fail(error.SyntaxError, "malformed integer");
        }
        const number = std.fmt.parseInt(i64, raw, 10) catch |err| switch (err) {
            error.Overflow => return self.fail(error.UnsafeInteger, "integer is outside the safe range"),
            else => return self.fail(error.SyntaxError, "malformed integer"),
        };
        if (number > max_safe_integer or number < -max_safe_integer) {
            return self.fail(error.UnsafeInteger, "integer is outside the safe range");
        }
        return .{ .integer = number };
    }

    fn parseString(self: *Parser) Error![]const u8 {
        std.debug.assert(self.peek() == '"');
        self.index += 1;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.gpa);
        while (true) {
            const byte = self.peek() orelse return self.fail(error.UnexpectedEndOfInput, "unterminated string");
            if (byte == '"') {
                self.index += 1;
                break;
            }
            if (byte == '\\') {
                self.index += 1;
                const escape = self.peek() orelse return self.fail(error.UnexpectedEndOfInput, "unterminated escape");
                self.index += 1;
                switch (escape) {
                    '"' => try out.append(self.gpa, '"'),
                    '\\' => try out.append(self.gpa, '\\'),
                    '/' => try out.append(self.gpa, '/'),
                    'b' => try out.append(self.gpa, 0x08),
                    'f' => try out.append(self.gpa, 0x0c),
                    'n' => try out.append(self.gpa, '\n'),
                    'r' => try out.append(self.gpa, '\r'),
                    't' => try out.append(self.gpa, '\t'),
                    'u' => try self.parseUnicodeEscape(&out),
                    else => return self.fail(error.SyntaxError, "unknown escape sequence"),
                }
                continue;
            }
            if (byte < 0x20) return self.fail(error.SyntaxError, "unescaped control character in string");
            try out.append(self.gpa, byte);
            self.index += 1;
        }
        const text = try out.toOwnedSlice(self.gpa);
        if (!std.unicode.utf8ValidateSlice(text)) {
            self.gpa.free(text);
            return self.fail(error.InvalidUnicode, "string is not valid UTF-8");
        }
        return text;
    }

    fn readHex4(self: *Parser) Error!u16 {
        if (self.index + 4 > self.text.len) return self.fail(error.UnexpectedEndOfInput, "truncated \\u escape");
        var value: u16 = 0;
        for (self.text[self.index .. self.index + 4]) |digit| {
            const nibble = std.fmt.charToDigit(digit, 16) catch return self.fail(error.SyntaxError, "\\u escape needs four hex digits");
            value = value * 16 + nibble;
        }
        self.index += 4;
        return value;
    }

    fn parseUnicodeEscape(self: *Parser, out: *std.ArrayList(u8)) Error!void {
        const first = try self.readHex4();
        var code_point: u21 = first;
        if (first >= 0xd800 and first <= 0xdbff) {
            // High surrogate: a low surrogate must follow immediately.
            if (self.index + 2 > self.text.len or self.text[self.index] != '\\' or self.text[self.index + 1] != 'u') {
                return self.fail(error.UnpairedSurrogate, "high surrogate without a following low surrogate");
            }
            self.index += 2;
            const second = try self.readHex4();
            if (second < 0xdc00 or second > 0xdfff) {
                return self.fail(error.UnpairedSurrogate, "high surrogate followed by a non-surrogate");
            }
            code_point = 0x10000 + ((@as(u21, first - 0xd800)) << 10) + (second - 0xdc00);
        } else if (first >= 0xdc00 and first <= 0xdfff) {
            return self.fail(error.UnpairedSurrogate, "low surrogate without a preceding high surrogate");
        }
        var buffer: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(code_point, &buffer) catch return self.fail(error.InvalidUnicode, "code point cannot be encoded");
        try out.appendSlice(self.gpa, buffer[0..length]);
    }

    fn parseArray(self: *Parser, depth: usize) Error!Value {
        self.index += 1;
        var items: std.ArrayList(Value) = .empty;
        errdefer {
            for (items.items) |item| item.deinit(self.gpa);
            items.deinit(self.gpa);
        }
        self.skipWhitespace();
        if (self.peek() == ']') {
            self.index += 1;
            return .{ .array = try items.toOwnedSlice(self.gpa) };
        }
        while (true) {
            try items.append(self.gpa, try self.parseValue(depth + 1));
            self.skipWhitespace();
            const byte = self.peek() orelse return self.fail(error.UnexpectedEndOfInput, "unterminated array");
            if (byte == ',') {
                self.index += 1;
                continue;
            }
            if (byte == ']') {
                self.index += 1;
                return .{ .array = try items.toOwnedSlice(self.gpa) };
            }
            return self.fail(error.SyntaxError, "expected ',' or ']' in array");
        }
    }

    fn parseObject(self: *Parser, depth: usize) Error!Value {
        self.index += 1;
        var entries: std.ArrayList(Entry) = .empty;
        errdefer {
            for (entries.items) |entry| {
                self.gpa.free(entry.key);
                entry.value.deinit(self.gpa);
            }
            entries.deinit(self.gpa);
        }
        self.skipWhitespace();
        if (self.peek() == '}') {
            self.index += 1;
            return .{ .object = try entries.toOwnedSlice(self.gpa) };
        }
        while (true) {
            self.skipWhitespace();
            if (self.peek() != '"') return self.fail(error.SyntaxError, "object key must be a string");
            const key = try self.parseString();
            errdefer self.gpa.free(key);
            self.skipWhitespace();
            if (self.peek() != ':') return self.fail(error.SyntaxError, "expected ':' after the object key");
            self.index += 1;
            const value = try self.parseValue(depth + 1);

            // Duplicate keys are rejected before any encoding or identity work.
            for (entries.items) |existing| {
                if (std.mem.eql(u8, existing.key, key)) {
                    // The key is released by the errdefer above; the parsed
                    // value has no owner yet, so it is released here.
                    value.deinit(self.gpa);
                    self.diagnostic.detail = "duplicate object key";
                    return error.DuplicateKey;
                }
            }
            try entries.append(self.gpa, .{ .key = key, .value = value });

            self.skipWhitespace();
            const byte = self.peek() orelse return self.fail(error.UnexpectedEndOfInput, "unterminated object");
            if (byte == ',') {
                self.index += 1;
                continue;
            }
            if (byte == '}') {
                self.index += 1;
                canonicalizeObject(entries.items);
                return .{ .object = try entries.toOwnedSlice(self.gpa) };
            }
            return self.fail(error.SyntaxError, "expected ',' or '}' in object");
        }
    }
};

fn canonicalizeObject(entries: []Entry) void {
    std.mem.sort(Entry, entries, {}, entryLessThan);
}

/// Parses raw JSON text into a canonical value: keys are sorted, and any
/// input outside the accepted domain is rejected with a positioned diagnostic.
pub fn parse(gpa: std.mem.Allocator, text: []const u8, diagnostic: *Diagnostic) Error!Value {
    var parser = Parser{ .text = text, .gpa = gpa, .diagnostic = diagnostic };
    const value = try parser.parseValue(0);
    errdefer value.deinit(gpa);
    parser.skipWhitespace();
    if (parser.index != text.len) {
        parser.diagnostic.* = .{ .code = error.SyntaxError, .offset = parser.index, .detail = "trailing data after the value" };
        return error.SyntaxError;
    }
    return value;
}

/// Convenience helper: parse and encode, returning the canonical bytes.
pub fn canonicalBytes(gpa: std.mem.Allocator, text: []const u8, diagnostic: *Diagnostic) Error![]u8 {
    const value = try parse(gpa, text, diagnostic);
    defer value.deinit(gpa);
    return encodeAlloc(gpa, value);
}

pub const fixture_path = ".jackage-delivery/fixtures/canonical-vectors.json";
pub const invalid_fixture_path = ".jackage-delivery/fixtures/invalid-canonical-json.json";

fn hexToBytes(gpa: std.mem.Allocator, hex: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, hex.len / 2);
    _ = try std.fmt.hexToBytes(out, hex);
    return out;
}

test "m02/CAN-001 canonical object order" {
    std.debug.print("JCKG_EVIDENCE CAN-001\n", .{});
    const gpa = std.testing.allocator;

    // Equal key/value pairs in different textual orders produce identical bytes.
    var first_diagnostic: Diagnostic = .{};
    const first = try canonicalBytes(gpa, "{\"z\":1,\"a\":2,\"m\":[1,2]}", &first_diagnostic);
    defer gpa.free(first);
    var second_diagnostic: Diagnostic = .{};
    const second = try canonicalBytes(gpa, "  {  \"m\" : [ 1 , 2 ] , \"a\":2,\"z\":1 }  ", &second_diagnostic);
    defer gpa.free(second);
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expectEqualStrings("{\"a\":2,\"m\":[1,2],\"z\":1}", first);

    // A value built in a different order canonicalizes to the same bytes.
    var parsed = try parse(gpa, "{\"z\":1,\"a\":2}", &second_diagnostic);
    defer parsed.deinit(gpa);
    canonicalize(&parsed);
    const reordered = try encodeAlloc(gpa, parsed);
    defer gpa.free(reordered);
    try std.testing.expectEqualStrings("{\"a\":2,\"z\":1}", reordered);
    try std.testing.expect(isCanonical(parsed));

    // A caller-supplied unsorted object is detected, not silently reordered.
    const unsorted = Value{ .object = @constCast(&[_]Entry{
        .{ .key = "z", .value = .{ .integer = 1 } },
        .{ .key = "a", .value = .{ .integer = 2 } },
    }) };
    try std.testing.expect(!isCanonical(unsorted));

    // Negative-or-recovery: keys sort by UTF-8 byte sequence, not by locale.
    // U+00E9 (c3 a9) sorts after all ASCII keys; U+1F600 (f0 9f 98 80) sorts last.
    var mixed_diagnostic: Diagnostic = .{};
    const mixed = try canonicalBytes(gpa, "{\"😀\":2,\"é\":1,\"a\":3}", &mixed_diagnostic);
    defer gpa.free(mixed);
    try std.testing.expectEqualStrings("{\"a\":3,\"é\":1,\"😀\":2}", mixed);
}

const Decode = struct {
    /// Converts a parsed JSON document into the canonical value domain.
    fn decodeValue(gpa: std.mem.Allocator, source: std.json.Value) Error!Value {
        return switch (source) {
            .null => .null,
            .bool => |flag| .{ .boolean = flag },
            .integer => |number| if (number > max_safe_integer or number < -max_safe_integer)
                error.UnsafeInteger
            else
                .{ .integer = number },
            .float, .number_string => error.FloatNotAllowed,
            .string => |text| .{ .string = try gpa.dupe(u8, text) },
            .array => |items| blk: {
                const values = try gpa.alloc(Value, items.items.len);
                errdefer gpa.free(values);
                for (items.items, 0..) |item, index| values[index] = try decodeValue(gpa, item);
                break :blk .{ .array = values };
            },
            .object => |map| blk: {
                const entries = try gpa.alloc(Entry, map.count());
                errdefer gpa.free(entries);
                var index: usize = 0;
                var iterator = map.iterator();
                while (iterator.next()) |item| : (index += 1) {
                    entries[index] = .{
                        .key = try gpa.dupe(u8, item.key_ptr.*),
                        .value = try decodeValue(gpa, item.value_ptr.*),
                    };
                }
                std.mem.sort(Entry, entries, {}, entryLessThan);
                break :blk .{ .object = entries };
            },
        };
    }
};

fn fixtureVectors(gpa: std.mem.Allocator, path: []const u8) !std.json.Parsed(std.json.Value) {
    const io = std.testing.io;
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(text);
    return try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
}

test "m02/canonical encoding matches every fixture vector" {
    const gpa = std.testing.allocator;
    var document = try fixtureVectors(gpa, fixture_path);
    defer document.deinit();
    const vectors = document.value.object.get("vectors").?.array.items;
    try std.testing.expectEqual(@as(usize, 15), vectors.len);

    for (vectors) |vector| {
        const id = vector.object.get("id").?.string;
        const expected_hex = vector.object.get("canonicalUtf8Hex").?.string;
        var diagnostic: Diagnostic = .{};
        const value = Decode.decodeValue(gpa, vector.object.get("value").?) catch |err| {
            std.debug.print("vector {s}: decode failed: {s}\n", .{ id, @errorName(err) });
            return err;
        };
        defer value.deinit(gpa);

        const encoded = try encodeAlloc(gpa, value);
        defer gpa.free(encoded);
        const expected = try hexToBytes(gpa, expected_hex);
        defer gpa.free(expected);
        if (!std.mem.eql(u8, encoded, expected)) {
            std.debug.print("vector {s}: encoded '{s}' but the fixture expects '{s}'\n", .{ id, encoded, expected });
            return error.VectorMismatch;
        }
        try std.testing.expect(isCanonical(value));
        _ = &diagnostic;
    }
}

test "m02/CAN-002 preserve array order" {
    std.debug.print("JCKG_EVIDENCE CAN-002\n", .{});
    const gpa = std.testing.allocator;
    var diagnostic: Diagnostic = .{};

    const ascending = try canonicalBytes(gpa, "[1,2,3]", &diagnostic);
    defer gpa.free(ascending);
    const descending = try canonicalBytes(gpa, "[3,2,1]", &diagnostic);
    defer gpa.free(descending);
    try std.testing.expectEqualStrings("[1,2,3]", ascending);
    try std.testing.expectEqualStrings("[3,2,1]", descending);
    // Equal elements in a different order are different values.
    try std.testing.expect(!std.mem.eql(u8, ascending, descending));

    // The same rule holds inside objects and nested arrays: only keys are
    // ordered, never array elements.
    const nested_a = try canonicalBytes(gpa, "{\"z\":{\"b\":[2,1]},\"a\":[[1],[2]]}", &diagnostic);
    defer gpa.free(nested_a);
    const nested_b = try canonicalBytes(gpa, "{\"a\":[[1],[2]],\"z\":{\"b\":[1,2]}}", &diagnostic);
    defer gpa.free(nested_b);
    try std.testing.expectEqualStrings("{\"a\":[[1],[2]],\"z\":{\"b\":[2,1]}}", nested_a);
    try std.testing.expect(!std.mem.eql(u8, nested_a, nested_b));

    // Negative-or-recovery: duplicate array elements are preserved rather than
    // collapsed into a set.
    const duplicated = try canonicalBytes(gpa, "[1,1,2]", &diagnostic);
    defer gpa.free(duplicated);
    try std.testing.expectEqualStrings("[1,1,2]", duplicated);

    // Empty containers keep their distinct identities.
    const empty_array = try canonicalBytes(gpa, "[]", &diagnostic);
    defer gpa.free(empty_array);
    const empty_object = try canonicalBytes(gpa, "{}", &diagnostic);
    defer gpa.free(empty_object);
    try std.testing.expectEqualStrings("[]", empty_array);
    try std.testing.expectEqualStrings("{}", empty_object);
}

test "m02/CAN-003 reject invalid numbers" {
    std.debug.print("JCKG_EVIDENCE CAN-003\n", .{});
    const gpa = std.testing.allocator;
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(error.FloatNotAllowed, parse(gpa, "1.0", &diagnostic));
    try std.testing.expectError(error.FloatNotAllowed, parse(gpa, "1e3", &diagnostic));
    try std.testing.expectError(error.FloatNotAllowed, parse(gpa, "-0.5", &diagnostic));
    try std.testing.expectError(error.NegativeZero, parse(gpa, "-0", &diagnostic));
    try std.testing.expectError(error.UnsafeInteger, parse(gpa, "9007199254740992", &diagnostic));
    try std.testing.expectError(error.UnsafeInteger, parse(gpa, "-9007199254740992", &diagnostic));
    try std.testing.expectError(error.UnsafeInteger, parse(gpa, "99999999999999999999999", &diagnostic));
    try std.testing.expectError(error.SyntaxError, parse(gpa, "NaN", &diagnostic));
    try std.testing.expectError(error.SyntaxError, parse(gpa, "Infinity", &diagnostic));
    try std.testing.expectError(error.SyntaxError, parse(gpa, "01", &diagnostic));
    try std.testing.expectError(error.SyntaxError, parse(gpa, "+1", &diagnostic));
    try std.testing.expectError(error.UnexpectedEndOfInput, parse(gpa, "", &diagnostic));
    try std.testing.expectError(error.SyntaxError, parse(gpa, "1 2", &diagnostic));

    // The diagnostic points at the offending byte, not just at the input.
    _ = parse(gpa, "[1, 2.5]", &diagnostic) catch {};
    try std.testing.expectEqual(error.FloatNotAllowed, diagnostic.code);
    try std.testing.expect(diagnostic.offset >= 3);

    // Exact boundary values are accepted.
    const maximum = try canonicalBytes(gpa, "9007199254740991", &diagnostic);
    defer gpa.free(maximum);
    try std.testing.expectEqualStrings("9007199254740991", maximum);
    const minimum = try canonicalBytes(gpa, "-9007199254740991", &diagnostic);
    defer gpa.free(minimum);
    try std.testing.expectEqualStrings("-9007199254740991", minimum);
    const zero = try canonicalBytes(gpa, "0", &diagnostic);
    defer gpa.free(zero);
    try std.testing.expectEqualStrings("0", zero);

    // Every fixture rejection vector is rejected with the documented reason.
    var document = try fixtureVectors(gpa, invalid_fixture_path);
    defer document.deinit();
    const vectors = document.value.object.get("vectors").?.array.items;
    try std.testing.expectEqual(@as(usize, 8), vectors.len);
    for (vectors) |vector| {
        const text = vector.object.get("text").?.string;
        const reason = vector.object.get("reason").?.string;
        const result = parse(gpa, text, &diagnostic);
        if (result) |value| {
            value.deinit(gpa);
            std.debug.print("fixture '{s}' ({s}) was accepted\n", .{ text, reason });
            return error.InvalidInputAccepted;
        } else |err| {
            try std.testing.expect(diagnostic.detail.len > 0);
            try std.testing.expect(err != error.OutOfMemory);
        }
    }
}

test "m02/CAN-004 reject duplicate keys" {
    std.debug.print("JCKG_EVIDENCE CAN-004\n", .{});
    const gpa = std.testing.allocator;
    var diagnostic: Diagnostic = .{};

    try std.testing.expectError(error.DuplicateKey, parse(gpa, "{\"a\":1,\"a\":2}", &diagnostic));
    try std.testing.expectEqualStrings("duplicate object key", diagnostic.detail);
    try std.testing.expectError(error.DuplicateKey, parse(gpa, "{\"a\":1,\"b\":2,\"a\":1}", &diagnostic));
    // Duplicates are rejected at any depth, and by decoded key value, so an
    // escaped spelling of the same key is still a duplicate.
    try std.testing.expectError(error.DuplicateKey, parse(gpa, "{\"outer\":{\"k\":1,\"k\":2}}", &diagnostic));
    try std.testing.expectError(error.DuplicateKey, parse(gpa, "{\"a\":1,\"\\u0061\":2}", &diagnostic));

    // Negative-or-recovery: distinct keys that merely look similar are kept,
    // and the parser never silently retains one value of a duplicate pair.
    const kept = try canonicalBytes(gpa, "{\"a\":1,\"A\":2,\"a \":3}", &diagnostic);
    defer gpa.free(kept);
    try std.testing.expectEqualStrings("{\"A\":2,\"a\":1,\"a \":3}", kept);
}

test "m02/CAN-005 preserve Unicode bytes" {
    std.debug.print("JCKG_EVIDENCE CAN-005\n", .{});
    const gpa = std.testing.allocator;
    var diagnostic: Diagnostic = .{};

    // Two spellings of the same visual character are different values: no
    // normalization is applied.
    const composed = try canonicalBytes(gpa, "{\"text\":\"é\"}", &diagnostic);
    defer gpa.free(composed);
    const decomposed = try canonicalBytes(gpa, "{\"text\":\"e\u{0301}\"}", &diagnostic);
    defer gpa.free(decomposed);
    try std.testing.expectEqualStrings("{\"text\":\"é\"}", composed);
    try std.testing.expect(!std.mem.eql(u8, composed, decomposed));
    // {"text":"e<U+0301>"} = 14 bytes: the combining mark is two UTF-8 bytes.
    try std.testing.expectEqual(@as(usize, 14), decomposed.len);

    // Non-ASCII keys and values keep their UTF-8 bytes, and astral characters
    // are encoded as four bytes, not as a surrogate pair.
    const emoji = try canonicalBytes(gpa, "{\"g\":\"😀\"}", &diagnostic);
    defer gpa.free(emoji);
    try std.testing.expectEqualStrings("{\"g\":\"😀\"}", emoji);
    // {"g":"<U+1F600>"} = 12 bytes: the astral character is four UTF-8 bytes.
    try std.testing.expectEqual(@as(usize, 12), emoji.len);

    // Escaped input decodes to the same bytes as literal input.
    const escaped = try canonicalBytes(gpa, "\"caf\\u00e9\"", &diagnostic);
    defer gpa.free(escaped);
    const literal = try canonicalBytes(gpa, "\"café\"", &diagnostic);
    defer gpa.free(literal);
    try std.testing.expectEqualStrings(literal, escaped);

    // Control characters use the documented short escapes and lowercase \u00xx.
    const controls = try canonicalBytes(gpa, "\"\\u0000\\b\\t\\n\\f\\r\"", &diagnostic);
    defer gpa.free(controls);
    try std.testing.expectEqualStrings("\"\\u0000\\b\\t\\n\\f\\r\"", controls);

    // Negative-or-recovery: the two accent vectors in the fixture differ only
    // by normalization and must stay different.
    var document = try fixtureVectors(gpa, fixture_path);
    defer document.deinit();
    var composed_hex: ?[]const u8 = null;
    var decomposed_hex: ?[]const u8 = null;
    for (document.value.object.get("vectors").?.array.items) |vector| {
        const id = vector.object.get("id").?.string;
        if (std.mem.eql(u8, id, "canonical-14")) decomposed_hex = vector.object.get("canonicalUtf8Hex").?.string;
        if (std.mem.eql(u8, id, "canonical-15")) composed_hex = vector.object.get("canonicalUtf8Hex").?.string;
    }
    try std.testing.expect(composed_hex != null and decomposed_hex != null);
    try std.testing.expect(!std.mem.eql(u8, composed_hex.?, decomposed_hex.?));
}

test "m02/CAN-006 reject invalid Unicode" {
    std.debug.print("JCKG_EVIDENCE CAN-006\n", .{});
    const gpa = std.testing.allocator;
    var diagnostic: Diagnostic = .{};

    // Unpaired surrogates, in both directions, and a surrogate pair that is
    // split by other content.
    try std.testing.expectError(error.UnpairedSurrogate, parse(gpa, "\"\\ud800\"", &diagnostic));
    try std.testing.expectError(error.UnpairedSurrogate, parse(gpa, "\"\\udc00\"", &diagnostic));
    try std.testing.expectError(error.UnpairedSurrogate, parse(gpa, "\"\\ud800x\"", &diagnostic));
    try std.testing.expectError(error.UnpairedSurrogate, parse(gpa, "\"\\ud800\\u0041\"", &diagnostic));
    try std.testing.expectError(error.UnpairedSurrogate, parse(gpa, "{\"k\":\"\\udfff\"}", &diagnostic));

    // A well-formed surrogate pair is accepted and becomes one scalar value.
    const pair = try canonicalBytes(gpa, "\"\\ud83d\\ude00\"", &diagnostic);
    defer gpa.free(pair);
    try std.testing.expectEqualStrings("\"😀\"", pair);

    // Raw bytes that are not valid UTF-8 are rejected rather than passed
    // through or replaced.
    try std.testing.expectError(error.InvalidUnicode, parse(gpa, "\"\xff\xfe\"", &diagnostic));
    try std.testing.expectError(error.InvalidUnicode, parse(gpa, "\"\xc3\"", &diagnostic));
    try std.testing.expectError(error.InvalidUnicode, parse(gpa, "\"\xed\xa0\x80\"", &diagnostic));

    // Negative-or-recovery: a boundary case is still well formed.
    const valid = try canonicalBytes(gpa, "\"\u{10FFFF}\"", &diagnostic);
    defer gpa.free(valid);
    try std.testing.expectEqual(@as(usize, 6), valid.len);

    // Rejection never leaves a partially decoded value behind: parse failures
    // are reported without returning a value.
    var leak_diagnostic: Diagnostic = .{};
    const outcome = parse(gpa, "[\"ok\",\"\\ud800\"]", &leak_diagnostic);
    try std.testing.expectError(error.UnpairedSurrogate, outcome);
    try std.testing.expectEqual(error.UnpairedSurrogate, leak_diagnostic.code);
}
