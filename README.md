# tug

A Zig project set up to produce a small binary with a small memory footprint.

## Build

```sh
zig build                    # ReleaseSmall, the default here
zig build run                # build and run
zig build test               # run tests (always built in Debug)
zig build -Doptimize=Debug   # or ReleaseSafe / ReleaseFast
```

## Layout

- `src/main.zig` — executable entry point
- `src/root.zig` — library module, importable as `@import("tug")`
- `build.zig` — build script
- `build.zig.zon` — package manifest

## How the size is kept down

`zig build` defaults to `ReleaseSmall` instead of `Debug`, and release builds
drop everything whose only purpose is to make a crash readable: debug info,
unwind tables, error return traces, frame pointers, stack canaries and the
sanitizers. The panic handler is swapped for `std.debug.simple_panic`, which
still prints the panic message but does not carry a debug info reader to
symbolize the stack with. Link-time optimization runs across the whole program.

Two things in `src/main.zig` matter more than any build flag:

- `std_options` turns off networking and TLS. Nothing here opens a socket, and
  the socket, DNS and TLS code together are worth about 85 KB.
- `main` takes `std.process.Init.Minimal` rather than the full
  `std.process.Init`, so the runtime does not construct a general purpose
  allocator, a process-wide arena, an environment map and a thread pool before
  `main` is entered. The `Io` implementation is built explicitly instead, in its
  single-threaded, non-allocating form.

Add any of those back if the program comes to need them — each one is a comment
in `src/main.zig` explaining what it costs.

At runtime the executable reserves 1 MB of stack rather than Zig's default of
16 MB, and allocates nothing on the heap: arguments are split into a fixed
stack buffer and output goes through a 512-byte buffered writer.

Roughly 200 KB of what is left is zero-filled tables inside `std.Io`, which are
backed by the file and never faulted into memory unless something touches them.
Getting past that floor would mean calling the platform directly instead of
going through `std.Io`, which is not a trade this project makes.
