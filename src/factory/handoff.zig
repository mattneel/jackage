//! Picking up where the last session stopped (M16, FACTORY-008).
//!
//! An agent stops after a partial milestone and a new session reads the handoff. What
//! that session must *not* do is start over: re-running a destructive setup - wiping a
//! store, recreating a workspace, fetching a toolchain - is how a session destroys the
//! work it was meant to continue. So the handoff is not prose. It names the milestone,
//! the cases already complete with their evidence, the one case to do next, and the
//! setups that are already done.
//!
//! `resume` answers two questions without guessing: which case comes next, and which
//! setups still have to run. A setup the handoff records as done is skipped, and one it
//! does not record is required - so "do not repeat the destructive setup" is a decision
//! the document makes rather than a habit the next session is trusted to have.
//!
//! A handoff that points at a case already marked complete is refused: resuming onto
//! work that is finished is how a session talks itself into redoing it.
const std = @import("std");

pub const Error = error{
    InvalidHandoff,
    AlreadyComplete,
    UnknownMilestone,
    OutOfMemory,
};

pub const Case = struct {
    id: []const u8,
    /// Where the evidence for this case lives, so a resume can check rather than trust.
    evidence: []const u8,
};

pub const Setup = struct {
    name: []const u8,
    done: bool,
};

pub const Handoff = struct {
    milestone: []const u8,
    completed: []const Case,
    /// The exact next case, named rather than implied by position.
    next_case: []const u8,
    setups: []const Setup,

    pub fn deinit(self: Handoff, gpa: std.mem.Allocator) void {
        gpa.free(self.milestone);
        for (self.completed) |case| {
            gpa.free(case.id);
            gpa.free(case.evidence);
        }
        gpa.free(self.completed);
        gpa.free(self.next_case);
        for (self.setups) |setup| gpa.free(setup.name);
        gpa.free(self.setups);
    }
};

/// Parses the handoff document.
pub fn read(gpa: std.mem.Allocator, document: []const u8) Error!Handoff {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, document, .{}) catch return error.InvalidHandoff;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidHandoff;
    const object = parsed.value.object;

    const milestone = object.get("milestone") orelse return error.InvalidHandoff;
    const next_case = object.get("next_case") orelse return error.InvalidHandoff;
    if (milestone != .string or next_case != .string) return error.InvalidHandoff;
    if (milestone.string.len == 0 or next_case.string.len == 0) return error.InvalidHandoff;

    var completed: std.ArrayList(Case) = .empty;
    errdefer {
        for (completed.items) |case| {
            gpa.free(case.id);
            gpa.free(case.evidence);
        }
        completed.deinit(gpa);
    }
    if (object.get("completed")) |list| {
        if (list != .array) return error.InvalidHandoff;
        for (list.array.items) |item| {
            if (item != .object) return error.InvalidHandoff;
            const id = item.object.get("id") orelse return error.InvalidHandoff;
            const evidence = item.object.get("evidence") orelse return error.InvalidHandoff;
            if (id != .string or evidence != .string or id.string.len == 0) return error.InvalidHandoff;
            try completed.append(gpa, .{
                .id = try gpa.dupe(u8, id.string),
                .evidence = try gpa.dupe(u8, evidence.string),
            });
        }
    }

    var setups: std.ArrayList(Setup) = .empty;
    errdefer {
        for (setups.items) |setup| gpa.free(setup.name);
        setups.deinit(gpa);
    }
    if (object.get("setups")) |list| {
        if (list != .array) return error.InvalidHandoff;
        for (list.array.items) |item| {
            if (item != .object) return error.InvalidHandoff;
            const name = item.object.get("name") orelse return error.InvalidHandoff;
            const done = item.object.get("done") orelse return error.InvalidHandoff;
            if (name != .string or done != .bool or name.string.len == 0) return error.InvalidHandoff;
            try setups.append(gpa, .{
                .name = try gpa.dupe(u8, name.string),
                .done = done.bool,
            });
        }
    }

    // Resuming onto work that is already finished is refused here, where the document
    // can say so, rather than by redoing it later.
    for (completed.items) |case| {
        if (std.mem.eql(u8, case.id, next_case.string)) return error.AlreadyComplete;
    }

    return .{
        .milestone = try gpa.dupe(u8, milestone.string),
        .completed = try completed.toOwnedSlice(gpa),
        .next_case = try gpa.dupe(u8, next_case.string),
        .setups = try setups.toOwnedSlice(gpa),
    };
}

pub const Resume = struct {
    /// The case to run, named by the handoff rather than derived from a position.
    next_case: []const u8,
    /// The setups that still have to run. A setup the handoff records as done is not
    /// here, which is the whole point: the next session does not repeat it.
    required_setups: []const []const u8,
    /// The setups the handoff says are already done, kept so a session can log what it
    /// skipped instead of silently assuming.
    skipped_setups: []const []const u8,

    pub fn deinit(self: Resume, gpa: std.mem.Allocator) void {
        // The case name is a copy, so it is freed here rather than borrowed from the
        // handoff: a caller that keeps the resume after dropping the handoff still has
        // a valid name.
        gpa.free(self.next_case);
        for (self.required_setups) |name| gpa.free(name);
        gpa.free(self.required_setups);
        for (self.skipped_setups) |name| gpa.free(name);
        gpa.free(self.skipped_setups);
    }
};

