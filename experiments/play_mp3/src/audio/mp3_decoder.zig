const std = @import("std");

// --- Constants and Tables Ported from dr_mp3 ---
const mpeg1_bitrates = [_]u32{0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0};
const mpeg2_bitrates = [_]u32{0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0};
const sample_rates = [_]u32{44100, 48000, 32000, 0};

/// Represents the parsed properties of a single MP3 frame header.
pub const FrameHeader = struct {
    is_valid: bool = false,
    version: Version = .mpeg1,
    layer: Layer = .layer3,
    has_crc: bool = false,
    bitrate_kbps: u32 = 0,
    sample_rate_hz: u32 = 0,
    padding: u32 = 0,
    is_mono: bool = false,
    frame_size_bytes: u32 = 0,

    pub const Version = enum {
        mpeg2_5,
        reserved,
        mpeg2,
        mpeg1,
    };

    pub const Layer = enum {
        reserved,
        layer3,
        layer2,
        layer1,
    };
};

/// Parses the 4-byte header of an MP3 frame.
pub fn parseFrameHeader(header_bytes: [4]u8) FrameHeader {
    // Check for the sync word
    if (header_bytes[0] != 0xFF or (header_bytes[1] & 0xE0) != 0xE0) {
        return .{};
    }

    var h: FrameHeader = .{};

    const version_bits = (header_bytes[1] >> 3) & 0x03;
    h.version = @as(FrameHeader.Version, @enumFromInt(version_bits));

    const layer_bits = (header_bytes[1] >> 1) & 0x03;
    if (layer_bits == 0) return .{}; // reserved layer
    h.layer = @as(FrameHeader.Layer, @enumFromInt(layer_bits));

    h.has_crc = (header_bytes[1] & 0x01) == 0;

    const bitrate_index = (header_bytes[2] >> 4) & 0x0F;
    if (bitrate_index == 15) return .{}; // reserved bitrate
    if (h.version == .mpeg1) {
        h.bitrate_kbps = mpeg1_bitrates[bitrate_index];
    } else {
        h.bitrate_kbps = mpeg2_bitrates[bitrate_index];
    }

    const sample_rate_index = (header_bytes[2] >> 2) & 0x03;
    if (sample_rate_index == 3) return .{}; // reserved sample rate
    h.sample_rate_hz = sample_rates[sample_rate_index];
    if (h.version == .mpeg2) {
        h.sample_rate_hz /= 2;
    } else if (h.version == .mpeg2_5) {
        h.sample_rate_hz /= 4;
    }

    if (h.sample_rate_hz == 0) return .{};

    const padding_bit = (header_bytes[2] >> 1) & 0x01;
    h.padding = if (padding_bit == 1) 1 else 0;

    const channel_mode_bits = (header_bytes[3] >> 6) & 0x03;
    h.is_mono = (channel_mode_bits == 3);

    // Calculate frame size
    const samples_per_frame: u32 = switch (h.layer) {
        .layer1 => 384,
        .layer2 => 1152,
        .layer3 => if (h.version == .mpeg1) 1152 else 576,
        else => return .{},
    };

    const frame_size = (samples_per_frame * (h.bitrate_kbps * 1000)) / 8 / h.sample_rate_hz;
    if (h.layer == .layer1) {
        h.frame_size_bytes = (frame_size + h.padding) * 4;
    } else {
        h.frame_size_bytes = frame_size + h.padding;
    }

    h.is_valid = true;
    return h;
}

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
