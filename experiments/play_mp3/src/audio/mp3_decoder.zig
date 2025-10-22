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

/// Holds the side information for a single granule in an MP3 frame.
/// This data describes how the main frame data is packed and compressed.
pub const GranuleInfo = extern struct {
    part2_3_length: u16,
    big_values: u16,
    global_gain: u8,
    scalefac_compress: u16,
    window_switching_flag: bool,

    // if window_switching_flag
    block_type: u2,
    mixed_block_flag: bool,
    table_select: [3]u5,
    subblock_gain: [3]u3,

    // else
    region0_count: u4,
    region1_count: u3,

    preflag: bool,
    scalefac_scale: u1,
    count1table_select: u1,
};

/// Side information for an entire MP3 frame.
/// For MPEG1, there are 2 granules per channel.
/// For MPEG2, there is 1 granule per channel.
pub const SideInfo = struct {
    main_data_begin: u9,
    private_bits: u5, // just for stereo, 3 for mono
    scfsi: [2]u4, // scale factor selection info
    granules: [2][2]GranuleInfo, // [channel][granule]
};

/// Parses the Layer 3 side information from the bitstream.
    return side_info;
}

// --- Scalefactor Band Calculation ---

const scale_factor_bands_long = [8][23]u8{
    { 6,6,6,6,6,6,8,10,12,14,16,20,24,28,32,38,46,52,60,68,58,54,0 },
    { 12,12,12,12,12,12,16,20,24,28,32,40,48,56,64,76,90,2,2,2,2,2,0 },
    { 6,6,6,6,6,6,8,10,12,14,16,20,24,28,32,38,46,52,60,68,58,54,0 },
    { 6,6,6,6,6,6,8,10,12,14,16,18,22,26,32,38,46,54,62,70,76,36,0 },
    { 6,6,6,6,6,6,8,10,12,14,16,20,24,28,32,38,46,52,60,68,58,54,0 },
    { 4,4,4,4,4,4,6,6,8,8,10,12,16,20,24,28,34,42,50,54,76,158,0 },
    { 4,4,4,4,4,4,6,6,6,8,10,12,16,18,22,28,34,40,46,54,54,192,0 },
    { 4,4,4,4,4,4,6,6,8,10,12,16,20,24,30,38,46,56,68,84,102,26,0 },
};
const scale_factor_bands_short = [8][40]u8{
    { 4,4,4,4,4,4,4,4,4,6,6,6,8,8,8,10,10,10,12,12,12,14,14,14,18,18,18,24,24,24,30,30,30,40,40,40,18,18,18,0 },
    { 8,8,8,8,8,8,8,8,8,12,12,12,16,16,16,20,20,20,24,24,24,28,28,28,36,36,36,2,2,2,2,2,2,2,2,2,26,26,26,0 },
    { 4,4,4,4,4,4,4,4,4,6,6,6,6,6,6,8,8,8,10,10,10,14,14,14,18,18,18,26,26,26,32,32,32,42,42,42,18,18,18,0 },
    { 4,4,4,4,4,4,4,4,4,6,6,6,8,8,8,10,10,10,12,12,12,14,14,14,18,18,18,24,24,24,32,32,32,44,44,44,12,12,12,0 },
    { 4,4,4,4,4,4,4,4,4,6,6,6,8,8,8,10,10,10,12,12,12,14,14,14,18,18,18,24,24,24,30,30,30,40,40,40,18,18,18,0 },
    { 4,4,4,4,4,4,4,4,4,4,4,4,6,6,6,8,8,8,10,10,10,12,12,12,14,14,14,18,18,18,22,22,22,30,30,30,56,56,56,0 },
    { 4,4,4,4,4,4,4,4,4,4,4,4,6,6,6,6,6,6,10,10,10,12,12,12,14,14,14,16,16,16,20,20,20,26,26,26,66,66,66,0 },
    { 4,4,4,4,4,4,4,4,4,4,4,4,6,6,6,8,8,8,12,12,12,16,16,16,20,20,20,26,26,26,34,34,34,42,42,42,12,12,12,0 },
};
const scale_factor_bands_mixed = [8][40]u8{
    { 6,6,6,6,6,6,6,6,6,8,8,8,10,10,10,12,12,12,14,14,14,18,18,18,24,24,24,30,30,30,40,40,40,18,18,18,0 },
    { 12,12,12,4,4,4,8,8,8,12,12,12,16,16,16,20,20,20,24,24,24,28,28,28,36,36,36,2,2,2,2,2,2,2,2,2,26,26,26,0 },
    { 6,6,6,6,6,6,6,6,6,6,6,6,8,8,8,10,10,10,14,14,14,18,18,18,26,26,26,32,32,32,42,42,42,18,18,18,0 },
    { 6,6,6,6,6,6,6,6,6,8,8,8,10,10,10,12,12,12,14,14,14,18,18,18,24,24,24,32,32,32,44,44,44,12,12,12,0 },
    { 6,6,6,6,6,6,6,6,6,8,8,8,10,10,10,12,12,12,14,14,14,18,18,18,24,24,24,30,30,30,40,40,40,18,18,18,0 },
    { 4,4,4,4,4,4,6,6,4,4,4,6,6,6,8,8,8,10,10,10,12,12,12,14,14,14,18,18,18,22,22,22,30,30,30,56,56,56,0 },
    { 4,4,4,4,4,4,6,6,4,4,4,6,6,6,6,6,6,10,10,10,12,12,12,14,14,14,16,16,16,20,20,20,26,26,26,66,66,66,0 },
    { 4,4,4,4,4,4,6,6,4,4,4,6,6,6,8,8,8,12,12,12,16,16,16,20,20,20,26,26,26,34,34,34,42,42,42,12,12,12,0 },
};