/// Decides what a new session runs first.
pub fn resumeFrom(gpa: std.mem.Allocator, handoff: Handoff, milestone: []const u8) Error!Resume {
    if (!std.mem.eql(u8, handoff.milestone, milestone)) return error.UnknownMilestone;

    var required: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (required.items) |name| gpa.free(name);
        required.deinit(gpa);
    }
    var skipped: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (skipped.items) |name| gpa.free(name);
        skipped.deinit(gpa);
    }
    for (handoff.setups) |setup| {
        if (setup.done) {
            try skipped.append(gpa, try gpa.dupe(u8, setup.name));
        } else {
            try required.append(gpa, try gpa.dupe(u8, setup.name));
        }
    }
    return .{
        .next_case = try gpa.dupe(u8, handoff.next_case),
        .required_setups = try required.toOwnedSlice(gpa),
        .skipped_setups = try skipped.toOwnedSlice(gpa),
    };
}

test "m16/FACTORY-008 resume agent work: the exact next case, without repeating destructive setup" {
    std.debug.print("JCKG_EVIDENCE FACTORY-008\n", .{});
    const gpa = std.testing.allocator;

    // A handoff of exactly the shape this delivery maintains: what is done, what comes
    // next, and which setups have already run.
    const document = 
    \\{"milestone":"M16",
    \\ "completed":[{"id":"FACTORY-001","evidence":"state/evidence/1.json"},
    \\              {"id":"FACTORY-002","evidence":"state/evidence/2.json"},
    \\              {"id":"FACTORY-003","evidence":"state/evidence/3.json"},
    \\              {"id":"FACTORY-004","evidence":"state/evidence/4.json"},
    \\              {"id":"FACTORY-005","evidence":"state/evidence/5.json"},
    \\              {"id":"FACTORY-006","evidence":"state/evidence/6.json"}],
    \\ "next_case":"FACTORY-007",
    \\ "setups":[{"name":"guest toolchain installed","done":true},
    \\           {"name":"store initialized","done":true},
    \\           {"name":"publication grant requested","done":false}]}
    ;

    const handoff = try read(gpa, document);
    defer handoff.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 6), handoff.completed.len);
    try std.testing.expectEqualStrings("FACTORY-007", handoff.next_case);

    const resumed = try resumeFrom(gpa, handoff, "M16");
    defer resumed.deinit(gpa);

    // The exact next case, named by the document.
    try std.testing.expectEqualStrings("FACTORY-007", resumed.next_case);
    // The destructive setups are not repeated: the toolchain is not fetched again and
    // the store is not wiped, because the handoff records both as done.
    try std.testing.expectEqual(@as(usize, 2), resumed.skipped_setups.len);
    try std.testing.expectEqualStrings("guest toolchain installed", resumed.skipped_setups[0]);
    try std.testing.expectEqualStrings("store initialized", resumed.skipped_setups[1]);
    // And the one that genuinely remains is required, so "skip what is done" does not
    // become "skip everything".
    try std.testing.expectEqual(@as(usize, 1), resumed.required_setups.len);
    try std.testing.expectEqualStrings("publication grant requested", resumed.required_setups[0]);

    // The setups list agrees with the document rather than with a queue somebody
    // happens to be holding.
    for (handoff.setups) |setup| {
        var in_skipped = false;
        for (resumed.skipped_setups) |name| {
            if (std.mem.eql(u8, name, setup.name)) in_skipped = true;
        }
        try std.testing.expectEqual(setup.done, in_skipped);
    }

    // Resuming a milestone the handoff is not about is refused.
    try std.testing.expectError(error.UnknownMilestone, resumeFrom(gpa, handoff, "M17"));

    // A handoff that points at a case it also lists as complete is refused: resuming
    // onto finished work is how a session talks itself into redoing it.
    const confused = 
    \\{"milestone":"M16","completed":[{"id":"FACTORY-007","evidence":"state/evidence/7.json"}],
    \\ "next_case":"FACTORY-007","setups":[]}
    ;
    try std.testing.expectError(error.AlreadyComplete, read(gpa, confused));

    // A handoff with no setups at all is valid: a fresh session has nothing to skip and
    // nothing to require, which is different from a malformed document.
    const bare = 
    \\{"milestone":"M17","completed":[],"next_case":"HARDEN-001","setups":[]}
    ;
    const fresh = try read(gpa, bare);
    defer fresh.deinit(gpa);
    const fresh_resume = try resumeFrom(gpa, fresh, "M17");
    defer fresh_resume.deinit(gpa);
    try std.testing.expectEqualStrings("HARDEN-001", fresh_resume.next_case);
    try std.testing.expectEqual(@as(usize, 0), fresh_resume.required_setups.len);
    try std.testing.expectEqual(@as(usize, 0), fresh_resume.skipped_setups.len);

    // Malformed documents are refused rather than half-read.
    try std.testing.expectError(error.InvalidHandoff, read(gpa, "{}"));
    try std.testing.expectError(error.InvalidHandoff, read(gpa, "not a document"));
    try std.testing.expectError(error.InvalidHandoff, read(gpa, "{\"milestone\":\"M16\"}"));
    try std.testing.expectError(error.InvalidHandoff, read(gpa, "{\"milestone\":\"M16\",\"next_case\":\"\",\"completed\":[],\"setups\":[]}"));
    try std.testing.expectError(error.InvalidHandoff, read(gpa, "{\"milestone\":\"M16\",\"next_case\":\"X\",\"completed\":\"nope\",\"setups\":[]}"));
    try std.testing.expectError(error.InvalidHandoff, read(gpa, "{\"milestone\":\"M16\",\"next_case\":\"X\",\"completed\":[],\"setups\":[{\"name\":\"x\"}]}"));
}
