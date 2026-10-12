//! Locked TypeScript configuration frontend (M04).
//!
//! `evaluate` consumes an explicit digest-locked module map and declared inert
//! inputs. esbuild transforms each module without resolution; TypeScript's
//! semantic stage is separate and optional unless required. Source-only
//! QuickJS-NG then executes with allocator, stack and interruption limits.
//! Only the SDK Project schema survives descriptor-only extraction. The result
//! is a canonical `{declaration, inputs}` plan envelope and its domain digest.
//!
//! Callers supply a disposable `Options.work_dir` and own `Result.deinit`.
//! Default native tools/provenance are in vendor/manifest.json. No PATH lookup,
//! engine bytecode deserialization, Node compatibility layer, or host bridge is
//! provided. `Cache` stores only validated inert plans and is disposable.
const frontend = @import("frontend.zig");
pub const evaluate = frontend.evaluate;
pub const typeCheck = frontend.typeCheck;
pub const cacheKey = frontend.cacheKey;
pub const Options = frontend.Options;
pub const Result = frontend.Result;
pub const Cache = frontend.Cache;
pub const Tool = frontend.Tool;
pub const Toolchain = frontend.Toolchain;
pub const LockedModule = frontend.LockedModule;
pub const Source = frontend.Source;
pub const Snapshot = frontend.Snapshot;
pub const TypeCheck = frontend.TypeCheck;
pub const Limits = frontend.Limits;
pub const engine = @import("engine.zig");
pub const schema = @import("schema.zig");
test { _ = @import("tests.zig"); }