pub fn getScaleFactorBands(h: FrameHeader, gr: GranuleInfo) struct { bands: []const u8, n_long: u8, n_short: u8 } {
    const sr_idx = switch (h.sample_rate_hz) {
        44100 => 0,
        48000 => 1,
        32000 => 2,
        22050 => 0,
        24000 => 1,
        16000 => 2,
        11025 => 0,
        12000 => 1,
        8000 => 2,
        else => 0,
    };

    if (gr.window_switching_flag and gr.block_type == 2) {
        if (gr.mixed_block_flag) {
            return .{ .bands = &scale_factor_bands_mixed[sr_idx], .n_long = if (h.version == .mpeg1) 8 else 6, .n_short = 30 };
        } else {
            return .{ .bands = &scale_factor_bands_short[sr_idx], .n_long = 0, .n_short = 39 };
        }
    } else {
        return .{ .bands = &scale_factor_bands_long[sr_idx], .n_long = 22, .n_short = 0 };
    }
}

fn midsideStereo(left: []f32, n: usize) void {
    const right = left[576..];
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const l = left[i];
        const r = right[i];
        left[i] = l + r;
        right[i] = l - r;
    }
}

fn intensityStereoBand(left: []f32, n: usize, kl: f32, kr: f32) void {
    const right = left[576..];
    var i: usize = 0;
    while (i < n) : (i += 1) {
        right[i] = left[i] * kr;
        left[i] *= kl;
    }
}

/// Processes MS/IS stereo modes for a granule.
pub fn stereoProcess(h: FrameHeader, gr: GranuleInfo, sfb: []const u8, ist_pos: []const u8, samples: []f32) void {
    if (h.is_mono) return;

    if (h.isMsStereo()) { // TODO: Need to implement this check on FrameHeader
        midsideStereo(samples, 576);
    }

    // TODO: Port the full intensity stereo logic from drmp3_L3_stereo_process
    _ = gr;
    _ = sfb;
    _ = ist_pos;
}

/// Reorders the spectral values when short blocks are used.
pub fn reorder(gr_buf: []f32, scratch: []f32, sfb: []const u8) void {
    var src_ptr = gr_buf;
    var dst_ptr = scratch;
    var sfb_idx: usize = 0;
    while (sfb[sfb_idx] > 0) {
        const len = sfb[sfb_idx];
        var i: usize = 0;
        while (i < len) : (i += 1) {
            dst_ptr[0] = src_ptr[0];
            dst_ptr[1] = src_ptr[len];
            dst_ptr[2] = src_ptr[2 * len];
            dst_ptr = dst_ptr[3..];
            src_ptr = src_ptr[1..];
        }
        sfb_idx += 3;
        src_ptr = src_ptr[2 * len..];
    }
    @memcpy(gr_buf, scratch[0..dst_ptr.len]);
}

const antialias_cs = [_]f32{0.85749293,0.88174200,0.94962865,0.98331459,0.99551782,0.99916056,0.99989920,0.99999316};
const antialias_ca = [_]f32{0.51449576,0.47173197,0.31337745,0.18191320,0.09457419,0.04096558,0.01419856,0.00369997};

/// Applies an antialiasing filter to the spectral data.
pub fn antialias(gr_buf: []f32, nbands: usize) void {
    var bands = nbands;
    var buf_ptr = gr_buf;
    while (bands > 0) : (bands -= 1) {
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            const u = buf_ptr[18 + i];
            const d = buf_ptr[17 - i];
            buf_ptr[18 + i] = u * antialias_cs[i] - d * antialias_ca[i];
            buf_ptr[17 - i] = u * antialias_ca[i] + d * antialias_cs[i];
        }
        buf_ptr = buf_ptr[18..];
    }
}

