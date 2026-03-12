//! Primary entry point for the app target.
//! Application entry/runtime glue for launching the sample app.

const engine_app = @import("engine_main");

/// Module entry point used by the runtime/bootstrap path.
/// Propagates recoverable errors so allocation/IO failures stay explicit to the caller.
pub fn main() !void {
    return engine_app.main();
}
