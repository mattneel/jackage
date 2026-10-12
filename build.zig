const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between debug, safe, fast, and small. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.
    //
    // `-Dfilter=<text>` restricts test executables to tests whose name contains
    // the text. Per-case acceptance evidence uses it so one test can be run in
    // isolation; the default runs everything.
    const filter = b.option([]const u8, "filter", "Only run tests whose name contains this text");
    var filter_storage: [1][]const u8 = undefined;
    const test_filters: []const []const u8 = if (filter) |value| blk: {
        filter_storage[0] = value;
        break :blk &filter_storage;
    } else &.{};

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("jackage", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
    });

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "jackage",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "jackage" is the name you will use in your source code to
                // import this module (e.g. `@import("jackage")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "jackage", .module = mod },
            },
        }),
    });

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    run_cmd.addPassthruArgs();

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
        .filters = test_filters,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
        .filters = test_filters,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // Jackage product library. `src/jckg.zig` is the root of the packages,
    // store, executor, evaluator, resolver, and profile code that the `jckg`
    // and `jckgx` clients link against. The scaffold's own `jackage` module
    // above stays untouched.
    const jckg_mod = b.addModule("jckg", .{
        .root_source_file = b.path("src/jckg.zig"),
        .target = target,
    });
    // The engine has no libc host modules: only the source parser and VM are
    // linked. Every product consumer uses these same vendored C sources.
    jckg_mod.link_libc = true;
    jckg_mod.addIncludePath(b.path("vendor/quickjs-ng"));
    const quickjs_bindings = b.addModule("quickjs", .{
        .root_source_file = b.path("vendor/quickjs-ng/quickjs.zig"),
        .target = target,
        .link_libc = true,
    });
    jckg_mod.addImport("quickjs", quickjs_bindings);
    jckg_mod.addCSourceFiles(.{
        .root = b.path("vendor/quickjs-ng"),
        .files = &.{ "quickjs.c", "dtoa.c", "libregexp.c", "libunicode.c" },
        .flags = &.{ "-std=c11", "-D_GNU_SOURCE", "-fno-sanitize=undefined" },
    });
    const eval_mod = b.createModule(.{
        .root_source_file = b.path("src/eval_tests.zig"),
        .target = target,
        .link_libc = true,
    });
    eval_mod.addImport("quickjs", quickjs_bindings);
    eval_mod.addIncludePath(b.path("vendor/quickjs-ng"));
    eval_mod.addCSourceFiles(.{
        .root = b.path("vendor/quickjs-ng"),
        .files = &.{ "quickjs.c", "dtoa.c", "libregexp.c", "libunicode.c" },
        .flags = &.{ "-std=c11", "-D_GNU_SOURCE", "-fno-sanitize=undefined" },
    });
    const eval_tests = b.addTest(.{
        .name = "eval-tests",
        .root_module = eval_mod,
        .filters = test_filters,
    });
    const install_eval_tests = b.addInstallArtifact(eval_tests, .{
        .dest_dir = .{ .override = .{ .custom = "bin" } },
    });
    const run_eval_tests = b.addRunArtifact(eval_tests);
    const eval_test_step = b.step("eval-test", "Run source evaluator tests");
    eval_test_step.dependOn(&run_eval_tests.step);
    eval_test_step.dependOn(&install_eval_tests.step);

    const jckg_tests = b.addTest(.{
        .name = "jckg-tests",
        .root_module = jckg_mod,
        .filters = test_filters,
    });
    const install_jckg_tests = b.addInstallArtifact(jckg_tests, .{
        .dest_dir = .{ .override = .{ .custom = "bin" } },
    });
    const run_jckg_tests = b.addRunArtifact(jckg_tests);
    // The client's integration tests run the installed executable, so the
    // install step must complete first.
    run_jckg_tests.step.dependOn(b.getInstallStep());

    // `jckg`: the client executable. Its entry file only imports the product
    // library, so no source file escapes its module root.
    const cli_entry = b.createModule(.{
        .root_source_file = b.path("src/cli/entry.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "jckg", .module = jckg_mod },
        },
    });
    const jckg_exe = b.addExecutable(.{
        .name = "jckg",
        .root_module = cli_entry,
    });
    b.installArtifact(jckg_exe);

    // `jckg-worker` and `jckg-probe`: the guest side of the strict execution
    // backend (M08). Both are built for the declared Linux execution environment
    // whatever the host is, because the sandbox needs Linux namespaces; a host
    // build of either program refuses to run rather than pretending.
    //
    // They live on their own steps (`worker`, `probe`) and are deliberately not
    // part of the default install or the `test` step, so an in-flight change to
    // the sandbox cannot invalidate someone else's acceptance run.
    const worker_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .musl,
    });
    const worker_mod = b.createModule(.{
        .root_source_file = b.path("src/worker_entry.zig"),
        .target = worker_target,
        .optimize = optimize,
    });
    const probe_mod = b.createModule(.{
        .root_source_file = b.path("src/worker_probe_entry.zig"),
        .target = worker_target,
        .optimize = optimize,
    });
    const jckg_worker = b.addExecutable(.{ .name = "jckg-worker", .root_module = worker_mod });
    const jckg_probe = b.addExecutable(.{ .name = "jckg-probe", .root_module = probe_mod });
    const install_worker = b.addInstallArtifact(jckg_worker, .{
        .dest_dir = .{ .override = .{ .custom = "bin" } },
    });
    const install_probe = b.addInstallArtifact(jckg_probe, .{
        .dest_dir = .{ .override = .{ .custom = "bin" } },
    });
    const worker_step = b.step("worker", "Build the guest worker for the Linux execution environment");
    worker_step.dependOn(&install_worker.step);
    const probe_step = b.step("probe", "Build the guest probe used by the sandbox acceptance tests");
    probe_step.dependOn(&install_probe.step);

    // Only the guest suite exercises the sandbox; it is a separate step so host
    // runs stay unaffected by worker changes.
    const strict_mod = b.createModule(.{
        .root_source_file = b.path("src/strict_tests_entry.zig"),
        .target = target,
        .optimize = optimize,
    });
    const strict_tests = b.addTest(.{
        .name = "strict-tests",
        .root_module = strict_mod,
        .filters = test_filters,
    });
    const run_strict_tests = b.addRunArtifact(strict_tests);
    // `strict-build` installs the suite without running it, so a hang can be
    // observed from outside instead of being buried in the build runner.
    const install_strict_tests = b.addInstallArtifact(strict_tests, .{
        .dest_dir = .{ .override = .{ .custom = "bin" } },
    });
    const strict_build_step = b.step("strict-build", "Build the sandbox acceptance test binary without running it");
    strict_build_step.dependOn(&install_strict_tests.step);

    const strict_step = b.step("strict-test", "Run the sandbox acceptance tests (guest-only evidence)");
    strict_step.dependOn(&run_strict_tests.step);
    strict_step.dependOn(&install_worker.step);
    strict_step.dependOn(&install_probe.step);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_jckg_tests.step);
    test_step.dependOn(&install_jckg_tests.step);
    test_step.dependOn(&run_eval_tests.step);
    test_step.dependOn(&install_eval_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