// --- Sub-band Synthesis (Polyphase Filterbank) ---

fn dct2(samples: []f32, n: usize) void {
    // This is a port of drmp3d_DCT_II
    // It's a highly optimized DCT-II implementation.
    // Due to its complexity and heavy use of SIMD intrinsics in the C source,
    // a direct, performant port is a major task. This is a simplified placeholder.
    _ = samples;
    _ = n;
}

pub fn synthGranule(qmf_state: []f32, gr_buf: []f32, nbands: usize, num_channels: u16, pcm: []f32, lins: []f32) void {
    // Port of drmp3d_synth_granule
    var i: usize = 0;
    while (i < num_channels) : (i += 1) {
        dct2(gr_buf[576*i..], nbands);
    }

    @memcpy(lins, qmf_state);
    i = 0;
    while (i < nbands) : (i += 2) {
        // synth(gr_buf[i..], pcm[(32*num_channels*i)..], num_channels, lins[(i*64)..]);
    }

    if (num_channels == 1) {
        i = 0;
        while (i < 15*64) : (i += 2) {
            qmf_state[i] = lins[nbands*64 + i];
        }
    } else {
        @memcpy(qmf_state, lins[nbands*64..]);
    }
    _ = pcm;
}

// --- IMDCT (Inverse Modified Discrete Cosine Transform) ---

const imdct_twiddle_factors = [_]f32{ 0.73727734,0.79335334,0.84339145,0.88701083,0.92387953,0.95371695,0.97629601,0.99144486,0.99904822,0.67559021,0.60876143,0.53729961,0.46174861,0.38268343,0.30070580,0.21643961,0.13052619,0.04361938 };

fn dct3_9(y: []f32) void {
    const s0 = y[0]; const s1 = y[1]; const s2 = y[2]; const s3 = y[3]; const s4 = y[4]; const s5 = y[5]; const s6 = y[6]; const s7 = y[7]; const s8 = y[8];
    const t0 = s0 + s6*0.5;
    const s0_new = s0 - s6;
    const t4 = (s4 + s2)*0.93969262;
    const t2 = (s8 + s2)*0.76604444;
    const s6_new = (s4 - s8)*0.17364818;
    const s4_new = s4 + s8 - s2;
    const s2_new = s0_new - s4_new*0.5;
    y[4] = s4_new + s0_new;
    const s8_new = t0 - t2 + s6_new;
    const s0_final = t0 - t4 + t2;
    const s4_final = t0 + t4 - s6_new;
    const s3_new = s3 * 0.86602540;
    const t0_2 = (s5 + s1)*0.98480775;
    const t4_2 = (s5 - s7)*0.34202014;
    const t2_2 = (s1 + s7)*0.64278761;
    const s1_new = (s1 - s5 - s7)*0.86602540;
    const s5_new = t0_2 - s3_new - t2_2;
    const s7_new = t4_2 - s3_new - t0_2;
    const s3_final = t4_2 + s3_new - t2_2;
    y[0] = s4_final - s7_new;
    y[1] = s2_new + s1_new;
    y[2] = s0_final - s3_final;
    y[3] = s8_new + s5_new;
    y[5] = s8_new - s5_new;
    y[6] = s0_final + s3_final;
    y[7] = s2_new - s1_new;
    y[8] = s4_final + s7_new;
}

fn imdct36(gr_buf: []f32, overlap: []f32, window: []const f32, nbands: usize) void {
    var band_buf = gr_buf;
    var overlap_buf = overlap;
    var band: usize = 0;
    while (band < nbands) : (band += 1) {
        var co: [9]f32 = undefined;
        var si: [9]f32 = undefined;
        co[0] = -band_buf[0];
        si[0] = band_buf[17];
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            si[8 - 2*i] = band_buf[4*i + 1] - band_buf[4*i + 2];
            co[1 + 2*i] = band_buf[4*i + 1] + band_buf[4*i + 2];
            si[7 - 2*i] = band_buf[4*i + 4] - band_buf[4*i + 3];
            co[2 + 2*i] = -(band_buf[4*i + 3] + band_buf[4*i + 4]);
        }
        dct3_9(&co);
        dct3_9(&si);
        si[1] = -si[1]; si[3] = -si[3]; si[5] = -si[5]; si[7] = -si[7];
        i = 0;
        while (i < 9) : (i += 1) {
            const ovl = overlap_buf[i];
            const sum = co[i]*imdct_twiddle_factors[9 + i] + si[i]*imdct_twiddle_factors[0 + i];
            overlap_buf[i] = co[i]*imdct_twiddle_factors[0 + i] - si[i]*imdct_twiddle_factors[9 + i];
            band_buf[i] = ovl*window[0 + i] - sum*window[9 + i];
            band_buf[17 - i] = ovl*window[9 + i] + sum*window[0 + i];
        }
        band_buf = band_buf[18..];
        overlap_buf = overlap_buf[9..];
    }
}

