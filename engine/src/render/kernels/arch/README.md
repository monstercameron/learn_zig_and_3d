# Kernel arch/ subfolders

This folder is reserved for ISA-specific kernel implementations once
the cross-ISA benchmark (see ROADMAP.md Phase B) starts landing
AVX-512, NEON, and SVE paths.

Expected layout once populated:

```
kernels/
├── arch/
│   ├── scalar/          # baseline, no SIMD
│   ├── x86_sse2/
│   ├── x86_avx2/        # current default for x86_64
│   ├── x86_avx512/
│   ├── arm_neon/        # Apple Silicon native + Graviton
│   └── arm_sve/         # Graviton 3+, scalable lane count
└── <kernel_name>.zig    # remains the dispatch shim; selects an
                        # arch/<isa>/<kernel_name>.zig at runtime
                        # via cpu_features
```

The dispatch shim pattern keeps the public kernel name stable while
letting each ISA path live in a focused file. Today every kernel is
flat at `kernels/*.zig` because only scalar/SSE2/AVX2 are
implemented and they branch inline on `runtime_*_lanes()`. When the
AVX-512/NEON/SVE work lands, files split here.
