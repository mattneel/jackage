# TypeScript and QuickJS-NG evaluator

## Model

The frontend transforms TypeScript into JavaScript with a pinned tool.
QuickJS-NG evaluates that JavaScript through an embedded C interface [S02].
The Zig host receives a declarative value and validates it against the plan contract.
The runtime does not become a Node.js or Bun compatibility layer.

The configuration SDK exposes pure constructors and explicit declarations.
The SDK does not expose arbitrary host filesystem, process, or network APIs.
QuickJS-NG memory and interruption controls bound normal evaluation work [S02].
A malicious native-engine exploit remains outside the protection of JavaScript API restrictions alone.
Untrusted evaluation therefore needs a restricted worker process as defense in depth.

## TypeScript pipeline

The initial TypeScript subset includes types, interfaces, modules, and ordinary executable JavaScript expressions.
The transformation tool, options, and imported module contents enter the lockfile.
A full type-check stage is distinct from syntax transformation.
An erase-only transform cannot imply semantic type checking.

The existing repository can already contain a transformer or QuickJS-NG dependency.
M00 must inspect that state before dependency selection.
A maintained pinned transformer is preferred over a custom TypeScript parser.
The decision must address its license, distribution size, bootstrap path, and target platforms.

## Module loading

The host supplies a module loader for declared local files and locked package modules.
Imports resolve inside an explicit configuration root or a verified dependency artifact.
Network imports, absolute host imports, and undeclared dynamic imports are denied.
Module resolution must reject traversal through symlinks and Windows reparse points.
Resolution does not consult ambient `NODE_PATH`, user configuration, or global installations.

The proposed builtin module name is `jackage`.
It is not an instruction to install an unrelated npm package with that name.
The supplied `.d.ts` and `.ts` files describe a candidate authoring interface only.

## Deterministic evaluation

Ambient date and time are unavailable to recipe code.
Random values are unavailable unless an explicit deterministic input supplies them.
Locale-sensitive behavior uses a declared locale or is rejected.
Evaluation cannot read the host environment implicitly.
A declared variable has a supplied value that enters the plan identity.

The host rejects unsupported values after evaluation.
Functions, symbols, cyclic objects, promises, non-finite numbers, and unsafe integers cannot enter the plan.
Property access during validation must not trigger uncontrolled user callbacks.
The host must extract and validate inert data rather than trust arbitrary object prototypes.

## Limits and failure

Every evaluation has memory, stack, module-count, source-size, and execution limits.
The worker terminates on a hard deadline if cooperative interruption fails.
A timeout leaves no published plan and no partially committed lockfile.
The error distinguishes syntax, type, module, policy, resource, and internal failures.
The host releases QuickJS values and runtime resources on all failure paths.

## Bytecode

Downloaded configuration arrives as source, not trusted engine bytecode.
QuickJS bytecode depends on the engine version and lacks a general untrusted-bytecode safety guarantee [S02].
An optional local bytecode cache is keyed by engine, transformer, options, and source digests.
The cache remains a disposable implementation detail.
It cannot replace signature or digest verification of source inputs.

## Acceptance emphasis

- Deterministic declarations must produce the same canonical plan across repeated evaluations.
- Missing imports must fail without network fallback.
- Infinite loops and allocation attacks must fail within enforced budgets.
- Prototype tricks and accessors must not escape data validation.
- Configuration evaluation must not spawn a process or open arbitrary host files.
- Errors must contain safe source locations without credentials.