// --- Huffman Decoding Data and Logic ---

const huffman_linbits = [_]u8{ 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,2,3,4,6,8,10,13,4,5,6,7,8,9,11,13 };
const huffman_tab_index = [_]i16{ 0,32,64,98,0,132,180,218,292,364,426,538,648,746,0,1126,1460,1460,1460,1460,1460,1460,1460,1460,1842,1842,1842,1842,1842,1842,1842,1842 };
const huffman_tab32 = [_]u8{ 130,162,193,209,44,28,76,140,9,9,9,9,9,9,9,9,190,254,222,238,126,94,157,157,109,61,173,205};
const huffman_tab33 = [_]u8{ 252,236,220,204,188,172,156,140,124,108,92,76,60,44,28,12 };

const huffman_tables = [_]i16{
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    785,785,785,785,784,784,784,784,513,513,513,513,513,513,513,513,256,256,256,256,256,256,256,256,256,256,256,256,256,256,256,256,
    -255,1313,1298,1282,785,785,785,785,784,784,784,784,769,769,769,769,256,256,256,256,256,256,256,256,256,256,256,256,256,256,256,256,290,288,
    -255,1313,1298,1282,769,769,769,769,529,529,529,529,529,529,529,529,528,528,528,528,528,528,528,528,512,512,512,512,512,512,512,512,290,288,
    -253,-318,-351,-367,785,785,785,785,784,784,784,784,769,769,769,769,256,256,256,256,256,256,256,256,256,256,256,256,256,256,256,256,819,818,547,547,275,275,275,275,561,560,515,546,289,274,288,258,
    -254,-287,1329,1299,1314,1312,1057,1057,1042,1042,1026,1026,784,784,784,784,529,529,529,529,529,529,529,529,769,769,769,769,768,768,768,768,563,560,306,306,291,259,
    -252,-413,-477,-542,1298,-575,1041,1041,784,784,784,784,769,769,769,769,256,256,256,256,256,256,256,256,256,256,256,256,256,256,256,256,-383,-399,1107,1092,1106,1061,849,849,789,789,1104,1091,773,773,1076,1075,341,340,325,309,834,804,577,577,532,532,516,516,832,818,803,816,561,561,531,531,515,546,289,289,288,258,
    -252,-429,-493,-559,1057,1057,1042,1042,529,529,529,529,529,529,529,529,784,784,784,784,769,769,769,769,512,512,512,512,512,512,512,512,-382,1077,-415,1106,1061,1104,849,849,789,789,1091,1076,1029,1075,834,834,597,581,340,340,339,324,804,833,532,532,832,772,818,803,817,787,816,771,290,290,290,290,288,258,
    -253,-349,-414,-447,-463,1329,1299,-479,1314,1312,1057,1057,1042,1042,1026,1026,785,785,785,785,784,784,784,784,769,769,769,769,768,768,768,768,-319,851,821,-335,836,850,805,849,341,340,325,336,533,533,579,579,564,564,773,832,578,548,563,516,321,276,306,291,304,259,
    -251,-572,-733,-830,-863,-879,1041,1041,784,784,784,784,769,769,769,769,256,256,256,256,256,256,256,256,256,256,256,256,256,256,256,256,-511,-527,-543,1396,1351,1381,1366,1395,1335,1380,-559,1334,1138,1138,1063,1063,1350,1392,1031,1031,1062,1062,1364,1363,1120,1120,1333,1348,881,881,881,881,375,374,359,373,343,358,341,325,791,791,1123,1122,-703,1105,1045,-719,865,865,790,790,774,774,1104,1029,338,293,323,308,-799,-815,833,788,772,818,803,816,322,292,307,320,561,531,515,546,289,274,288,258,
    -251,-525,-605,-685,-765,-831,-846,1298,1057,1057,1312,1282,785,785,785,785,784,784,784,784,769,769,769,769,512,512,512,512,512,512,512,512,1399,1398,1383,1367,1382,1396,1351,-511,1381,1366,1139,1139,1079,1079,1124,1124,1364,1349,1363,1333,882,882,882,882,807,807,807,807,1094,1094,1136,1136,373,341,535,535,881,775,867,822,774,-591,324,338,-671,849,550,550,866,864,609,609,293,336,534,534,789,835,773,-751,834,804,308,307,833,788,832,772,562,562,547,547,305,275,560,515,290,290,
    -252,-397,-477,-557,-622,-653,-719,-735,-750,1329,1299,1314,1057,1057,1042,1042,1312,1282,1024,1024,785,785,785,785,784,784,784,784,769,769,769,769,-383,1127,1141,1111,1126,1140,1095,1110,869,869,883,883,1079,1109,882,882,375,374,807,868,838,881,791,-463,867,822,368,263,852,837,836,-543,610,610,550,550,352,336,534,534,865,774,851,821,850,805,593,533,579,564,773,832,578,578,548,548,577,577,307,276,306,291,516,560,259,259,
    -250,-2107,-2507,-2764,-2909,-2974,-3007,-3023,1041,1041,1040,1040,769,769,769,769,256,256,256,256,256,256,256,256,256,256,256,256,256,256,256,256,-767,-1052,-1213,-1277,-1358,-1405,-1469,-1535,-1550,-1582,-1614,-1647,-1662,-1694,-1726,-1759,-1774,-1807,-1822,-1854,-1886,1565,-1919,-1935,-1951,-1967,1731,1730,1580,1717,-1983,1729,1564,-1999,1548,-2015,-2031,1715,1595,-2047,1714,-2063,1610,-2079,1609,-2095,1323,1323,1457,1457,1307,1307,1712,1547,1641,1700,1699,1594,1685,1625,1442,1442,1322,1322,-780,-973,-910,1279,1278,1277,1262,1276,1261,1275,1215,1260,1229,-959,974,974,989,989,-943,735,478,478,495,463,506,414,-1039,1003,958,1017,927,942,987,957,431,476,1272,1167,1228,-1183,1256,-1199,895,895,941,941,1242,1227,1212,1135,1014,1014,490,489,503,487,910,1013,985,925,863,894,970,955,1012,847,-1343,831,755,755,984,909,428,366,754,559,-1391,752,486,457,924,997,698,698,983,893,740,740,908,877,739,739,667,667,953,938,497,287,271,271,683,606,590,712,726,574,302,302,738,736,481,286,526,725,605,711,636,724,696,651,589,681,666,710,364,467,573,695,466,466,301,465,379,379,709,604,665,679,316,316,634,633,436,436,464,269,424,394,452,332,438,363,347,408,393,448,331,422,362,407,392,421,346,406,391,376,375,359,1441,1306,-2367,1290,-2383,1337,-2399,-2415,1426,1321,-2431,1411,1336,-2447,-2463,-2479,1169,1169,1049,1049,1424,1289,1412,1352,1319,-2495,1154,1154,1064,1064,1153,1153,416,390,360,404,403,389,344,374,373,343,358,372,327,357,342,311,356,326,1395,1394,1137,1137,1047,1047,1365,1392,1287,1379,1334,1364,1349,1378,1318,1363,792,792,792,792,1152,1152,1032,1032,1121,1121,1046,1046,1120,1120,1030,1030,-2895,1106,1061,1104,849,849,789,789,1091,1076,1029,1090,1060,1075,833,833,309,324,532,532,832,772,818,803,561,561,531,560,515,546,289,274,288,258,
    -250,-1179,-1579,-1836,-1996,-2124,-2253,-2333,-2413,-2477,-2542,-2574,-2607,-2622,-2655,1314,1313,1298,1312,1282,785,785,785,785,1040,1040,1025,1025,768,768,768,768,-766,-798,-830,-862,-895,-911,-927,-943,-959,-975,-991,-1007,-1023,-1039,-1055,-1070,1724,1647,-1103,-1119,1631,1767,1662,1738,1708,1723,-1135,1780,1615,1779,1599,1677,1646,1778,1583,-1151,1777,1567,1737,1692,1765,1722,1707,1630,1751,1661,1764,1614,1736,1676,1763,1750,1645,1598,1721,1691,1762,1706,1582,1761,1566,-1167,1749,1629,767,766,751,765,494,494,735,764,719,749,734,763,447,447,748,718,477,506,431,491,446,476,461,505,415,430,475,445,504,399,460,489,414,503,383,474,429,459,502,502,746,752,488,398,501,473,413,472,486,271,480,270,-1439,-1455,1357,-1471,-1487,-1503,1341,1325,-1519,1489,1463,1403,1309,-1535,1372,1448,1418,1476,1356,1462,1387,-1551,1475,1340,1447,1402,1386,-1567,1068,1068,1474,1461,455,380,468,440,395,425,410,454,364,467,466,464,453,269,409,448,268,432,1371,1473,1432,1417,1308,1460,1355,1446,1459,1431,1083,1083,1401,1416,1458,1445,1067,1067,1370,1457,1051,1051,1291,1430,1385,1444,1354,1415,1400,1443,1082,1082,1173,1113,1186,1066,1185,1050,-1967,1158,1128,1172,1097,1171,1081,-1983,1157,1112,416,266,375,400,1170,1142,1127,1065,793,793,1169,1033,1156,1096,1141,1111,1155,1080,1126,1140,898,898,808,808,897,897,792,792,1095,1152,1032,1125,1110,1139,1079,1124,882,807,838,881,853,791,-2319,867,368,263,822,852,837,866,806,865,-2399,851,352,262,534,534,821,836,594,594,549,549,593,593,533,533,848,773,579,579,564,578,548,563,276,276,577,576,306,291,516,560,305,305,275,259,
    -251,-892,-2058,-2620,-2828,-2957,-3023,-3039,1041,1041,1040,1040,769,769,769,769,256,256,256,256,256,256,256,256,256,256,256,256,256,256,256,256,-511,-527,-543,-559,1530,-575,-591,1528,1527,1407,1526,1391,1023,1023,1023,1023,1525,1375,1268,1268,1103,1103,1087,1087,1039,1039,1523,-604,815,815,815,815,510,495,509,479,508,463,507,447,431,505,415,399,-734,-782,1262,-815,1259,1244,-831,1258,1228,-847,-863,1196,-879,1253,987,987,748,-767,493,493,462,477,414,414,686,669,478,446,461,445,474,429,487,458,412,471,1266,1264,1009,1009,799,799,-1019,-1276,-1452,-1581,-1677,-1757,-1821,-1886,-1933,-1997,1257,1257,1483,1468,1512,1422,1497,1406,1467,1496,1421,1510,1134,1134,1225,1225,1466,1451,1374,1405,1252,1252,1358,1480,1164,1164,1251,1251,1238,1238,1389,1465,-1407,1054,1101,-1423,1207,-1439,830,830,1248,1038,1237,1117,1223,1148,1236,1208,411,426,395,410,379,269,1193,1222,1132,1235,1221,1116,976,976,1192,1162,1177,1220,1131,1191,963,963,-1647,961,780,-1663,558,558,994,993,437,408,393,407,829,978,813,797,947,-1743,721,721,377,392,844,950,828,890,706,706,812,859,796,960,948,843,934,874,571,571,-1919,690,555,689,421,346,539,539,944,779,918,873,932,842,903,888,570,570,931,917,674,674,-2575,1562,-2591,1609,-2607,1654,1322,1322,1441,1441,1696,1546,1683,1593,1669,1624,1426,1426,1321,1321,1639,1680,1425,1425,1305,1305,1545,1668,1608,1623,1667,1592,1638,1666,1320,1320,1652,1607,1409,1409,1304,1304,1288,1288,1664,1637,1395,1395,1335,1335,1622,1636,1394,1394,1319,1319,1606,1621,1392,1392,1137,1137,1137,1137,345,390,360,375,404,373,1047,-2751,-2767,-2783,1062,1121,1046,-2799,1077,-2815,1106,1061,789,789,1105,1104,263,355,310,340,325,354,352,262,339,324,1091,1076,1029,1090,1060,1075,833,833,788,788,1088,1028,818,818,803,803,561,561,531,531,816,771,546,546,289,274,288,258,
    -253,-317,-381,-446,-478,-509,1279,1279,-811,-1179,-1451,-1756,-1900,-2028,-2189,-2253,-2333,-2414,-2445,-2511,-2526,1313,1298,-2559,1041,1041,1040,1040,1025,1025,1024,1024,1022,1007,1021,991,1020,975,1019,959,687,687,1018,1017,671,671,655,655,1016,1015,639,639,758,758,623,623,757,607,756,591,755,575,754,559,543,543,1009,783,-575,-621,-685,-749,496,-590,750,749,734,748,974,989,1003,958,988,973,1002,942,987,957,972,1001,926,986,941,971,956,1000,910,985,925,999,894,970,-1071,-1087,-1102,1390,-1135,1436,1509,1451,1374,-1151,1405,1358,1480,1420,-1167,1507,1494,1389,1342,1465,1435,1450,1326,1505,1310,1493,1373,1479,1404,1492,1464,1419,428,443,472,397,736,526,464,464,486,457,442,471,484,482,1357,1449,1434,1478,1388,1491,1341,1490,1325,1489,1463,1403,1309,1477,1372,1448,1418,1433,1476,1356,1462,1387,-1439,1475,1340,1447,1402,1474,1324,1461,1371,1473,269,448,1432,1417,1308,1460,-1711,1459,-1727,1441,1099,1099,1446,1386,1431,1401,-1743,1289,1083,1083,1160,1160,1458,1445,1067,1067,1370,1457,1307,1430,1129,1129,1098,1098,268,432,267,416,266,400,-1887,1144,1187,1082,1173,1113,1186,1066,1050,1158,1128,1143,1172,1097,1171,1081,420,391,1157,1112,1170,1142,1127,1065,1169,1049,1156,1096,1141,1111,1155,1080,1126,1154,1064,1153,1140,1095,1048,-2159,1125,1110,1137,-2175,823,823,1139,1138,807,807,384,264,368,263,868,838,853,791,867,822,852,837,866,806,865,790,-2319,851,821,836,352,262,850,805,849,-2399,533,533,835,820,336,261,578,548,563,577,532,532,832,772,562,562,547,547,305,275,560,515,290,290,288,258
};

