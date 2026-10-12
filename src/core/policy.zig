//! Authorization policy for effects that are not free (case CLI-006).
//!
//! Interactive prompts are refused when stdin is not a terminal, and `--yes`
//! only approves the narrow class of local, reversible profile actions. It
//! never enrolls trust roots, enables privilege, or authorizes publication,
//! and nothing here may bypass an explicit trust decision.
const std = @import("std");

pub const Kind = enum {
    /// Replacing files inside the project the user is working in.
    project_file_replacement,
    /// Committing a new installed profile generation.
    local_profile_transaction,
    /// Trusting a new repository identity.
    trust_enrollment,
    /// Making a release visible to other people.
    publication,
    /// Raising privilege for the client or an installer.
    privilege_change,

    pub fn text(self: Kind) []const u8 {
        return switch (self) {
            .project_file_replacement => "project file replacement",
            .local_profile_transaction => "local profile transaction",
            .trust_enrollment => "repository trust enrollment",
            .publication => "publication",
            .privilege_change => "privilege change",
        };
    }

    /// Whether `--yes` may approve this kind without a terminal.
    pub fn approvableByFlag(self: Kind) bool {
        return switch (self) {
            .project_file_replacement, .local_profile_transaction => true,
            .trust_enrollment, .publication, .privilege_change => false,
        };
    }
};

pub const Request = struct {
    kind: Kind,
    /// What the action would do, in the user's terms.
    description: []const u8,
};

pub const Interaction = struct {
    /// Whether stdin is an interactive terminal.
    interactive: bool,
    /// Whether `--yes` was given.
    assume_yes: bool,
};

pub const Decision = union(enum) {
    /// No prompt is needed; the action may proceed.
    approved,
    /// A terminal would be prompted; the caller shows the description.
    would_prompt,
    denied: DenialReason,

    pub fn isApproved(self: Decision) bool {
        return self == .approved;
    }
};

pub const DenialReason = enum {
    /// The decision needs a human and stdin is not a terminal.
    non_interactive,
    /// The decision needs explicit trust material, not a confirmation flag.
    requires_explicit_trust,
    /// The decision needs elevated authority.
    requires_privilege,
};

pub fn decide(interaction: Interaction, request: Request) Decision {
    switch (request.kind) {
        .project_file_replacement, .local_profile_transaction => {
            if (interaction.assume_yes) return .approved;
            if (interaction.interactive) return .would_prompt;
            return .{ .denied = .non_interactive };
        },
        .trust_enrollment, .publication => return .{ .denied = .requires_explicit_trust },
        .privilege_change => return .{ .denied = .requires_privilege },
    }
}

/// Explains a denial so the caller can act without guessing.
pub fn describeDenial(gpa: std.mem.Allocator, request: Request, reason: DenialReason) std.mem.Allocator.Error![]u8 {
    return switch (reason) {
        .non_interactive => gpa.print(
            "{s} requires confirmation, but stdin is not an interactive terminal; nothing was changed. Re-run with --yes to approve this local action, or run it from a terminal.",
            .{request.kind.text()},
        ),
        .requires_explicit_trust => gpa.print(
            "{s} cannot be approved by --yes; supply explicit trust material (a root file or an approved fingerprint) as documented for the operation, and nothing was changed.",
            .{request.kind.text()},
        ),
        .requires_privilege => gpa.print(
            "{s} requires explicit user authorization for elevated authority; --yes does not grant privilege and nothing was changed.",
            .{request.kind.text()},
        ),
    };
}

test "m01/CLI-006 avoid implicit prompts" {
    std.debug.print("JCKG_EVIDENCE CLI-006\n", .{});
    const gpa = std.testing.allocator;

    const request = Request{
        .kind = .project_file_replacement,
        .description = "replace jackage.ts",
    };

    // Non-interactive stdin without an explicit approval is denied, not
    // answered by waiting and not auto-approved.
    const denied = decide(.{ .interactive = false, .assume_yes = false }, request);
    try std.testing.expect(!denied.isApproved());
    try std.testing.expectEqual(DenialReason.non_interactive, denied.denied);
    const message = try describeDenial(gpa, request, denied.denied);
    defer gpa.free(message);
    try std.testing.expect(std.mem.indexOf(u8, message, "--yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "nothing was changed") != null);

    // A terminal would prompt; an explicit flag approves the local action.
    try std.testing.expectEqual(Decision.would_prompt, decide(.{ .interactive = true, .assume_yes = false }, request));
    try std.testing.expect(decide(.{ .interactive = false, .assume_yes = true }, request).isApproved());

    // --yes never enrolls trust, publishes, or grants privilege, even in a
    // terminal.
    const trust = Request{ .kind = .trust_enrollment, .description = "enroll example.invalid" };
    const trust_decision = decide(.{ .interactive = true, .assume_yes = true }, trust);
    try std.testing.expect(!trust_decision.isApproved());
    try std.testing.expectEqual(DenialReason.requires_explicit_trust, trust_decision.denied);
    try std.testing.expect(!Kind.trust_enrollment.approvableByFlag());

    const publish = Request{ .kind = .publication, .description = "publish channel" };
    try std.testing.expect(!decide(.{ .interactive = true, .assume_yes = true }, publish).isApproved());
    try std.testing.expect(!Kind.publication.approvableByFlag());

    const privilege = Request{ .kind = .privilege_change, .description = "elevate" };
    const privilege_decision = decide(.{ .interactive = true, .assume_yes = true }, privilege);
    try std.testing.expect(!privilege_decision.isApproved());
    try std.testing.expectEqual(DenialReason.requires_privilege, privilege_decision.denied);

    // A local profile transaction stays approvable, which is the documented
    // scope of --yes.
    const profile = Request{ .kind = .local_profile_transaction, .description = "install closure" };
    try std.testing.expect(decide(.{ .interactive = false, .assume_yes = true }, profile).isApproved());
    try std.testing.expect(Kind.local_profile_transaction.approvableByFlag());
}
