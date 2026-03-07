# Performance Profiling

This project has two built-in profiling paths:

1. Exact per-pass timings from the renderer.
2. Native call-stack sampling from `tools/native_stack_sampler.py`.

Use both for performance reviews. The pass timings tell you which render pass is slow. The stack sampler tells you where the CPU is spending time inside that pass.

## 1. Build For Profiling

For call-stack sampling, keep frame pointers enabled:

```powershell
zig build -Dprofile=true
```

For realistic numbers in optimized builds:

```powershell
zig build -Doptimize=ReleaseFast -Dprofile=true
```

`Debug` is still useful when you want easy-to-read behavior and worst-case hotspot visibility.

## 2. Exact Frame Timings

The renderer can print exact timings for a specific frame by setting `ZIG_RENDER_PROFILE_FRAME`.

Example:

```powershell
$env:ZIG_RENDER_PROFILE_FRAME = '120'
zig-out\bin\zig-windows-app.exe
```

At the selected frame, the renderer logs lines like:

```text
[renderer.core] [INFO] [frame_profile] meshlet_tiled: 2.446 ms
[renderer.core] [INFO] [frame_profile] hybrid_shadow: 75.012 ms
[renderer.core] [INFO] [frame_profile] ssao: 2.678 ms
```

For hybrid shadows, it also prints detailed sub-metrics:

```text
hybrid_shadow detail accel=... candidate=... clear=... execute=... jobs=... active_tiles=...
```

That breakdown is the fastest way to decide whether the problem is:

- acceleration structure work
- candidate building
- cache clearing
- actual shadow execution

Clear the variable after use if needed:

```powershell
Remove-Item Env:ZIG_RENDER_PROFILE_FRAME
```

## 3. Call-Stack Sampling

Use the local sampler in `tools/native_stack_sampler.py`.

Sample a running process:

```powershell
python tools\native_stack_sampler.py <pid> 1
```

Launch, warm up, sample for one second, then terminate automatically:

```powershell
python tools\native_stack_sampler.py --launch zig-out\bin\zig-windows-app.exe 12 1
```

Recommended combined workflow:

```powershell
zig build -Dprofile=true
$env:ZIG_RENDER_PROFILE_FRAME = '120'
python tools\native_stack_sampler.py --launch zig-out\bin\zig-windows-app.exe 12 1
```

That gives you:

- `TOP LEAF FRAMES`
- `TOP INCLUSIVE FRAMES`
- `TOP STACKS`
- exact renderer pass timings for frame `120`

## 4. How To Read Results

Use the reports in this order:

1. Find the dominant pass from `frame_profile`.
2. Check pass-specific detail fields if available.
3. Look at `TOP STACKS` and `TOP INCLUSIVE FRAMES`.
4. Ignore tiny passes until the dominant pass is under control.

Example interpretation:

- If `hybrid_shadow` is `75 ms` and everything else is under `3 ms`, do not optimize bloom or fog.
- If `hybrid_shadow candidate` is small but `execute` is huge, the problem is per-sample shadow work, not setup.
- If `meshlet_tiled` rises, inspect raster, interpolation, overdraw, and tile binning.

## 5. Recommended Review Routine

For any serious performance review:

1. Run one `Debug` capture to identify the dominant system quickly.
2. Run one `ReleaseFast` capture to see whether the same hotspot still matters in optimized code.
3. Make one change at a time.
4. Re-run the same frame and same sampler duration.
5. Record before/after numbers for the exact pass you changed.

## 6. Visual Validation

If a change affects image quality, capture a screenshot before and after profiling. Performance-only changes are not enough if they break shadow edges, SSAO, textures, or model loading.
