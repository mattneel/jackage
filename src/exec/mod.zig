//! Native action execution (EXE-001..EXE-010).
//!
//! `Executor.run(Request, *const core.cancel.Token)` returns an owned Result.
//! Requests carry an absolute program, exact argv excluding argv[0], declared
//! environment, workspace handle, output paths, optional monotonic deadline,
//! and total log budget. No environment minimum or host shell is implicit.
//!
//! Configure a core.Store and a Journal outside the action workspace. A new
//! controller calls Executor.reconcile before retry/collection; run also
//! reconciles its action ID and refuses live or uncertain prior ownership.
//! PID plus creation time guards against reuse. Started/running/completed
//! records are flushed and atomically replaced; user code starts only after
//! a suspended process identity is persisted.
//!
//! Native means same user, filesystem and network, not a sandbox.
//! `requireCapabilities` returns error.CapabilityUnavailable for every strict
//! capability that is not `enforced`, including filesystem/network isolation
//! and resource bounds. Supported output checks do not imply isolation.
//! This executor implements Windows ownership only. Other targets compile
//! cleanly, report execution unavailable with the same capability names, and
//! return error.NativePlatformUnavailable before launch or journal mutation.
//!
//! Windows descendant cleanup uses taskkill /T /F on owned identities, followed
//! by real process-state verification. No job object is installed: detached
//! descendants, same-user races and snapshot/spawn races are not prevented.
//! Never release a workspace/store lease while Result.cleanup_complete is
//! false; the journal then retains running ownership for reconciliation.
//! Only successful actions collect outputs. Declared directory roots include
//! their descendants, undeclared paths are reported, and links/reparses and
//! lexical escapes fail before any selected blob is published.
//!
//! Log memory is exactly the total capture budget plus two fixed 8 KiB drain
//! buffers and thread overhead. Stdout gets ceil(half), stderr floor(half);
//! excess bytes are drained/discarded, not accumulated.
pub const native = @import("native.zig");
pub const Request = native.Request;
pub const Environment = native.Environment;
pub const Result = native.Result;
pub const Status = native.Status;
pub const Executor = native.Executor;
pub const nativeBackend = native.nativeBackend;
pub const requireCapabilities = native.requireCapabilities;
pub const collector = @import("collector.zig");
pub const journal = @import("journal.zig");
pub const Journal = journal.Journal;
pub const ProcessIdentity = @import("windows.zig").Identity;

test {
    _ = @import("tests.zig");
}
