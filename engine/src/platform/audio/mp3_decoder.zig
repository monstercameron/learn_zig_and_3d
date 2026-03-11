const std = @import("std");

/// A pure Zig port of the bitstream reader from dr_mp3.
/// This struct allows reading a specific number of bits from a byte slice.
pub const BitStream = struct {
    buf: []const u8,
    pos: usize, // Position in bits
    limit: usize, // Total limit in bits

    /// Initializes a new bitstream reader from a byte slice.
    pub fn init(data: []const u8) BitStream {
        return .{
            .buf = data,
            .pos = 0,
            .limit = data.len * 8,
        };
    }

    /// Reads the next `n` bits from the stream and advances the position.
    /// Returns 0 if the read goes past the end of the buffer.
    pub fn getBits(self: *BitStream, n: u8) u32 {
        if (n > 32) return 0; // Cannot read more than 32 bits at a time

        // Check if the read would go out of bounds
        if (self.pos + n > self.limit) {
            // To prevent repeated failed reads, advance position to the end
            self.pos = self.limit;
            return 0;
        }

        const byte_index = self.pos / 8;
        const bit_offset = self.pos & 7;

        // This implementation is simpler and safer than the C version, but potentially slower.
        // It reads bytes one by one and assembles the result.
        var cache: u64 = 0;
        var i: usize = 0;
        while (i < 5 and (byte_index + i) < self.buf.len) : (i += 1) {
            cache |= @as(u64, self.buf[byte_index + i]) << @as(u5, i * 8);
        }

        const result = @as(u32, @truncate((cache >> @as(u6, bit_offset)) & (@as(u64, 1) << @as(u6, n)) - 1));

        self.pos += n;
        return result;
    }
};
