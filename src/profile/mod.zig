//! Durable profiles and transient execution (PROFILE-001..PROFILE-010).
//!
//! Manager.init(io, allocator, profile_root, store), then ensureLayout.
//! publish accepts a trusted local Artifact with portable tree entries, command
//! declarations, a default command, and runtime artifact dependencies. It
//! verifies bytes and records core.Store references; trust is the caller's
//! responsibility. install accepts resolver.Selection slices (a Resolution's
//! selections directly). active/readGeneration return owned Generation handles;
//! rollback selects a prior generation and remove creates a new selection.
//!
//! Layout: profiles/<name>/generations/<id>.json, active, leases/<id>.json;
//! profile-workspaces/<lease-id> and profile-journal/<lease-id>.json. Canonical
//! manifests declare package selections, complete closure, command ownership,
//! and parent. File sync precedes atomic generation/pointer rename. Stale temp
//! files are never selected. All publication/collection/leases share one OS
//! file lock; callers sharing a store must use the same profile root.
//!
//! Conflict policy: same command name (case-insensitive on Windows/macOS) is an
//! error naming both packages unless InstallOptions.owners explicitly declares
//! its owner. Manifest ownership never depends on selection order.
//!
//! collect keeps active plus one parent by default; keep_generations=1 retires
//! old history immediately. Every durable lease pins its generation and full
//! closure. Protected/in-use files are retained and reported. No age-based
//! lease expiration is safe. readLease reloads durable ownership after restart;
//! release reconciles actual processes/groups before removing the record.
//!
//! runner.parse implements [--repo <url>] <package> [--] <args...>. Only the
//! first separator immediately after the package is consumed. Quotes are argv
//! data; no shell is involved. prepareTransient uses the verified descriptor's
//! default command; prepareCommand atomically leases an installed selection.
//! Execution.run(options, cancellation_token) uses M03 Executor on Windows
//! and a real std.process.spawn/wait process-group backend on Linux, with the
//! same durable ownership journal, from a private copied workspace. Result
//! distinguishes program status from launch/infrastructure failure.
//! callerStatus preserves native program status (Windows DWORD, POSIX exit
//! byte or 128+signal), or launch=127, infrastructure=7, canceled=130, timeout=124.
//! Neither installed profiles nor global PATH are changed. Declare child
//! environment explicitly; native execution is not a sandbox.
pub const artifact = @import("artifact.zig");
pub const Artifact = artifact.Artifact;
pub const ArtifactCommand = artifact.Command;
pub const manager = @import("manager.zig");
pub const Manager = manager.Manager;
pub const Manifest = manager.Manifest;
pub const Generation = manager.Generation;
pub const Package = manager.Package;
pub const Command = manager.Command;
pub const CommandOwner = manager.CommandOwner;
pub const Collision = manager.Collision;
pub const ActivationPoint = manager.ActivationPoint;
pub const InstallOptions = manager.InstallOptions;
pub const Lease = manager.Lease;
pub const LeaseRecord = manager.LeaseRecord;
pub const Owner = manager.Owner;
pub const process = @import("process.zig");
pub const ProcessIdentity = process.Identity;
pub const CollectionOptions = manager.CollectionOptions;
pub const CollectionReport = manager.CollectionReport;
pub const runner = @import("runner.zig");
pub const Execution = runner.Execution;
pub const RunOptions = runner.RunOptions;
pub const RunResult = runner.Result;
pub const RunStatus = runner.Status;

test {
    _ = @import("tests.zig");
}
