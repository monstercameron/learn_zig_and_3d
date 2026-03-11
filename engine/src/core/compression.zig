//! # Compression/Decompression Utilities
//!
//! This module provides pure functions for basic data compression and decompression.
//! These utilities are designed to be lightweight and suitable for use in a CPU-based
//! renderer, for example, to compress texture data, vertex attributes, or other
//! repetitive data streams.
//!
//! The primary algorithm implemented here is a simple Run-Length Encoding (RLE).
//! RLE is effective for data that contains long sequences of identical values.
//!
//! ## Run-Length Encoding (RLE) Scheme Used
//!
//! This RLE implementation uses a control byte to indicate the type and length of a run:
//! 
//! *   **Repeated Run**: `[count_byte, value_byte]`
//!     *   `count_byte`: A `u8` value from `0` to `127`.
//!     *   This signifies `count_byte + 1` repetitions of `value_byte`.
//!     *   Example: `[0x02, 0xFF]` means three `0xFF` bytes (`0xFF 0xFF 0xFF`).
//! 
//! *   **Literal Run**: `[count_byte | 0x80, byte1, byte2, ..., byteN]`
//!     *   `count_byte`: A `u8` value from `0` to `127`.
//!     *   The most significant bit (`0x80`) is set to indicate a literal run.
//!     *   This signifies `count_byte + 1` literal bytes follow immediately.
//!     *   Example: `[0x82, 0x11, 0x22, 0x33]` means three literal bytes (`0x11 0x22 0x33`).
//! 
//! This scheme allows for runs of up to 128 bytes (0-127) for both repeated and literal data.

const std = @import("std");

/// Compresses a slice of bytes using Run-Length Encoding (RLE).
///
/// The RLE scheme uses a control byte:
/// - `0..127`: `count + 1` repetitions of the next byte.
/// - `0x80..0xFF`: `(count & 0x7F) + 1` literal bytes follow.
///
/// Args:
///   input_data: The uncompressed data as a slice of `u8`.
///   allocator: The allocator to use for the output `ArrayList`.
/// Returns:
///   An `ArrayList(u8)` containing the compressed data.
pub fn compress_rle(input_data: []const u8, allocator: std.mem.Allocator) !std.ArrayList(u8) {
    var compressed_data = std.ArrayList(u8).init(allocator);
    var i: usize = 0;
    while (i < input_data.len) {
        const current_byte = input_data[i];
        var run_length: u8 = 0;

        // Try to find a repeated run
        var j = i;
        while (j < input_data.len and input_data[j] == current_byte and run_length < 127) : (j += 1) {
            run_length += 1;
        }

        if (run_length > 1) {
            // Found a repeated run
            try compressed_data.append(run_length - 1); // Store count - 1
            try compressed_data.append(current_byte);
            i += run_length;
        } else {
            // Literal run (or single byte)
            var literal_start = i;
            var literal_length: u8 = 0;
            // Find a sequence of non-repeating bytes or a single byte
            while (literal_length < 127 and i < input_data.len) : (i += 1) {
                if (i + 1 < input_data.len and input_data[i] == input_data[i + 1]) {
                    // Next byte repeats, so end literal run here
                    break;
                }
                literal_length += 1;
            }

            try compressed_data.append(literal_length - 1 | 0x80); // Store count - 1 with MSB set
            var k: usize = 0;
            while (k < literal_length) : (k += 1) {
                try compressed_data.append(input_data[literal_start + k]);
            }
        }
    }
    return compressed_data;
}

/// Decompresses a slice of RLE-compressed bytes.
///
/// Args:
///   compressed_data: The RLE-compressed data as a slice of `u8`.
///   original_size: The expected size of the decompressed data. Used for pre-allocating.
///   allocator: The allocator to use for the output `ArrayList`.
/// Returns:
///   An `ArrayList(u8)` containing the decompressed data.
pub fn decompress_rle(compressed_data: []const u8, original_size: usize, allocator: std.mem.Allocator) !std.ArrayList(u8) {
    var decompressed_data = std.ArrayList(u8).initCapacity(allocator, original_size) catch |err| {
        std.debug.print("Failed to pre-allocate for decompression: {s}\n", .{@errorName(err)});
        return err;
    };

    var i: usize = 0;
    while (i < compressed_data.len) {
        const control_byte = compressed_data[i];
        i += 1;

        if ((control_byte & 0x80) != 0) {
            // Literal run
            const literal_length = (control_byte & 0x7F) + 1;
            if (i + literal_length > compressed_data.len) return error.InvalidCompressedData;
            var j: u8 = 0;
            while (j < literal_length) : (j += 1) {
                try decompressed_data.append(compressed_data[i + j]);
            }
            i += literal_length;
        } else {
            // Repeated run
            const repeat_length = control_byte + 1;
            if (i >= compressed_data.len) return error.InvalidCompressedData;
            const value_byte = compressed_data[i];
            i += 1;
            var j: u8 = 0;
            while (j < repeat_length) : (j += 1) {
                try decompressed_data.append(value_byte);
            }
        }
    }

    if (decompressed_data.items.len != original_size) {
        std.debug.print("Decompressed size mismatch! Expected {d}, got {d}\n", .{original_size, decompressed_data.items.len});
        return error.DecompressedSizeMismatch;
    }

    return decompressed_data;
}
