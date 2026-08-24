const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // A plain `zig build` produces a ReleaseSmall binary, because size and
    // memory footprint are what this project optimizes for. `-Doptimize=Debug`
    // and the `--release=fast|safe|small` shorthands still work.
    const optimize: std.builtin.OptimizeMode = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse switch (b.release_mode) {
        .off, .any, .small => .ReleaseSmall,
        .fast => .ReleaseFast,
        .safe => .ReleaseSafe,
    };

    // Everything below trades away debuggability for size and runtime memory.
    // The settings only apply to release builds: in Debug they would strip the
    // information that makes a panic readable, so leave them off there.
    const lean = optimize != .Debug;

    const mod = b.addModule("tug", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        // The remaining options are left null so this module inherits whatever
        // the root module of the compilation using it decided.
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tug", .module = mod },
        },

        // No symbol table and no debug info in the output file.
        .strip = lean,
        // Drops the thread-safety machinery in std, including the locks around
        // stdio and the general purpose allocator's thread bookkeeping.
        .single_threaded = lean,
        // Unwind tables only exist to walk the stack for tracebacks; without
        // them the .pdata/.xdata sections disappear.
        .unwind_tables = if (lean) .none else null,
        // Error return traces cost a slot per error site plus the code to fill
        // it in.
        .error_tracing = if (lean) false else null,
        // The frame pointer is only needed to walk the stack, which nothing
        // does once the traces above are gone.
        .omit_frame_pointer = lean,
        // Stack canaries and probes are runtime checks with a code-size cost.
        .stack_protector = if (lean) false else null,
        .stack_check = if (lean) false else null,
        .sanitize_c = if (lean) .off else null,
        .sanitize_thread = if (lean) false else null,
    });

    const exe = b.addExecutable(.{
        .name = "tug",
        .root_module = exe_mod,
    });

    // Zig reserves 16 MiB of address space for the main thread's stack. 1 MiB
    // matches what a C program on Windows gets and is plenty for code that does
    // not recurse deeply. Raise it if a stack overflow ever shows up.
    exe.stack_size = 1 * 1024 * 1024;

    // Link-time optimization, so the linker can drop code that survived
    // per-module dead code elimination. Worth very little on a program this
    // small; it earns its keep as one grows.
    if (lean) exe.lto = .full;

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // The test modules deliberately do not inherit the size options above: a
    // stripped, traceback-free build makes a failing test much harder to read.
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .imports = &.{
                .{ .name = "tug", .module = mod },
            },
        }),
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
