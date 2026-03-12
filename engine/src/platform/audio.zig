//! Audio module.
//! Platform abstraction layer for windowing, input, and system integration.

const platform_audio = @import("platform/audio.zig");
pub usingnamespace platform_audio;
