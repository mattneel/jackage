//! Declaring the SDK perimeter for a release (M11, PLAT-012).
//!
//! Some builds need a proprietary SDK. That is allowed; what is not allowed is for
//! the boundary to be implicit. This module makes three things explicit and refuses
//! a release plan that leaves any of them unstated:
//!
//! 1. **Which component is the SDK**, by name, so "we need a proprietary thing" is
//!    never an unnamed worry.
//! 2. **Its redistribution policy**, stated per component: redistributable,
//!    proprietary, or restricted. A licence nobody has classified is refused,
//!    because publishing what you cannot license is not a decision to make by
//!    omission.
//! 3. **Which side of the boundary it lands on**: an SDK may appear in the build
//!    closure and must not appear in the release payload. A proprietary or
//!    restricted component in the payload is a refusal, not a warning.
//!
//! The two failure shapes are distinguished on purpose: a missing policy is a
//! paperwork problem, while a restricted component in the payload is a legal one.
const std = @import("std");

pub const Error = error{
    UnclassifiedLicense,
    RestrictedComponentInPayload,
    SdkNotDeclared,
    DuplicateComponent,
    OutOfMemory,
};

pub const License = enum {
    /// May be redistributed with the product.
    redistributable,
    /// Proprietary: usable to build, not to ship.
    proprietary,
    /// Restricted: neither shipping nor unqualified use.
    restricted,
    /// Nobody has classified it. Refused rather than assumed.
    unclassified,
};

pub const Side = enum { build, runtime };

pub const Component = struct {
    name: []const u8,
    license: License,
    /// Which side of the boundary the component lands on in this plan.
    side: Side,
    /// True when this component is the SDK the plan requires.
    sdk: bool = false,
};

pub const Report = struct {
    /// Components that remain in the shipped payload.
    shipped: []const []const u8,
    /// Components used only to build.
    build_only: []const []const u8,
    /// The SDK the plan declared, when it declared one.
    sdk: ?[]const u8,

    pub fn deinit(self: Report, gpa: std.mem.Allocator) void {
        for (self.shipped) |name| gpa.free(name);
        gpa.free(self.shipped);
        for (self.build_only) |name| gpa.free(name);
        gpa.free(self.build_only);
        if (self.sdk) |name| gpa.free(name);
    }
};

/// Validates a closure against the perimeter rules and reports where the boundary
/// fell.
pub fn validate(gpa: std.mem.Allocator, components: []const Component, requires_sdk: bool) Error!Report {
    for (components, 0..) |component, index| {
        for (components[index + 1 ..]) |other| {
            if (std.mem.eql(u8, component.name, other.name)) return error.DuplicateComponent;
        }
    }

    var sdk_name: ?[]const u8 = null;
    for (components) |component| {
        if (!component.sdk) continue;
        if (sdk_name != null) return error.SdkNotDeclared;
        sdk_name = component.name;
    }
    if (requires_sdk and sdk_name == null) return error.SdkNotDeclared;

    var shipped: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (shipped.items) |name| gpa.free(name);
        shipped.deinit(gpa);
    }
    var build_only: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (build_only.items) |name| gpa.free(name);
        build_only.deinit(gpa);
    }

    for (components) |component| {
        // An unclassified licence stops the plan wherever the component sits: a
        // build that ships an unknown licence is a build nobody can publish.
        if (component.license == .unclassified) return error.UnclassifiedLicense;

        switch (component.side) {
            .runtime => {
                // The boundary: a proprietary or restricted component in the payload
                // is a refusal. Shipping an SDK is the specific mistake this case is
                // about, and shipping a restricted component is worse.
                if (component.license != .redistributable) return error.RestrictedComponentInPayload;
                try shipped.append(gpa, try gpa.dupe(u8, component.name));
            },
            .build => try build_only.append(gpa, try gpa.dupe(u8, component.name)),
        }
    }

    return .{
        .shipped = try shipped.toOwnedSlice(gpa),
        .build_only = try build_only.toOwnedSlice(gpa),
        .sdk = if (sdk_name) |name| try gpa.dupe(u8, name) else null,
    };
}

test "m11/PLAT-012 declare SDK perimeter: boundary and redistribution policy are explicit" {
    std.debug.print("JCKG_EVIDENCE PLAT-012\n", .{});
    const gpa = std.testing.allocator;

    // A release action that needs a proprietary SDK: the SDK and its runtime
    // libraries stay on the build side, and the product ships alone.
    const components = [_]Component{
        .{ .name = "jackage", .license = .redistributable, .side = .runtime },
        .{ .name = "vendor-sdk", .license = .proprietary, .side = .build, .sdk = true },
        .{ .name = "sdk-runtime", .license = .proprietary, .side = .build },
        .{ .name = "libz", .license = .redistributable, .side = .runtime },
    };
    const report = try validate(gpa, &components, true);
    defer report.deinit(gpa);

    // The boundary is explicit: exactly what ships, exactly what does not, and
    // exactly which component is the SDK.
    try std.testing.expectEqual(@as(usize, 2), report.shipped.len);
    try std.testing.expectEqualStrings("jackage", report.shipped[0]);
    try std.testing.expectEqualStrings("libz", report.shipped[1]);
    try std.testing.expectEqual(@as(usize, 2), report.build_only.len);
    try std.testing.expectEqualStrings("vendor-sdk", report.sdk.?);
    for (report.shipped) |name| {
        try std.testing.expect(!std.mem.eql(u8, name, "vendor-sdk"));
        try std.testing.expect(!std.mem.eql(u8, name, "sdk-runtime"));
    }

    // A proprietary component in the payload is a refusal, not a warning: this is
    // the mistake the case exists to prevent.
    const leaked = [_]Component{
        .{ .name = "jackage", .license = .redistributable, .side = .runtime },
        .{ .name = "vendor-sdk", .license = .proprietary, .side = .runtime, .sdk = true },
    };
    try std.testing.expectError(error.RestrictedComponentInPayload, validate(gpa, &leaked, true));

    // A restricted component in the payload is refused as well.
    const restricted = [_]Component{
        .{ .name = "vendor-sdk", .license = .restricted, .side = .runtime, .sdk = true },
    };
    try std.testing.expectError(error.RestrictedComponentInPayload, validate(gpa, &restricted, true));

    // An unclassified licence is refused wherever it sits: publishing what nobody
    // has classified is not a decision to make by omission.
    const unknown = [_]Component{
        .{ .name = "mystery", .license = .unclassified, .side = .build },
    };
    try std.testing.expectError(error.UnclassifiedLicense, validate(gpa, &unknown, false));

    // A plan that requires an SDK and does not name it is refused: an unnamed
    // boundary is not a boundary.
    const no_sdk = [_]Component{
        .{ .name = "jackage", .license = .redistributable, .side = .runtime },
    };
    try std.testing.expectError(error.SdkNotDeclared, validate(gpa, &no_sdk, true));
    const without_requirement = try validate(gpa, &no_sdk, false);
    defer without_requirement.deinit(gpa);
    try std.testing.expect(without_requirement.sdk == null);

    // Duplicate components are refused: two entries with one name is a plan that
    // cannot say which policy applies.
    const duplicated = [_]Component{
        .{ .name = "libz", .license = .redistributable, .side = .runtime },
        .{ .name = "libz", .license = .restricted, .side = .build },
    };
    try std.testing.expectError(error.DuplicateComponent, validate(gpa, &duplicated, false));
}