const pow43_table = [_]f32{
    0,-1,-2.519842,-4.326749,-6.349604,-8.549880,-10.902724,-13.390518,-16.000000,-18.720754,-21.544347,-24.463781,-27.473142,-30.567351,-33.741992,-36.993181f,
    0,1,2.519842,4.326749,6.349604,8.549880,10.902724,13.390518,16.000000,18.720754,21.544347,24.463781,27.473142,30.567351,33.741992,36.993181,40.317474,43.711787,47.173345,50.699631,54.288352,57.937408,61.644865,65.408941,69.227979,73.100443,77.024898,81.000000,85.024491,89.097188,93.216975,97.382800,101.593667,105.848633,110.146801,114.487321,118.869381,123.292209,127.755065,132.257246,136.798076,141.376907,145.993119,150.646117,155.335327,160.060199,164.820202,169.614826,174.443577,179.305980,184.201575,189.129918,194.090580,199.083145,204.107210,209.162385,214.248292,219.364564,224.510845,229.686789,234.892058,240.126328,245.389280,250.680604,256.000000,261.347174,266.721841,272.123723,277.552547,283.008049,288.489971,293.998060,299.532071,305.091761,310.676898,316.287249,321.922592,327.582707,333.267377,338.976394,344.709550,350.466646,356.247482,362.051866,367.879608,373.730522,379.604427,385.501143,391.420496,397.362314,403.326427,409.312672,415.320884,421.350905,427.402579,433.475750,439.570269,445.685987,451.822757,457.980436,464.158883,470.357960,476.577530,482.817459,489.077615,495.357868,501.658090,507.978156,514.317941,520.677324,527.056184,533.454404,539.871867,546.308458,552.764065,559.238575,565.731879,572.243870,578.774440,585.323483,591.890898,598.476581,605.080431,611.702349,618.342238,625.000000,631.675540,638.368763,645.079578
};

