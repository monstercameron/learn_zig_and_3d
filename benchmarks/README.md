# Benchmarks

This subproject contains focused microbenchmarks for math kernels, meshlet work, lighting paths, and render-job behavior.

## Purpose

- measure hot code paths without the full renderer loop
- compare scalar and SIMD variants
- validate optimization ideas before landing them in the main app

## Commands

From the repository root:

```powershell
zig build benchmarks
zig build run-benchmarks
```

From this folder directly:

```powershell
zig build
zig build run
```

## Layout

- `build.zig`: benchmark build entry point
- `src/main.zig`: benchmark driver
- `src/bench_*.zig`: individual benchmark cases