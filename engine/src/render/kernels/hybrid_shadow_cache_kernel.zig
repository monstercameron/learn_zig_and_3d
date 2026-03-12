//! Implements the Hybrid Shadow Cache kernel logic used in renderer jobs.
//! CPU pixel/compute kernel used by the software renderer post-processing and shading stack.

/// Clears c le ar un kn ow n.
/// Structured for hot inner-loop execution with predictable memory access and minimal branching for CPU SIMD paths.
pub fn clearUnknown(cache: []u8) void {
    @memset(cache, 0xFF);
}
