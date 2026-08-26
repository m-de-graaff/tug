const std = @import("std");

/// Bumped by hand. `--version` reads it through the `build_options` module, so
/// there is exactly one place it is written down.
const version = "0.1.0";

/// The v0.2 binary-size budget from the roadmap: 2 MiB, ReleaseSmall, stripped,
/// static Linux x86_64. `zig build size` prints the number, and the CI gate
/// fails the build when it is exceeded.
///
/// The number moved from v0.1's 500 KiB because TLS, an HTTP client and two
/// providers land inside this version. It moves once, here, with the changelog
/// line the "budgets never silently loosen" rule requires.
const size_budget_bytes = 2 * 1024 * 1024;

/// The ratchet, tightened at the v0.1 freeze per Phase 11 to the measured size
/// plus ten per cent — 211 KiB — and suspended for the duration of v0.2, whose
/// provider stack would breach it on the first commit that links TLS.
///
/// A ratchet that fails on planned work is a ratchet nobody reads, so rather
/// than being nudged upward all version long it is parked at the ceiling and
/// re-derived from the measured size at the v0.2 tag (Phase 10). Until then the
/// 2 MiB ceiling above is the only live gate, and `zig build size` keeps running
/// both checks so restoring the real ratchet is one constant.
const size_ratchet_bytes = size_budget_bytes;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // A plain `zig build` produces ReleaseSmall: the size budget is a shipping
    // constraint, so the default build is the one that has to satisfy it.
    // `-Doptimize=Debug` and the `--release=fast|safe|small` shorthands work as
    // usual.
    const optimize: std.builtin.OptimizeMode = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse switch (b.release_mode) {
        .off, .any, .small => .ReleaseSmall,
        .fast => .ReleaseFast,
        .safe => .ReleaseSafe,
    };

    // Release builds trade away everything whose only purpose is making a crash
    // readable. Debug keeps all of it — a stripped Debug build would be a
    // strictly worse Debug build.
    const lean = optimize != .Debug;

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    const build_options = options.createModule();

    // The module graph is the architecture, so it exists before the code that
    // fills it. Each module may import only the ones above it in this list.
    //
    //   tugproto      the wire vocabulary; depends on nothing
    //   tugcore       sans-IO logic; must compile for wasm32-freestanding
    //   tugproviders  SSE, transport, mappers; the only module with sockets
    //   tugshell      the terminal frontend
    //   tug           the executable
    //
    // `tugcore` deliberately sits above `tugproviders` in that list and does not
    // import it: the core has to compile for a target with no sockets at all.

    const proto = b.addModule("tugproto", .{
        .root_source_file = b.path("src/proto/root.zig"),
        .target = target,
    });

    const tugcore = b.addModule("tugcore", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "tugproto", .module = proto },
            .{ .name = "build_options", .module = build_options },
        },
    });

    // The provider layer. Not freestanding, not imported by tugcore, and the
    // only module whose `transport/` subtree may open a socket (DR-016).
    const providers = b.addModule("tugproviders", .{
        .root_source_file = b.path("src/providers/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "tugproto", .module = proto },
            // The legal direction. `tugcore` defines the `Provider` seam and
            // must never import this module back — it compiles for a target
            // with no sockets at all, and `zig build wasm-check` is what says
            // so if anyone tries.
            .{ .name = "tugcore", .module = tugcore },
        },
    });

    // `@embedFile` cannot reach outside a module's own directory, and the
    // fixtures live in `testdata/` where the rest of the repo can see them. An
    // anonymous import is the bridge: the parser's tests embed the bytes by
    // import name, and the corpus stays one directory rather than two.
    providers.addAnonymousImport("framing-corners.sse", .{
        .root_source_file = b.path("testdata/fixtures/anthropic/framing-corners.sse"),
    });
    providers.addAnonymousImport("clean-turn.head", .{
        .root_source_file = b.path("testdata/fixtures/anthropic/clean-turn.head"),
    });
    providers.addAnonymousImport("clean-turn.sse", .{
        .root_source_file = b.path("testdata/fixtures/anthropic/clean-turn.sse"),
    });
    providers.addAnonymousImport("request-anthropic.json", .{
        .root_source_file = b.path("testdata/golden/request-anthropic.json"),
    });
    providers.addAnonymousImport("clean-turn.ndjson", .{
        .root_source_file = b.path("testdata/fixtures/anthropic/clean-turn.ndjson"),
    });
    providers.addAnonymousImport("request-openai.json", .{
        .root_source_file = b.path("testdata/golden/request-openai.json"),
    });
    // Prefixed by shape, because `clean-turn` is a case name that exists in
    // both directories and an import name is flat.
    providers.addAnonymousImport("openai-clean-turn.head", .{
        .root_source_file = b.path("testdata/fixtures/openai/clean-turn.head"),
    });
    providers.addAnonymousImport("openai-clean-turn.sse", .{
        .root_source_file = b.path("testdata/fixtures/openai/clean-turn.sse"),
    });
    providers.addAnonymousImport("openai-clean-turn.ndjson", .{
        .root_source_file = b.path("testdata/fixtures/openai/clean-turn.ndjson"),
    });
    providers.addAnonymousImport("openai-usage-absent.sse", .{
        .root_source_file = b.path("testdata/fixtures/openai/usage-absent.sse"),
    });
    providers.addAnonymousImport("openai-usage-absent.ndjson", .{
        .root_source_file = b.path("testdata/fixtures/openai/usage-absent.ndjson"),
    });

    const shell = b.addModule("tugshell", .{
        .root_source_file = b.path("src/shell/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "tugproto", .module = proto },
            .{ .name = "tugcore", .module = tugcore },
            .{ .name = "tugproviders", .module = providers },
        },
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tugproto", .module = proto },
            .{ .name = "tugcore", .module = tugcore },
            .{ .name = "tugshell", .module = shell },
        },

        // No symbol table and no debug info in the output file.
        .strip = lean,
        // Unwind tables exist to walk the stack for a traceback; without them
        // the .pdata and .xdata sections go away.
        .unwind_tables = if (lean) .none else null,
        // Error return traces cost a slot per error site plus the code to fill
        // it in.
        .error_tracing = if (lean) false else null,
        // The frame pointer is only needed to walk the stack, which nothing
        // does once the traces above are gone.
        .omit_frame_pointer = lean,
        .stack_protector = if (lean) false else null,
        .stack_check = if (lean) false else null,
        .sanitize_c = if (lean) .off else null,
        .sanitize_thread = if (lean) false else null,
        //
        // Note the absence of `single_threaded`. The architecture is
        // thread-per-stream from v0.2, so enabling it now would only mean
        // disabling it again in Phase 5.
    });

    const exe = b.addExecutable(.{
        .name = "tug",
        .root_module = exe_mod,
    });

    // Zig reserves 16 MiB of address space for the main thread's stack. tug
    // recurses nowhere near that, and the roadmap's idle-RSS budget is 10 MiB.
    exe.stack_size = 1 * 1024 * 1024;

    // Link-time optimization is deliberately off. It saved 512 bytes when
    // measured against this program, and `-flto=full` on the COFF target fails
    // to link at all — `lld-link: undefined symbol: _tls_index`, thread-local
    // storage that survives into the LTO object with nothing to resolve it
    // against. Revisit when the size gate starts to bite, and measure first.

    b.installArtifact(exe);

    // --- run ---------------------------------------------------------------

    const run_step = b.step("run", "Run tug");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // --- test --------------------------------------------------------------

    // Tests build in Debug regardless of how the executable is configured: a
    // stripped, traceback-free build makes a failing test much harder to read.
    // Every test allocates through `std.testing.allocator`, so a leaked byte is
    // a failed test rather than something noticed in production.
    const test_step = b.step("test", "Run all unit tests");

    const test_targets = [_]struct { name: []const u8, module: *std.Build.Module }{
        .{ .name = "tugproto", .module = proto },
        .{ .name = "tugcore", .module = tugcore },
        .{ .name = "tugproviders", .module = providers },
        .{ .name = "tugshell", .module = shell },
    };

    for (test_targets) |entry| {
        const unit_tests = b.addTest(.{
            .name = entry.name,
            .root_module = entry.module,
        });
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    }

    const exe_tests = b.addTest(.{
        .name = "tug",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .imports = &.{
                .{ .name = "tugproto", .module = proto },
                .{ .name = "tugcore", .module = tugcore },
                .{ .name = "tugshell", .module = shell },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    // --- wasm-check --------------------------------------------------------

    // The tripwire for the sans-IO discipline. `tugcore` must compile for a
    // target with no filesystem, no sockets, no threads and no clock, so
    // reaching for one of those fails here rather than in v0.8 when someone
    // first tries to run the core in a browser.
    const wasm_step = b.step("wasm-check", "Compile tugcore for wasm32-freestanding");
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm_proto = b.createModule(.{
        .root_source_file = b.path("src/proto/root.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    const wasm_core = b.addObject(.{
        .name = "tugcore-wasm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/root.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .imports = &.{
                .{ .name = "tugproto", .module = wasm_proto },
                .{ .name = "build_options", .module = build_options },
            },
        }),
    });
    wasm_step.dependOn(&wasm_core.step);

    // --- fuzz --------------------------------------------------------------

    // The decoder is the one component in v0.1 that parses untrusted input from
    // outside the process, so it is the one with a fuzz target. Running the
    // fuzzer is opt-in and local — `--fuzz` starts a server and does not
    // terminate, which is not a shape a five-minute CI wall can hold. What CI
    // gets is the seed corpus, replayed on every ordinary `zig build test`; the
    // roadmap puts the real fuzzing job in v0.2.
    const fuzz_step = b.step("fuzz", "Build the fuzz targets (add -- --fuzz to run them)");

    // Every module that decodes bytes from outside the process. Two of them now:
    // the terminal's input decoder and the provider layer's SSE parser, which is
    // v0.2's equivalent and hardened the same way.
    const fuzz_targets = [_]struct { name: []const u8, module: *std.Build.Module }{
        .{ .name = "tugshell-fuzz", .module = shell },
        .{ .name = "tugproviders-fuzz", .module = providers },
    };

    for (fuzz_targets) |entry| {
        const fuzz_tests = b.addTest(.{
            .name = entry.name,
            .root_module = entry.module,
            .filters = &.{"fuzz:"},
        });
        fuzz_step.dependOn(&b.addRunArtifact(fuzz_tests).step);
    }

    // --- size --------------------------------------------------------------

    const size_step = b.step("size", "Print the installed binary size against its budget");
    const size_check = b.addSystemCommand(&.{ "sh", "scripts/size-gate.sh" });
    size_check.addFileArg(exe.getEmittedBin());
    size_check.addArg(b.fmt("{d}", .{size_budget_bytes}));
    size_step.dependOn(&size_check.step);

    const ratchet_check = b.addSystemCommand(&.{ "sh", "scripts/size-gate.sh" });
    ratchet_check.addFileArg(exe.getEmittedBin());
    ratchet_check.addArg(b.fmt("{d}", .{size_ratchet_bytes}));
    size_step.dependOn(&ratchet_check.step);

    // --- bench -------------------------------------------------------------

    // `--version` is the one path with a hard latency budget in v0.1: 2 ms,
    // measured with hyperfine, which is why it allocates nothing and reads no
    // config. The step exists from Phase 0 so the number is never a surprise.
    const bench_step = b.step("bench", "Benchmark the --version fast path");
    const bench = b.addSystemCommand(&.{ "sh", "scripts/bench-version.sh" });
    bench.addFileArg(exe.getEmittedBin());
    bench.step.dependOn(b.getInstallStep());
    bench_step.dependOn(&bench.step);
}