fn pow43(x: i32) f32 {
    if (x < 129) {
        return pow43_table[16 + x];
    }
    // This is a simplified version for now.
    // The full version has more logic for larger values.
    return 0;
}

/// Decodes the main data of a granule using Huffman coding.
pub fn huffmanDecode(bs: *BitStream, h: FrameHeader, gr: GranuleInfo, scf: []const f32, dst: []f32) !void {
    const sfb = getScaleFactorBands(h, gr);
    var big_val_pairs = gr.big_values / 2;
    var region_idx: usize = 0;
    var sfb_idx: usize = 0;
    var dst_idx: usize = 0;

    // --- Big Values Region ---
    while (big_val_pairs > 0 and region_idx < 3) {
        const table_num = gr.table_select[region_idx];
        if (table_num == 0) {
            region_idx += 1;
            continue;
        }

        var region_sfb_count: u8 = 0;
        if (gr.window_switching_flag and gr.block_type == 2) {
            // short blocks have different region logic
            // This is complex and depends on mixed_block_flag
            // For now, we assume long blocks
        } else {
            if (region_idx == 0) region_sfb_count = gr.region0_count + 1;
            if (region_idx == 1) region_sfb_count = gr.region1_count + 1;
        }

        const codebook_offset = huffman_tab_index[table_num];
        const codebook = huffman_tables[codebook_offset..];
        const linbits = huffman_linbits[table_num];

        while (big_val_pairs > 0 and region_sfb_count > 0) {
            const pairs_in_sfb = sfb.bands[sfb_idx] / 2;
            const pairs_to_decode = @min(big_val_pairs, pairs_in_sfb);
            const scale_factor = scf[sfb_idx];

            var i: usize = 0;
            while (i < pairs_to_decode) : (i += 1) {
                var leaf = codebook[bs.peekBits(5)];
                while (leaf < 0) {
                    _ = bs.getBits(leaf & 7);
                    leaf = codebook[bs.peekBits(leaf & 7) - (leaf >> 3)];
                }
                _ = bs.getBits(@as(u8, @truncate(leaf >> 8)));

                var j: u1 = 0;
                while (j < 2) : (j += 1) {
                    var val = @as(u4, @truncate(leaf));
                    if (val == 15 and linbits > 0) {
                        val += @as(u4, @truncate(bs.getBits(linbits)));
                    }
                    if (val > 0) {
                        if (bs.getBits(1) == 1) { // sign bit
                            dst[dst_idx] = -pow43(@as(i32, val)) * scale_factor;
                        } else {
                            dst[dst_idx] = pow43(@as(i32, val)) * scale_factor;
                        }
                    } else {
                        dst[dst_idx] = 0;
                    }
                    dst_idx += 1;
                    leaf >>= 4;
                }
            }

            big_val_pairs -= pairs_to_decode;
            sfb_idx += 1;
            region_sfb_count -= 1;
        }
        region_idx += 1;
    }

    // --- Count1 Region ---
    const count1_table = if (gr.count1table_select == 1) huffman_tab33 else huffman_tab32;
    while (bs.pos < layer3gr_limit and dst_idx + 3 < dst.len) {
        var leaf = count1_table[bs.peekBits(4)];
        if ((leaf & 8) == 0) {
            const offset = @as(u4, @truncate(leaf >> 3));
            const len = leaf & 3;
            _ = bs.getBits(len);
            leaf = count1_table[offset + bs.peekBits(len)];
        }
        _ = bs.getBits(leaf & 7);

        if (bs.pos > layer3gr_limit) break;

        if ((leaf & 128) != 0) {
            dst[dst_idx] = if (bs.getBits(1) == 1) -scf[sfb_idx] else scf[sfb_idx];
        }
        dst_idx += 1;
        if ((leaf & 64) != 0) {
            dst[dst_idx] = if (bs.getBits(1) == 1) -scf[sfb_idx] else scf[sfb_idx];
        }
        dst_idx += 1;
        if ((leaf & 32) != 0) {
            dst[dst_idx] = if (bs.getBits(1) == 1) -scf[sfb_idx] else scf[sfb_idx];
        }
        dst_idx += 1;
        if ((leaf & 16) != 0) {
            dst[dst_idx] = if (bs.getBits(1) == 1) -scf[sfb_idx] else scf[sfb_idx];
        }
        dst_idx += 1;
    }

    bs.pos = layer3gr_limit;
}

/// Decodes the scalefactors for a granule from the bitstream.
pub fn decodeScaleFactors(bs: *BitStream, h: FrameHeader, gr: GranuleInfo, ch: u1, scf: []f32, ist_pos: []u8) !void {
    const scf_shift = if (gr.scalefac_scale == 0) 0 else 1;
    var scf_size: [4]u8 = undefined;
    var scf_partition_counts: [4]u8 = undefined;

    if (h.version == .mpeg1) {
        const part = huffman_scalefac_compress_decode_mpeg1[gr.scalefac_compress];
        scf_size[0] = @as(u8, @truncate(part >> 2));
        scf_size[1] = @as(u8, @truncate(part >> 2));
        scf_size[2] = @as(u8, @truncate(part & 3));
        scf_size[3] = @as(u8, @truncate(part & 3));
        scf_partition_counts = huffman_scf_partitions_long[0];
    } else { // MPEG2, 2.5
        // ... porting MPEG2 logic is complex and requires more tables ...
        // For now, we focus on the MPEG1 path.
        return error.UnsupportedMpegVersion;
    }

    // Read raw scalefactors from bitstream
    var scf_raw: [40]u8 = undefined;
    var scf_cursor: usize = 0;
    var i: u2 = 0;
    while (i < 4) : (i += 1) {
        const count = scf_partition_counts[i];
        const bits = scf_size[i];
        if (bits > 0) {
            var j: u8 = 0;
            while (j < count) : (j += 1) {
                scf_raw[scf_cursor] = @as(u8, @truncate(bs.getBits(bits)));
                scf_cursor += 1;
            }
        }
    }

    // Apply preflag logic for MPEG1
    if (gr.preflag) {
        const preamp_table = [_]u8{ 1,1,1,1,2,2,3,3,3,2 };
        var j: u4 = 0;
        while (j < 10) : (j += 1) {
            scf_raw[11 + j] += preamp_table[j];
        }
    }

    // Dequantize scalefactors
    const gain_exp = gr.global_gain - 210 - (if (h.is_mono) 0 else 2);
    const gain = std.math.pow(f32, 2.0, @as(f32, @floatFromInt(gain_exp)) / 4.0);

    var band_idx: usize = 0;
    while (band_idx < scf.len) : (band_idx += 1) {
        const shifted_scf = @as(i32, scf_raw[band_idx]) << scf_shift;
        scf[band_idx] = std.math.pow(f32, 2.0, -@as(f32, @floatFromInt(shifted_scf))) * gain;
    }

    _ = ist_pos; // TODO: Intensity stereo position decoding
}

const huffman_scalefac_compress_decode_mpeg1 = [_]u8{0,1,2,3,12,5,6,7,9,10,11,13,14,15,18,19};
const huffman_scf_partitions_long = [_][4]u8{
    {6,5,5,5},
    {6,5,7,3},
    {11,10,0,0},
    // ... and more ...
};
