pub const __builtin_bswap16 = @import("std").zig.c_builtins.__builtin_bswap16;
pub const __builtin_bswap32 = @import("std").zig.c_builtins.__builtin_bswap32;
pub const __builtin_bswap64 = @import("std").zig.c_builtins.__builtin_bswap64;
pub const __builtin_signbit = @import("std").zig.c_builtins.__builtin_signbit;
pub const __builtin_signbitf = @import("std").zig.c_builtins.__builtin_signbitf;
pub const __builtin_popcount = @import("std").zig.c_builtins.__builtin_popcount;
pub const __builtin_ctz = @import("std").zig.c_builtins.__builtin_ctz;
pub const __builtin_clz = @import("std").zig.c_builtins.__builtin_clz;
pub const __builtin_sqrt = @import("std").zig.c_builtins.__builtin_sqrt;
pub const __builtin_sqrtf = @import("std").zig.c_builtins.__builtin_sqrtf;
pub const __builtin_sin = @import("std").zig.c_builtins.__builtin_sin;
pub const __builtin_sinf = @import("std").zig.c_builtins.__builtin_sinf;
pub const __builtin_cos = @import("std").zig.c_builtins.__builtin_cos;
pub const __builtin_cosf = @import("std").zig.c_builtins.__builtin_cosf;
pub const __builtin_exp = @import("std").zig.c_builtins.__builtin_exp;
pub const __builtin_expf = @import("std").zig.c_builtins.__builtin_expf;
pub const __builtin_exp2 = @import("std").zig.c_builtins.__builtin_exp2;
pub const __builtin_exp2f = @import("std").zig.c_builtins.__builtin_exp2f;
pub const __builtin_log = @import("std").zig.c_builtins.__builtin_log;
pub const __builtin_logf = @import("std").zig.c_builtins.__builtin_logf;
pub const __builtin_log2 = @import("std").zig.c_builtins.__builtin_log2;
pub const __builtin_log2f = @import("std").zig.c_builtins.__builtin_log2f;
pub const __builtin_log10 = @import("std").zig.c_builtins.__builtin_log10;
pub const __builtin_log10f = @import("std").zig.c_builtins.__builtin_log10f;
pub const __builtin_abs = @import("std").zig.c_builtins.__builtin_abs;
pub const __builtin_labs = @import("std").zig.c_builtins.__builtin_labs;
pub const __builtin_llabs = @import("std").zig.c_builtins.__builtin_llabs;
pub const __builtin_fabs = @import("std").zig.c_builtins.__builtin_fabs;
pub const __builtin_fabsf = @import("std").zig.c_builtins.__builtin_fabsf;
pub const __builtin_floor = @import("std").zig.c_builtins.__builtin_floor;
pub const __builtin_floorf = @import("std").zig.c_builtins.__builtin_floorf;
pub const __builtin_ceil = @import("std").zig.c_builtins.__builtin_ceil;
pub const __builtin_ceilf = @import("std").zig.c_builtins.__builtin_ceilf;
pub const __builtin_trunc = @import("std").zig.c_builtins.__builtin_trunc;
pub const __builtin_truncf = @import("std").zig.c_builtins.__builtin_truncf;
pub const __builtin_round = @import("std").zig.c_builtins.__builtin_round;
pub const __builtin_roundf = @import("std").zig.c_builtins.__builtin_roundf;
pub const __builtin_strlen = @import("std").zig.c_builtins.__builtin_strlen;
pub const __builtin_strcmp = @import("std").zig.c_builtins.__builtin_strcmp;
pub const __builtin_object_size = @import("std").zig.c_builtins.__builtin_object_size;
pub const __builtin___memset_chk = @import("std").zig.c_builtins.__builtin___memset_chk;
pub const __builtin_memset = @import("std").zig.c_builtins.__builtin_memset;
pub const __builtin___memcpy_chk = @import("std").zig.c_builtins.__builtin___memcpy_chk;
pub const __builtin_memcpy = @import("std").zig.c_builtins.__builtin_memcpy;
pub const __builtin_expect = @import("std").zig.c_builtins.__builtin_expect;
pub const __builtin_nanf = @import("std").zig.c_builtins.__builtin_nanf;
pub const __builtin_huge_valf = @import("std").zig.c_builtins.__builtin_huge_valf;
pub const __builtin_inff = @import("std").zig.c_builtins.__builtin_inff;
pub const __builtin_isnan = @import("std").zig.c_builtins.__builtin_isnan;
pub const __builtin_isinf = @import("std").zig.c_builtins.__builtin_isinf;
pub const __builtin_isinf_sign = @import("std").zig.c_builtins.__builtin_isinf_sign;
pub const __has_builtin = @import("std").zig.c_builtins.__has_builtin;
pub const __builtin_assume = @import("std").zig.c_builtins.__builtin_assume;
pub const __builtin_unreachable = @import("std").zig.c_builtins.__builtin_unreachable;
pub const __builtin_constant_p = @import("std").zig.c_builtins.__builtin_constant_p;
pub const __builtin_mul_overflow = @import("std").zig.c_builtins.__builtin_mul_overflow;
pub const ptrdiff_t = c_longlong;
pub const wchar_t = c_ushort;
pub const max_align_t = extern struct {
    __clang_max_align_nonce1: c_longlong align(8) = @import("std").mem.zeroes(c_longlong),
    __clang_max_align_nonce2: c_longdouble align(16) = @import("std").mem.zeroes(c_longdouble),
};
pub const drmp3_int8 = i8;
pub const drmp3_uint8 = u8;
pub const drmp3_int16 = c_short;
pub const drmp3_uint16 = c_ushort;
pub const drmp3_int32 = c_int;
pub const drmp3_uint32 = c_uint;
pub const drmp3_int64 = c_longlong;
pub const drmp3_uint64 = c_ulonglong;
pub const drmp3_uintptr = drmp3_uint64;
pub const drmp3_bool8 = drmp3_uint8;
pub const drmp3_bool32 = drmp3_uint32;
pub const drmp3_result = drmp3_int32;
pub extern fn drmp3_version(pMajor: [*c]drmp3_uint32, pMinor: [*c]drmp3_uint32, pRevision: [*c]drmp3_uint32) void;
pub extern fn drmp3_version_string() [*c]const u8;
pub const drmp3_allocation_callbacks = extern struct {
    pUserData: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    onMalloc: ?*const fn (usize, ?*anyopaque) callconv(.c) ?*anyopaque = @import("std").mem.zeroes(?*const fn (usize, ?*anyopaque) callconv(.c) ?*anyopaque),
    onRealloc: ?*const fn (?*anyopaque, usize, ?*anyopaque) callconv(.c) ?*anyopaque = @import("std").mem.zeroes(?*const fn (?*anyopaque, usize, ?*anyopaque) callconv(.c) ?*anyopaque),
    onFree: ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void = @import("std").mem.zeroes(?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void),
};
pub const drmp3dec_frame_info = extern struct {
    frame_bytes: c_int = @import("std").mem.zeroes(c_int),
    channels: c_int = @import("std").mem.zeroes(c_int),
    sample_rate: c_int = @import("std").mem.zeroes(c_int),
    layer: c_int = @import("std").mem.zeroes(c_int),
    bitrate_kbps: c_int = @import("std").mem.zeroes(c_int),
};
pub const drmp3_bs = extern struct {
    buf: [*c]const drmp3_uint8 = @import("std").mem.zeroes([*c]const drmp3_uint8),
    pos: c_int = @import("std").mem.zeroes(c_int),
    limit: c_int = @import("std").mem.zeroes(c_int),
};
pub const drmp3_L3_gr_info = extern struct {
    sfbtab: [*c]const drmp3_uint8 = @import("std").mem.zeroes([*c]const drmp3_uint8),
    part_23_length: drmp3_uint16 = @import("std").mem.zeroes(drmp3_uint16),
    big_values: drmp3_uint16 = @import("std").mem.zeroes(drmp3_uint16),
    scalefac_compress: drmp3_uint16 = @import("std").mem.zeroes(drmp3_uint16),
    global_gain: drmp3_uint8 = @import("std").mem.zeroes(drmp3_uint8),
    block_type: drmp3_uint8 = @import("std").mem.zeroes(drmp3_uint8),
    mixed_block_flag: drmp3_uint8 = @import("std").mem.zeroes(drmp3_uint8),
    n_long_sfb: drmp3_uint8 = @import("std").mem.zeroes(drmp3_uint8),
    n_short_sfb: drmp3_uint8 = @import("std").mem.zeroes(drmp3_uint8),
    table_select: [3]drmp3_uint8 = @import("std").mem.zeroes([3]drmp3_uint8),
    region_count: [3]drmp3_uint8 = @import("std").mem.zeroes([3]drmp3_uint8),
    subblock_gain: [3]drmp3_uint8 = @import("std").mem.zeroes([3]drmp3_uint8),
    preflag: drmp3_uint8 = @import("std").mem.zeroes(drmp3_uint8),
    scalefac_scale: drmp3_uint8 = @import("std").mem.zeroes(drmp3_uint8),
    count1_table: drmp3_uint8 = @import("std").mem.zeroes(drmp3_uint8),
    scfsi: drmp3_uint8 = @import("std").mem.zeroes(drmp3_uint8),
};
pub const drmp3dec_scratch = extern struct {
    bs: drmp3_bs = @import("std").mem.zeroes(drmp3_bs),
    maindata: [2815]drmp3_uint8 = @import("std").mem.zeroes([2815]drmp3_uint8),
    gr_info: [4]drmp3_L3_gr_info = @import("std").mem.zeroes([4]drmp3_L3_gr_info),
    grbuf: [2][576]f32 = @import("std").mem.zeroes([2][576]f32),
    scf: [40]f32 = @import("std").mem.zeroes([40]f32),
    syn: [33][64]f32 = @import("std").mem.zeroes([33][64]f32),
    ist_pos: [2][39]drmp3_uint8 = @import("std").mem.zeroes([2][39]drmp3_uint8),
};
pub const drmp3dec = extern struct {
    mdct_overlap: [2][288]f32 = @import("std").mem.zeroes([2][288]f32),
    qmf_state: [960]f32 = @import("std").mem.zeroes([960]f32),
    reserv: c_int = @import("std").mem.zeroes(c_int),
    free_format_bytes: c_int = @import("std").mem.zeroes(c_int),
    header: [4]drmp3_uint8 = @import("std").mem.zeroes([4]drmp3_uint8),
    reserv_buf: [511]drmp3_uint8 = @import("std").mem.zeroes([511]drmp3_uint8),
    scratch: drmp3dec_scratch = @import("std").mem.zeroes(drmp3dec_scratch),
};
pub extern fn drmp3dec_init(dec: [*c]drmp3dec) void;
pub extern fn drmp3dec_decode_frame(dec: [*c]drmp3dec, mp3: [*c]const drmp3_uint8, mp3_bytes: c_int, pcm: ?*anyopaque, info: [*c]drmp3dec_frame_info) c_int;
pub extern fn drmp3dec_f32_to_s16(in: [*c]const f32, out: [*c]drmp3_int16, num_samples: usize) void;
pub const DRMP3_SEEK_SET: c_int = 0;
pub const DRMP3_SEEK_CUR: c_int = 1;
pub const DRMP3_SEEK_END: c_int = 2;
pub const drmp3_seek_origin = c_uint;
pub const drmp3_seek_point = extern struct {
    seekPosInBytes: drmp3_uint64 = @import("std").mem.zeroes(drmp3_uint64),
    pcmFrameIndex: drmp3_uint64 = @import("std").mem.zeroes(drmp3_uint64),
    mp3FramesToDiscard: drmp3_uint16 = @import("std").mem.zeroes(drmp3_uint16),
    pcmFramesToDiscard: drmp3_uint16 = @import("std").mem.zeroes(drmp3_uint16),
};
pub const DRMP3_METADATA_TYPE_ID3V1: c_int = 0;
pub const DRMP3_METADATA_TYPE_ID3V2: c_int = 1;
pub const DRMP3_METADATA_TYPE_APE: c_int = 2;
pub const DRMP3_METADATA_TYPE_XING: c_int = 3;
pub const DRMP3_METADATA_TYPE_VBRI: c_int = 4;
pub const drmp3_metadata_type = c_uint;
pub const drmp3_metadata = extern struct {
    type: drmp3_metadata_type = @import("std").mem.zeroes(drmp3_metadata_type),
    pRawData: ?*const anyopaque = @import("std").mem.zeroes(?*const anyopaque),
    rawDataSize: usize = @import("std").mem.zeroes(usize),
};
pub const drmp3_read_proc = ?*const fn (?*anyopaque, ?*anyopaque, usize) callconv(.c) usize;
pub const drmp3_seek_proc = ?*const fn (?*anyopaque, c_int, drmp3_seek_origin) callconv(.c) drmp3_bool32;
pub const drmp3_tell_proc = ?*const fn (?*anyopaque, [*c]drmp3_int64) callconv(.c) drmp3_bool32;
pub const drmp3_meta_proc = ?*const fn (?*anyopaque, [*c]const drmp3_metadata) callconv(.c) void;
pub const drmp3_config = extern struct {
    channels: drmp3_uint32 = @import("std").mem.zeroes(drmp3_uint32),
    sampleRate: drmp3_uint32 = @import("std").mem.zeroes(drmp3_uint32),
};
const struct_unnamed_1 = extern struct {
    pData: [*c]const drmp3_uint8 = @import("std").mem.zeroes([*c]const drmp3_uint8),
    dataSize: usize = @import("std").mem.zeroes(usize),
    currentReadPos: usize = @import("std").mem.zeroes(usize),
};
pub const drmp3 = extern struct {
    decoder: drmp3dec = @import("std").mem.zeroes(drmp3dec),
    channels: drmp3_uint32 = @import("std").mem.zeroes(drmp3_uint32),
    sampleRate: drmp3_uint32 = @import("std").mem.zeroes(drmp3_uint32),
    onRead: drmp3_read_proc = @import("std").mem.zeroes(drmp3_read_proc),
    onSeek: drmp3_seek_proc = @import("std").mem.zeroes(drmp3_seek_proc),
    onMeta: drmp3_meta_proc = @import("std").mem.zeroes(drmp3_meta_proc),
    pUserData: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    pUserDataMeta: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    allocationCallbacks: drmp3_allocation_callbacks = @import("std").mem.zeroes(drmp3_allocation_callbacks),
    mp3FrameChannels: drmp3_uint32 = @import("std").mem.zeroes(drmp3_uint32),
    mp3FrameSampleRate: drmp3_uint32 = @import("std").mem.zeroes(drmp3_uint32),
    pcmFramesConsumedInMP3Frame: drmp3_uint32 = @import("std").mem.zeroes(drmp3_uint32),
    pcmFramesRemainingInMP3Frame: drmp3_uint32 = @import("std").mem.zeroes(drmp3_uint32),
    pcmFrames: [9216]drmp3_uint8 = @import("std").mem.zeroes([9216]drmp3_uint8),
    currentPCMFrame: drmp3_uint64 = @import("std").mem.zeroes(drmp3_uint64),
    streamCursor: drmp3_uint64 = @import("std").mem.zeroes(drmp3_uint64),
    streamLength: drmp3_uint64 = @import("std").mem.zeroes(drmp3_uint64),
    streamStartOffset: drmp3_uint64 = @import("std").mem.zeroes(drmp3_uint64),
    pSeekPoints: [*c]drmp3_seek_point = @import("std").mem.zeroes([*c]drmp3_seek_point),
    seekPointCount: drmp3_uint32 = @import("std").mem.zeroes(drmp3_uint32),
    delayInPCMFrames: drmp3_uint32 = @import("std").mem.zeroes(drmp3_uint32),
    paddingInPCMFrames: drmp3_uint32 = @import("std").mem.zeroes(drmp3_uint32),
    totalPCMFrameCount: drmp3_uint64 = @import("std").mem.zeroes(drmp3_uint64),
    isVBR: drmp3_bool32 = @import("std").mem.zeroes(drmp3_bool32),
    isCBR: drmp3_bool32 = @import("std").mem.zeroes(drmp3_bool32),
    dataSize: usize = @import("std").mem.zeroes(usize),
    dataCapacity: usize = @import("std").mem.zeroes(usize),
    dataConsumed: usize = @import("std").mem.zeroes(usize),
    pData: [*c]drmp3_uint8 = @import("std").mem.zeroes([*c]drmp3_uint8),
    atEnd: drmp3_bool32 = @import("std").mem.zeroes(drmp3_bool32),
    memory: struct_unnamed_1 = @import("std").mem.zeroes(struct_unnamed_1),
};
pub extern fn drmp3_init(pMP3: [*c]drmp3, onRead: drmp3_read_proc, onSeek: drmp3_seek_proc, onTell: drmp3_tell_proc, onMeta: drmp3_meta_proc, pUserData: ?*anyopaque, pAllocationCallbacks: [*c]const drmp3_allocation_callbacks) drmp3_bool32;
pub extern fn drmp3_init_memory_with_metadata(pMP3: [*c]drmp3, pData: ?*const anyopaque, dataSize: usize, onMeta: drmp3_meta_proc, pUserDataMeta: ?*anyopaque, pAllocationCallbacks: [*c]const drmp3_allocation_callbacks) drmp3_bool32;
pub extern fn drmp3_init_memory(pMP3: [*c]drmp3, pData: ?*const anyopaque, dataSize: usize, pAllocationCallbacks: [*c]const drmp3_allocation_callbacks) drmp3_bool32;
pub extern fn drmp3_init_file_with_metadata(pMP3: [*c]drmp3, pFilePath: [*c]const u8, onMeta: drmp3_meta_proc, pUserDataMeta: ?*anyopaque, pAllocationCallbacks: [*c]const drmp3_allocation_callbacks) drmp3_bool32;
pub extern fn drmp3_init_file_with_metadata_w(pMP3: [*c]drmp3, pFilePath: [*c]const wchar_t, onMeta: drmp3_meta_proc, pUserDataMeta: ?*anyopaque, pAllocationCallbacks: [*c]const drmp3_allocation_callbacks) drmp3_bool32;
pub extern fn drmp3_init_file(pMP3: [*c]drmp3, pFilePath: [*c]const u8, pAllocationCallbacks: [*c]const drmp3_allocation_callbacks) drmp3_bool32;
pub extern fn drmp3_init_file_w(pMP3: [*c]drmp3, pFilePath: [*c]const wchar_t, pAllocationCallbacks: [*c]const drmp3_allocation_callbacks) drmp3_bool32;
pub extern fn drmp3_uninit(pMP3: [*c]drmp3) void;
pub extern fn drmp3_read_pcm_frames_f32(pMP3: [*c]drmp3, framesToRead: drmp3_uint64, pBufferOut: [*c]f32) drmp3_uint64;
pub extern fn drmp3_read_pcm_frames_s16(pMP3: [*c]drmp3, framesToRead: drmp3_uint64, pBufferOut: [*c]drmp3_int16) drmp3_uint64;
pub extern fn drmp3_seek_to_pcm_frame(pMP3: [*c]drmp3, frameIndex: drmp3_uint64) drmp3_bool32;
pub extern fn drmp3_get_pcm_frame_count(pMP3: [*c]drmp3) drmp3_uint64;
pub extern fn drmp3_get_mp3_frame_count(pMP3: [*c]drmp3) drmp3_uint64;
pub extern fn drmp3_get_mp3_and_pcm_frame_count(pMP3: [*c]drmp3, pMP3FrameCount: [*c]drmp3_uint64, pPCMFrameCount: [*c]drmp3_uint64) drmp3_bool32;
pub extern fn drmp3_calculate_seek_points(pMP3: [*c]drmp3, pSeekPointCount: [*c]drmp3_uint32, pSeekPoints: [*c]drmp3_seek_point) drmp3_bool32;
pub extern fn drmp3_bind_seek_table(pMP3: [*c]drmp3, seekPointCount: drmp3_uint32, pSeekPoints: [*c]drmp3_seek_point) drmp3_bool32;
pub extern fn drmp3_open_and_read_pcm_frames_f32(onRead: drmp3_read_proc, onSeek: drmp3_seek_proc, onTell: drmp3_tell_proc, pUserData: ?*anyopaque, pConfig: [*c]drmp3_config, pTotalFrameCount: [*c]drmp3_uint64, pAllocationCallbacks: [*c]const drmp3_allocation_callbacks) [*c]f32;
pub extern fn drmp3_open_and_read_pcm_frames_s16(onRead: drmp3_read_proc, onSeek: drmp3_seek_proc, onTell: drmp3_tell_proc, pUserData: ?*anyopaque, pConfig: [*c]drmp3_config, pTotalFrameCount: [*c]drmp3_uint64, pAllocationCallbacks: [*c]const drmp3_allocation_callbacks) [*c]drmp3_int16;
pub extern fn drmp3_open_memory_and_read_pcm_frames_f32(pData: ?*const anyopaque, dataSize: usize, pConfig: [*c]drmp3_config, pTotalFrameCount: [*c]drmp3_uint64, pAllocationCallbacks: [*c]const drmp3_allocation_callbacks) [*c]f32;
pub extern fn drmp3_open_memory_and_read_pcm_frames_s16(pData: ?*const anyopaque, dataSize: usize, pConfig: [*c]drmp3_config, pTotalFrameCount: [*c]drmp3_uint64, pAllocationCallbacks: [*c]const drmp3_allocation_callbacks) [*c]drmp3_int16;
pub extern fn drmp3_open_file_and_read_pcm_frames_f32(filePath: [*c]const u8, pConfig: [*c]drmp3_config, pTotalFrameCount: [*c]drmp3_uint64, pAllocationCallbacks: [*c]const drmp3_allocation_callbacks) [*c]f32;
pub extern fn drmp3_open_file_and_read_pcm_frames_s16(filePath: [*c]const u8, pConfig: [*c]drmp3_config, pTotalFrameCount: [*c]drmp3_uint64, pAllocationCallbacks: [*c]const drmp3_allocation_callbacks) [*c]drmp3_int16;
pub extern fn drmp3_malloc(sz: usize, pAllocationCallbacks: [*c]const drmp3_allocation_callbacks) ?*anyopaque;
pub extern fn drmp3_free(p: ?*anyopaque, pAllocationCallbacks: [*c]const drmp3_allocation_callbacks) void;
pub const __llvm__ = @as(c_int, 1);
pub const __clang__ = @as(c_int, 1);
pub const __clang_major__ = @as(c_int, 20);
pub const __clang_minor__ = @as(c_int, 1);
pub const __clang_patchlevel__ = @as(c_int, 2);
pub const __clang_version__ = "20.1.2 (https://github.com/ziglang/zig-bootstrap 7ef74e656cf8ddbd6bf891a8475892aa1afa6891)";
pub const __GNUC__ = @as(c_int, 4);
pub const __GNUC_MINOR__ = @as(c_int, 2);
pub const __GNUC_PATCHLEVEL__ = @as(c_int, 1);
pub const __GXX_ABI_VERSION = @as(c_int, 1002);
pub const __ATOMIC_RELAXED = @as(c_int, 0);
pub const __ATOMIC_CONSUME = @as(c_int, 1);
pub const __ATOMIC_ACQUIRE = @as(c_int, 2);
pub const __ATOMIC_RELEASE = @as(c_int, 3);
pub const __ATOMIC_ACQ_REL = @as(c_int, 4);
pub const __ATOMIC_SEQ_CST = @as(c_int, 5);
pub const __MEMORY_SCOPE_SYSTEM = @as(c_int, 0);
pub const __MEMORY_SCOPE_DEVICE = @as(c_int, 1);
pub const __MEMORY_SCOPE_WRKGRP = @as(c_int, 2);
pub const __MEMORY_SCOPE_WVFRNT = @as(c_int, 3);
pub const __MEMORY_SCOPE_SINGLE = @as(c_int, 4);
pub const __OPENCL_MEMORY_SCOPE_WORK_ITEM = @as(c_int, 0);
pub const __OPENCL_MEMORY_SCOPE_WORK_GROUP = @as(c_int, 1);
pub const __OPENCL_MEMORY_SCOPE_DEVICE = @as(c_int, 2);
pub const __OPENCL_MEMORY_SCOPE_ALL_SVM_DEVICES = @as(c_int, 3);
pub const __OPENCL_MEMORY_SCOPE_SUB_GROUP = @as(c_int, 4);
pub const __FPCLASS_SNAN = @as(c_int, 0x0001);
pub const __FPCLASS_QNAN = @as(c_int, 0x0002);
pub const __FPCLASS_NEGINF = @as(c_int, 0x0004);
pub const __FPCLASS_NEGNORMAL = @as(c_int, 0x0008);
pub const __FPCLASS_NEGSUBNORMAL = @as(c_int, 0x0010);
pub const __FPCLASS_NEGZERO = @as(c_int, 0x0020);
pub const __FPCLASS_POSZERO = @as(c_int, 0x0040);
pub const __FPCLASS_POSSUBNORMAL = @as(c_int, 0x0080);
pub const __FPCLASS_POSNORMAL = @as(c_int, 0x0100);
pub const __FPCLASS_POSINF = @as(c_int, 0x0200);
pub const __PRAGMA_REDEFINE_EXTNAME = @as(c_int, 1);
pub const __VERSION__ = "Clang 20.1.2 (https://github.com/ziglang/zig-bootstrap 7ef74e656cf8ddbd6bf891a8475892aa1afa6891)";
pub const __GXX_TYPEINFO_EQUALITY_INLINE = @as(c_int, 0);
pub const __OBJC_BOOL_IS_BOOL = @as(c_int, 0);
pub const __CONSTANT_CFSTRINGS__ = @as(c_int, 1);
pub const __SEH__ = @as(c_int, 1);
pub const __clang_literal_encoding__ = "UTF-8";
pub const __clang_wide_literal_encoding__ = "UTF-16";
pub const __ORDER_LITTLE_ENDIAN__ = @as(c_int, 1234);
pub const __ORDER_BIG_ENDIAN__ = @as(c_int, 4321);
pub const __ORDER_PDP_ENDIAN__ = @as(c_int, 3412);
pub const __BYTE_ORDER__ = __ORDER_LITTLE_ENDIAN__;
pub const __LITTLE_ENDIAN__ = @as(c_int, 1);
pub const __CHAR_BIT__ = @as(c_int, 8);
pub const __BOOL_WIDTH__ = @as(c_int, 1);
pub const __SHRT_WIDTH__ = @as(c_int, 16);
pub const __INT_WIDTH__ = @as(c_int, 32);
pub const __LONG_WIDTH__ = @as(c_int, 32);
pub const __LLONG_WIDTH__ = @as(c_int, 64);
pub const __BITINT_MAXWIDTH__ = @import("std").zig.c_translation.promoteIntLiteral(c_int, 8388608, .decimal);
pub const __SCHAR_MAX__ = @as(c_int, 127);
pub const __SHRT_MAX__ = @as(c_int, 32767);
pub const __INT_MAX__ = @import("std").zig.c_translation.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __LONG_MAX__ = @as(c_long, 2147483647);
pub const __LONG_LONG_MAX__ = @as(c_longlong, 9223372036854775807);
pub const __WCHAR_MAX__ = @import("std").zig.c_translation.promoteIntLiteral(c_int, 65535, .decimal);
pub const __WCHAR_WIDTH__ = @as(c_int, 16);
pub const __WINT_MAX__ = @import("std").zig.c_translation.promoteIntLiteral(c_int, 65535, .decimal);
pub const __WINT_WIDTH__ = @as(c_int, 16);
pub const __INTMAX_MAX__ = @as(c_longlong, 9223372036854775807);
pub const __INTMAX_WIDTH__ = @as(c_int, 64);
pub const __SIZE_MAX__ = @as(c_ulonglong, 18446744073709551615);
pub const __SIZE_WIDTH__ = @as(c_int, 64);
pub const __UINTMAX_MAX__ = @as(c_ulonglong, 18446744073709551615);
pub const __UINTMAX_WIDTH__ = @as(c_int, 64);
pub const __PTRDIFF_MAX__ = @as(c_longlong, 9223372036854775807);
pub const __PTRDIFF_WIDTH__ = @as(c_int, 64);
pub const __INTPTR_MAX__ = @as(c_longlong, 9223372036854775807);
pub const __INTPTR_WIDTH__ = @as(c_int, 64);
pub const __UINTPTR_MAX__ = @as(c_ulonglong, 18446744073709551615);
pub const __UINTPTR_WIDTH__ = @as(c_int, 64);
pub const __SIZEOF_DOUBLE__ = @as(c_int, 8);
pub const __SIZEOF_FLOAT__ = @as(c_int, 4);
pub const __SIZEOF_INT__ = @as(c_int, 4);
pub const __SIZEOF_LONG__ = @as(c_int, 4);
pub const __SIZEOF_LONG_DOUBLE__ = @as(c_int, 16);
pub const __SIZEOF_LONG_LONG__ = @as(c_int, 8);
pub const __SIZEOF_POINTER__ = @as(c_int, 8);
pub const __SIZEOF_SHORT__ = @as(c_int, 2);
pub const __SIZEOF_PTRDIFF_T__ = @as(c_int, 8);
pub const __SIZEOF_SIZE_T__ = @as(c_int, 8);
pub const __SIZEOF_WCHAR_T__ = @as(c_int, 2);
pub const __SIZEOF_WINT_T__ = @as(c_int, 2);
pub const __SIZEOF_INT128__ = @as(c_int, 16);
pub const __INTMAX_TYPE__ = c_longlong;
pub const __INTMAX_FMTd__ = "lld";
pub const __INTMAX_FMTi__ = "lli";
pub const __INTMAX_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `LL`");
// (no file):95:9
pub const __INTMAX_C = @import("std").zig.c_translation.Macros.LL_SUFFIX;
pub const __UINTMAX_TYPE__ = c_ulonglong;
pub const __UINTMAX_FMTo__ = "llo";
pub const __UINTMAX_FMTu__ = "llu";
pub const __UINTMAX_FMTx__ = "llx";
pub const __UINTMAX_FMTX__ = "llX";
pub const __UINTMAX_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `ULL`");
// (no file):102:9
pub const __UINTMAX_C = @import("std").zig.c_translation.Macros.ULL_SUFFIX;
pub const __PTRDIFF_TYPE__ = c_longlong;
pub const __PTRDIFF_FMTd__ = "lld";
pub const __PTRDIFF_FMTi__ = "lli";
pub const __INTPTR_TYPE__ = c_longlong;
pub const __INTPTR_FMTd__ = "lld";
pub const __INTPTR_FMTi__ = "lli";
pub const __SIZE_TYPE__ = c_ulonglong;
pub const __SIZE_FMTo__ = "llo";
pub const __SIZE_FMTu__ = "llu";
pub const __SIZE_FMTx__ = "llx";
pub const __SIZE_FMTX__ = "llX";
pub const __WCHAR_TYPE__ = c_ushort;
pub const __WINT_TYPE__ = c_ushort;
pub const __SIG_ATOMIC_MAX__ = @import("std").zig.c_translation.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __SIG_ATOMIC_WIDTH__ = @as(c_int, 32);
pub const __CHAR16_TYPE__ = c_ushort;
pub const __CHAR32_TYPE__ = c_uint;
pub const __UINTPTR_TYPE__ = c_ulonglong;
pub const __UINTPTR_FMTo__ = "llo";
pub const __UINTPTR_FMTu__ = "llu";
pub const __UINTPTR_FMTx__ = "llx";
pub const __UINTPTR_FMTX__ = "llX";
pub const __FLT16_DENORM_MIN__ = @as(f16, 5.9604644775390625e-8);
pub const __FLT16_NORM_MAX__ = @as(f16, 6.5504e+4);
pub const __FLT16_HAS_DENORM__ = @as(c_int, 1);
pub const __FLT16_DIG__ = @as(c_int, 3);
pub const __FLT16_DECIMAL_DIG__ = @as(c_int, 5);
pub const __FLT16_EPSILON__ = @as(f16, 9.765625e-4);
pub const __FLT16_HAS_INFINITY__ = @as(c_int, 1);
pub const __FLT16_HAS_QUIET_NAN__ = @as(c_int, 1);
pub const __FLT16_MANT_DIG__ = @as(c_int, 11);
pub const __FLT16_MAX_10_EXP__ = @as(c_int, 4);
pub const __FLT16_MAX_EXP__ = @as(c_int, 16);
pub const __FLT16_MAX__ = @as(f16, 6.5504e+4);
pub const __FLT16_MIN_10_EXP__ = -@as(c_int, 4);
pub const __FLT16_MIN_EXP__ = -@as(c_int, 13);
pub const __FLT16_MIN__ = @as(f16, 6.103515625e-5);
pub const __FLT_DENORM_MIN__ = @as(f32, 1.40129846e-45);
pub const __FLT_NORM_MAX__ = @as(f32, 3.40282347e+38);
pub const __FLT_HAS_DENORM__ = @as(c_int, 1);
pub const __FLT_DIG__ = @as(c_int, 6);
pub const __FLT_DECIMAL_DIG__ = @as(c_int, 9);
pub const __FLT_EPSILON__ = @as(f32, 1.19209290e-7);
pub const __FLT_HAS_INFINITY__ = @as(c_int, 1);
pub const __FLT_HAS_QUIET_NAN__ = @as(c_int, 1);
pub const __FLT_MANT_DIG__ = @as(c_int, 24);
pub const __FLT_MAX_10_EXP__ = @as(c_int, 38);
pub const __FLT_MAX_EXP__ = @as(c_int, 128);
pub const __FLT_MAX__ = @as(f32, 3.40282347e+38);
pub const __FLT_MIN_10_EXP__ = -@as(c_int, 37);
pub const __FLT_MIN_EXP__ = -@as(c_int, 125);
pub const __FLT_MIN__ = @as(f32, 1.17549435e-38);
pub const __DBL_DENORM_MIN__ = @as(f64, 4.9406564584124654e-324);
pub const __DBL_NORM_MAX__ = @as(f64, 1.7976931348623157e+308);
pub const __DBL_HAS_DENORM__ = @as(c_int, 1);
pub const __DBL_DIG__ = @as(c_int, 15);
pub const __DBL_DECIMAL_DIG__ = @as(c_int, 17);
pub const __DBL_EPSILON__ = @as(f64, 2.2204460492503131e-16);
pub const __DBL_HAS_INFINITY__ = @as(c_int, 1);
pub const __DBL_HAS_QUIET_NAN__ = @as(c_int, 1);
pub const __DBL_MANT_DIG__ = @as(c_int, 53);
pub const __DBL_MAX_10_EXP__ = @as(c_int, 308);
pub const __DBL_MAX_EXP__ = @as(c_int, 1024);
pub const __DBL_MAX__ = @as(f64, 1.7976931348623157e+308);
pub const __DBL_MIN_10_EXP__ = -@as(c_int, 307);
pub const __DBL_MIN_EXP__ = -@as(c_int, 1021);
pub const __DBL_MIN__ = @as(f64, 2.2250738585072014e-308);
pub const __LDBL_DENORM_MIN__ = @as(c_longdouble, 3.64519953188247460253e-4951);
pub const __LDBL_NORM_MAX__ = @as(c_longdouble, 1.18973149535723176502e+4932);
pub const __LDBL_HAS_DENORM__ = @as(c_int, 1);
pub const __LDBL_DIG__ = @as(c_int, 18);
pub const __LDBL_DECIMAL_DIG__ = @as(c_int, 21);
pub const __LDBL_EPSILON__ = @as(c_longdouble, 1.08420217248550443401e-19);
pub const __LDBL_HAS_INFINITY__ = @as(c_int, 1);
pub const __LDBL_HAS_QUIET_NAN__ = @as(c_int, 1);
pub const __LDBL_MANT_DIG__ = @as(c_int, 64);
pub const __LDBL_MAX_10_EXP__ = @as(c_int, 4932);
pub const __LDBL_MAX_EXP__ = @as(c_int, 16384);
pub const __LDBL_MAX__ = @as(c_longdouble, 1.18973149535723176502e+4932);
pub const __LDBL_MIN_10_EXP__ = -@as(c_int, 4931);
pub const __LDBL_MIN_EXP__ = -@as(c_int, 16381);
pub const __LDBL_MIN__ = @as(c_longdouble, 3.36210314311209350626e-4932);
pub const __POINTER_WIDTH__ = @as(c_int, 64);
pub const __BIGGEST_ALIGNMENT__ = @as(c_int, 16);
pub const __WCHAR_UNSIGNED__ = @as(c_int, 1);
pub const __WINT_UNSIGNED__ = @as(c_int, 1);
pub const __INT8_TYPE__ = i8;
pub const __INT8_FMTd__ = "hhd";
pub const __INT8_FMTi__ = "hhi";
pub const __INT8_C_SUFFIX__ = "";
pub inline fn __INT8_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub const __INT16_TYPE__ = c_short;
pub const __INT16_FMTd__ = "hd";
pub const __INT16_FMTi__ = "hi";
pub const __INT16_C_SUFFIX__ = "";
pub inline fn __INT16_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub const __INT32_TYPE__ = c_int;
pub const __INT32_FMTd__ = "d";
pub const __INT32_FMTi__ = "i";
pub const __INT32_C_SUFFIX__ = "";
pub inline fn __INT32_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub const __INT64_TYPE__ = c_longlong;
pub const __INT64_FMTd__ = "lld";
pub const __INT64_FMTi__ = "lli";
pub const __INT64_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `LL`");
// (no file):208:9
pub const __INT64_C = @import("std").zig.c_translation.Macros.LL_SUFFIX;
pub const __UINT8_TYPE__ = u8;
pub const __UINT8_FMTo__ = "hho";
pub const __UINT8_FMTu__ = "hhu";
pub const __UINT8_FMTx__ = "hhx";
pub const __UINT8_FMTX__ = "hhX";
pub const __UINT8_C_SUFFIX__ = "";
pub inline fn __UINT8_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub const __UINT8_MAX__ = @as(c_int, 255);
pub const __INT8_MAX__ = @as(c_int, 127);
pub const __UINT16_TYPE__ = c_ushort;
pub const __UINT16_FMTo__ = "ho";
pub const __UINT16_FMTu__ = "hu";
pub const __UINT16_FMTx__ = "hx";
pub const __UINT16_FMTX__ = "hX";
pub const __UINT16_C_SUFFIX__ = "";
pub inline fn __UINT16_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub const __UINT16_MAX__ = @import("std").zig.c_translation.promoteIntLiteral(c_int, 65535, .decimal);
pub const __INT16_MAX__ = @as(c_int, 32767);
pub const __UINT32_TYPE__ = c_uint;
pub const __UINT32_FMTo__ = "o";
pub const __UINT32_FMTu__ = "u";
pub const __UINT32_FMTx__ = "x";
pub const __UINT32_FMTX__ = "X";
pub const __UINT32_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `U`");
// (no file):233:9
pub const __UINT32_C = @import("std").zig.c_translation.Macros.U_SUFFIX;
pub const __UINT32_MAX__ = @import("std").zig.c_translation.promoteIntLiteral(c_uint, 4294967295, .decimal);
pub const __INT32_MAX__ = @import("std").zig.c_translation.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __UINT64_TYPE__ = c_ulonglong;
pub const __UINT64_FMTo__ = "llo";
pub const __UINT64_FMTu__ = "llu";
pub const __UINT64_FMTx__ = "llx";
pub const __UINT64_FMTX__ = "llX";
pub const __UINT64_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `ULL`");
// (no file):242:9
pub const __UINT64_C = @import("std").zig.c_translation.Macros.ULL_SUFFIX;
pub const __UINT64_MAX__ = @as(c_ulonglong, 18446744073709551615);
pub const __INT64_MAX__ = @as(c_longlong, 9223372036854775807);
pub const __INT_LEAST8_TYPE__ = i8;
pub const __INT_LEAST8_MAX__ = @as(c_int, 127);
pub const __INT_LEAST8_WIDTH__ = @as(c_int, 8);
pub const __INT_LEAST8_FMTd__ = "hhd";
pub const __INT_LEAST8_FMTi__ = "hhi";
pub const __UINT_LEAST8_TYPE__ = u8;
pub const __UINT_LEAST8_MAX__ = @as(c_int, 255);
pub const __UINT_LEAST8_FMTo__ = "hho";
pub const __UINT_LEAST8_FMTu__ = "hhu";
pub const __UINT_LEAST8_FMTx__ = "hhx";
pub const __UINT_LEAST8_FMTX__ = "hhX";
pub const __INT_LEAST16_TYPE__ = c_short;
pub const __INT_LEAST16_MAX__ = @as(c_int, 32767);
pub const __INT_LEAST16_WIDTH__ = @as(c_int, 16);
pub const __INT_LEAST16_FMTd__ = "hd";
pub const __INT_LEAST16_FMTi__ = "hi";
pub const __UINT_LEAST16_TYPE__ = c_ushort;
pub const __UINT_LEAST16_MAX__ = @import("std").zig.c_translation.promoteIntLiteral(c_int, 65535, .decimal);
pub const __UINT_LEAST16_FMTo__ = "ho";
pub const __UINT_LEAST16_FMTu__ = "hu";
pub const __UINT_LEAST16_FMTx__ = "hx";
pub const __UINT_LEAST16_FMTX__ = "hX";
pub const __INT_LEAST32_TYPE__ = c_int;
pub const __INT_LEAST32_MAX__ = @import("std").zig.c_translation.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __INT_LEAST32_WIDTH__ = @as(c_int, 32);
pub const __INT_LEAST32_FMTd__ = "d";
pub const __INT_LEAST32_FMTi__ = "i";
pub const __UINT_LEAST32_TYPE__ = c_uint;
pub const __UINT_LEAST32_MAX__ = @import("std").zig.c_translation.promoteIntLiteral(c_uint, 4294967295, .decimal);
pub const __UINT_LEAST32_FMTo__ = "o";
pub const __UINT_LEAST32_FMTu__ = "u";
pub const __UINT_LEAST32_FMTx__ = "x";
pub const __UINT_LEAST32_FMTX__ = "X";
pub const __INT_LEAST64_TYPE__ = c_longlong;
pub const __INT_LEAST64_MAX__ = @as(c_longlong, 9223372036854775807);
pub const __INT_LEAST64_WIDTH__ = @as(c_int, 64);
pub const __INT_LEAST64_FMTd__ = "lld";
pub const __INT_LEAST64_FMTi__ = "lli";
pub const __UINT_LEAST64_TYPE__ = c_ulonglong;
pub const __UINT_LEAST64_MAX__ = @as(c_ulonglong, 18446744073709551615);
pub const __UINT_LEAST64_FMTo__ = "llo";
pub const __UINT_LEAST64_FMTu__ = "llu";
pub const __UINT_LEAST64_FMTx__ = "llx";
pub const __UINT_LEAST64_FMTX__ = "llX";
pub const __INT_FAST8_TYPE__ = i8;
pub const __INT_FAST8_MAX__ = @as(c_int, 127);
pub const __INT_FAST8_WIDTH__ = @as(c_int, 8);
pub const __INT_FAST8_FMTd__ = "hhd";
pub const __INT_FAST8_FMTi__ = "hhi";
pub const __UINT_FAST8_TYPE__ = u8;
pub const __UINT_FAST8_MAX__ = @as(c_int, 255);
pub const __UINT_FAST8_FMTo__ = "hho";
pub const __UINT_FAST8_FMTu__ = "hhu";
pub const __UINT_FAST8_FMTx__ = "hhx";
pub const __UINT_FAST8_FMTX__ = "hhX";
pub const __INT_FAST16_TYPE__ = c_short;
pub const __INT_FAST16_MAX__ = @as(c_int, 32767);
pub const __INT_FAST16_WIDTH__ = @as(c_int, 16);
pub const __INT_FAST16_FMTd__ = "hd";
pub const __INT_FAST16_FMTi__ = "hi";
pub const __UINT_FAST16_TYPE__ = c_ushort;
pub const __UINT_FAST16_MAX__ = @import("std").zig.c_translation.promoteIntLiteral(c_int, 65535, .decimal);
pub const __UINT_FAST16_FMTo__ = "ho";
pub const __UINT_FAST16_FMTu__ = "hu";
pub const __UINT_FAST16_FMTx__ = "hx";
pub const __UINT_FAST16_FMTX__ = "hX";
pub const __INT_FAST32_TYPE__ = c_int;
pub const __INT_FAST32_MAX__ = @import("std").zig.c_translation.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __INT_FAST32_WIDTH__ = @as(c_int, 32);
pub const __INT_FAST32_FMTd__ = "d";
pub const __INT_FAST32_FMTi__ = "i";
pub const __UINT_FAST32_TYPE__ = c_uint;
pub const __UINT_FAST32_MAX__ = @import("std").zig.c_translation.promoteIntLiteral(c_uint, 4294967295, .decimal);
pub const __UINT_FAST32_FMTo__ = "o";
pub const __UINT_FAST32_FMTu__ = "u";
pub const __UINT_FAST32_FMTx__ = "x";
pub const __UINT_FAST32_FMTX__ = "X";
pub const __INT_FAST64_TYPE__ = c_longlong;
pub const __INT_FAST64_MAX__ = @as(c_longlong, 9223372036854775807);
pub const __INT_FAST64_WIDTH__ = @as(c_int, 64);
pub const __INT_FAST64_FMTd__ = "lld";
pub const __INT_FAST64_FMTi__ = "lli";
pub const __UINT_FAST64_TYPE__ = c_ulonglong;
pub const __UINT_FAST64_MAX__ = @as(c_ulonglong, 18446744073709551615);
pub const __UINT_FAST64_FMTo__ = "llo";
pub const __UINT_FAST64_FMTu__ = "llu";
pub const __UINT_FAST64_FMTx__ = "llx";
pub const __UINT_FAST64_FMTX__ = "llX";
pub const __USER_LABEL_PREFIX__ = "";
pub const __FINITE_MATH_ONLY__ = @as(c_int, 0);
pub const __GNUC_STDC_INLINE__ = @as(c_int, 1);
pub const __GCC_ATOMIC_TEST_AND_SET_TRUEVAL = @as(c_int, 1);
pub const __GCC_DESTRUCTIVE_SIZE = @as(c_int, 64);
pub const __GCC_CONSTRUCTIVE_SIZE = @as(c_int, 64);
pub const __CLANG_ATOMIC_BOOL_LOCK_FREE = @as(c_int, 2);
pub const __CLANG_ATOMIC_CHAR_LOCK_FREE = @as(c_int, 2);
pub const __CLANG_ATOMIC_CHAR16_T_LOCK_FREE = @as(c_int, 2);
pub const __CLANG_ATOMIC_CHAR32_T_LOCK_FREE = @as(c_int, 2);
pub const __CLANG_ATOMIC_WCHAR_T_LOCK_FREE = @as(c_int, 2);
pub const __CLANG_ATOMIC_SHORT_LOCK_FREE = @as(c_int, 2);
pub const __CLANG_ATOMIC_INT_LOCK_FREE = @as(c_int, 2);
pub const __CLANG_ATOMIC_LONG_LOCK_FREE = @as(c_int, 2);
pub const __CLANG_ATOMIC_LLONG_LOCK_FREE = @as(c_int, 2);
pub const __CLANG_ATOMIC_POINTER_LOCK_FREE = @as(c_int, 2);
pub const __GCC_ATOMIC_BOOL_LOCK_FREE = @as(c_int, 2);
pub const __GCC_ATOMIC_CHAR_LOCK_FREE = @as(c_int, 2);
pub const __GCC_ATOMIC_CHAR16_T_LOCK_FREE = @as(c_int, 2);
pub const __GCC_ATOMIC_CHAR32_T_LOCK_FREE = @as(c_int, 2);
pub const __GCC_ATOMIC_WCHAR_T_LOCK_FREE = @as(c_int, 2);
pub const __GCC_ATOMIC_SHORT_LOCK_FREE = @as(c_int, 2);
pub const __GCC_ATOMIC_INT_LOCK_FREE = @as(c_int, 2);
pub const __GCC_ATOMIC_LONG_LOCK_FREE = @as(c_int, 2);
pub const __GCC_ATOMIC_LLONG_LOCK_FREE = @as(c_int, 2);
pub const __GCC_ATOMIC_POINTER_LOCK_FREE = @as(c_int, 2);
pub const __NO_INLINE__ = @as(c_int, 1);
pub const __PIC__ = @as(c_int, 2);
pub const __pic__ = @as(c_int, 2);
pub const __FLT_RADIX__ = @as(c_int, 2);
pub const __DECIMAL_DIG__ = __LDBL_DECIMAL_DIG__;
pub const __GCC_ASM_FLAG_OUTPUTS__ = @as(c_int, 1);
pub const __code_model_small__ = @as(c_int, 1);
pub const __amd64__ = @as(c_int, 1);
pub const __amd64 = @as(c_int, 1);
pub const __x86_64 = @as(c_int, 1);
pub const __x86_64__ = @as(c_int, 1);
pub const __SEG_GS = @as(c_int, 1);
pub const __SEG_FS = @as(c_int, 1);
pub const __seg_gs = @compileError("unable to translate macro: undefined identifier `address_space`");
// (no file):375:9
pub const __seg_fs = @compileError("unable to translate macro: undefined identifier `address_space`");
// (no file):376:9
pub const __corei7 = @as(c_int, 1);
pub const __corei7__ = @as(c_int, 1);
pub const __tune_corei7__ = @as(c_int, 1);
pub const __REGISTER_PREFIX__ = "";
pub const __NO_MATH_INLINES = @as(c_int, 1);
pub const __AES__ = @as(c_int, 1);
pub const __VAES__ = @as(c_int, 1);
pub const __PCLMUL__ = @as(c_int, 1);
pub const __VPCLMULQDQ__ = @as(c_int, 1);
pub const __LAHF_SAHF__ = @as(c_int, 1);
pub const __LZCNT__ = @as(c_int, 1);
pub const __RDRND__ = @as(c_int, 1);
pub const __FSGSBASE__ = @as(c_int, 1);
pub const __BMI__ = @as(c_int, 1);
pub const __BMI2__ = @as(c_int, 1);
pub const __POPCNT__ = @as(c_int, 1);
pub const __PRFCHW__ = @as(c_int, 1);
pub const __RDSEED__ = @as(c_int, 1);
pub const __ADX__ = @as(c_int, 1);
pub const __MOVBE__ = @as(c_int, 1);
pub const __FMA__ = @as(c_int, 1);
pub const __F16C__ = @as(c_int, 1);
pub const __GFNI__ = @as(c_int, 1);
pub const __SHA__ = @as(c_int, 1);
pub const __FXSR__ = @as(c_int, 1);
pub const __XSAVE__ = @as(c_int, 1);
pub const __XSAVEOPT__ = @as(c_int, 1);
pub const __XSAVEC__ = @as(c_int, 1);
pub const __XSAVES__ = @as(c_int, 1);
pub const __CLFLUSHOPT__ = @as(c_int, 1);
pub const __CLWB__ = @as(c_int, 1);
pub const __SHSTK__ = @as(c_int, 1);
pub const __RDPID__ = @as(c_int, 1);
pub const __WAITPKG__ = @as(c_int, 1);
pub const __MOVDIRI__ = @as(c_int, 1);
pub const __MOVDIR64B__ = @as(c_int, 1);
pub const __PTWRITE__ = @as(c_int, 1);
pub const __INVPCID__ = @as(c_int, 1);
pub const __HRESET__ = @as(c_int, 1);
pub const __AVXVNNI__ = @as(c_int, 1);
pub const __SERIALIZE__ = @as(c_int, 1);
pub const __CRC32__ = @as(c_int, 1);
pub const __AVX2__ = @as(c_int, 1);
pub const __AVX__ = @as(c_int, 1);
pub const __SSE4_2__ = @as(c_int, 1);
pub const __SSE4_1__ = @as(c_int, 1);
pub const __SSSE3__ = @as(c_int, 1);
pub const __SSE3__ = @as(c_int, 1);
pub const __SSE2__ = @as(c_int, 1);
pub const __SSE2_MATH__ = @as(c_int, 1);
pub const __SSE__ = @as(c_int, 1);
pub const __SSE_MATH__ = @as(c_int, 1);
pub const __MMX__ = @as(c_int, 1);
pub const __GCC_HAVE_SYNC_COMPARE_AND_SWAP_1 = @as(c_int, 1);
pub const __GCC_HAVE_SYNC_COMPARE_AND_SWAP_2 = @as(c_int, 1);
pub const __GCC_HAVE_SYNC_COMPARE_AND_SWAP_4 = @as(c_int, 1);
pub const __GCC_HAVE_SYNC_COMPARE_AND_SWAP_8 = @as(c_int, 1);
pub const __GCC_HAVE_SYNC_COMPARE_AND_SWAP_16 = @as(c_int, 1);
pub const __SIZEOF_FLOAT128__ = @as(c_int, 16);
pub const _WIN32 = @as(c_int, 1);
pub const _WIN64 = @as(c_int, 1);
pub const WIN32 = @as(c_int, 1);
pub const __WIN32 = @as(c_int, 1);
pub const __WIN32__ = @as(c_int, 1);
pub const WINNT = @as(c_int, 1);
pub const __WINNT = @as(c_int, 1);
pub const __WINNT__ = @as(c_int, 1);
pub const WIN64 = @as(c_int, 1);
pub const __WIN64 = @as(c_int, 1);
pub const __WIN64__ = @as(c_int, 1);
pub const __MINGW64__ = @as(c_int, 1);
pub const __MSVCRT__ = @as(c_int, 1);
pub const __MINGW32__ = @as(c_int, 1);
pub const __declspec = @compileError("unable to translate C expr: unexpected token '__attribute__'");
// (no file):450:9
pub const _cdecl = @compileError("unable to translate macro: undefined identifier `__cdecl__`");
// (no file):451:9
pub const __cdecl = @compileError("unable to translate macro: undefined identifier `__cdecl__`");
// (no file):452:9
pub const _stdcall = @compileError("unable to translate macro: undefined identifier `__stdcall__`");
// (no file):453:9
pub const __stdcall = @compileError("unable to translate macro: undefined identifier `__stdcall__`");
// (no file):454:9
pub const _fastcall = @compileError("unable to translate macro: undefined identifier `__fastcall__`");
// (no file):455:9
pub const __fastcall = @compileError("unable to translate macro: undefined identifier `__fastcall__`");
// (no file):456:9
pub const _thiscall = @compileError("unable to translate macro: undefined identifier `__thiscall__`");
// (no file):457:9
pub const __thiscall = @compileError("unable to translate macro: undefined identifier `__thiscall__`");
// (no file):458:9
pub const _pascal = @compileError("unable to translate macro: undefined identifier `__pascal__`");
// (no file):459:9
pub const __pascal = @compileError("unable to translate macro: undefined identifier `__pascal__`");
// (no file):460:9
pub const __STDC__ = @as(c_int, 1);
pub const __STDC_HOSTED__ = @as(c_int, 1);
pub const __STDC_VERSION__ = @as(c_long, 201710);
pub const __STDC_UTF_16__ = @as(c_int, 1);
pub const __STDC_UTF_32__ = @as(c_int, 1);
pub const __STDC_EMBED_NOT_FOUND__ = @as(c_int, 0);
pub const __STDC_EMBED_FOUND__ = @as(c_int, 1);
pub const __STDC_EMBED_EMPTY__ = @as(c_int, 2);
pub const dr_mp3_h = "";
pub const DRMP3_STRINGIFY = @compileError("unable to translate C expr: unexpected token '#'");
// libs/dr_libs/dr_mp3.h:70:9
pub inline fn DRMP3_XSTRINGIFY(x: anytype) @TypeOf(DRMP3_STRINGIFY(x)) {
    _ = &x;
    return DRMP3_STRINGIFY(x);
}
pub const DRMP3_VERSION_MAJOR = @as(c_int, 0);
pub const DRMP3_VERSION_MINOR = @as(c_int, 7);
pub const DRMP3_VERSION_REVISION = @as(c_int, 2);
pub const DRMP3_VERSION_STRING = DRMP3_XSTRINGIFY(DRMP3_VERSION_MAJOR) ++ "." ++ DRMP3_XSTRINGIFY(DRMP3_VERSION_MINOR) ++ "." ++ DRMP3_XSTRINGIFY(DRMP3_VERSION_REVISION);
pub const __need_ptrdiff_t = "";
pub const __need_size_t = "";
pub const __need_wchar_t = "";
pub const __need_NULL = "";
pub const __need_max_align_t = "";
pub const __need_offsetof = "";
pub const __STDDEF_H = "";
pub const _PTRDIFF_T = "";
pub const _SIZE_T = "";
pub const _WCHAR_T = "";
pub const NULL = @import("std").zig.c_translation.cast(?*anyopaque, @as(c_int, 0));
pub const __CLANG_MAX_ALIGN_T_DEFINED = "";
pub const offsetof = @compileError("unable to translate C expr: unexpected token 'an identifier'");
// C:\Users\Cam\AppData\Local\Microsoft\WinGet\Packages\zig.zig_Microsoft.Winget.Source_8wekyb3d8bbwe\zig-x86_64-windows-0.15.2\lib\include/__stddef_offsetof.h:16:9
pub const DRMP3_TRUE = @as(c_int, 1);
pub const DRMP3_FALSE = @as(c_int, 0);
pub const DRMP3_UINT64_MAX = (@import("std").zig.c_translation.cast(drmp3_uint64, @import("std").zig.c_translation.promoteIntLiteral(c_int, 0xFFFFFFFF, .hex)) << @as(c_int, 32)) | @import("std").zig.c_translation.cast(drmp3_uint64, @import("std").zig.c_translation.promoteIntLiteral(c_int, 0xFFFFFFFF, .hex));
pub const DRMP3_API = @compileError("unable to translate C expr: unexpected token 'extern'");
// libs/dr_libs/dr_mp3.h:144:17
pub const DRMP3_PRIVATE = @compileError("unable to translate C expr: unexpected token 'static'");
// libs/dr_libs/dr_mp3.h:145:17
pub const DRMP3_SUCCESS = @as(c_int, 0);
pub const DRMP3_ERROR = -@as(c_int, 1);
pub const DRMP3_INVALID_ARGS = -@as(c_int, 2);
pub const DRMP3_INVALID_OPERATION = -@as(c_int, 3);
pub const DRMP3_OUT_OF_MEMORY = -@as(c_int, 4);
pub const DRMP3_OUT_OF_RANGE = -@as(c_int, 5);
pub const DRMP3_ACCESS_DENIED = -@as(c_int, 6);
pub const DRMP3_DOES_NOT_EXIST = -@as(c_int, 7);
pub const DRMP3_ALREADY_EXISTS = -@as(c_int, 8);
pub const DRMP3_TOO_MANY_OPEN_FILES = -@as(c_int, 9);
pub const DRMP3_INVALID_FILE = -@as(c_int, 10);
pub const DRMP3_TOO_BIG = -@as(c_int, 11);
pub const DRMP3_PATH_TOO_LONG = -@as(c_int, 12);
pub const DRMP3_NAME_TOO_LONG = -@as(c_int, 13);
pub const DRMP3_NOT_DIRECTORY = -@as(c_int, 14);
pub const DRMP3_IS_DIRECTORY = -@as(c_int, 15);
pub const DRMP3_DIRECTORY_NOT_EMPTY = -@as(c_int, 16);
pub const DRMP3_END_OF_FILE = -@as(c_int, 17);
pub const DRMP3_NO_SPACE = -@as(c_int, 18);
pub const DRMP3_BUSY = -@as(c_int, 19);
pub const DRMP3_IO_ERROR = -@as(c_int, 20);
pub const DRMP3_INTERRUPT = -@as(c_int, 21);
pub const DRMP3_UNAVAILABLE = -@as(c_int, 22);
pub const DRMP3_ALREADY_IN_USE = -@as(c_int, 23);
pub const DRMP3_BAD_ADDRESS = -@as(c_int, 24);
pub const DRMP3_BAD_SEEK = -@as(c_int, 25);
pub const DRMP3_BAD_PIPE = -@as(c_int, 26);
pub const DRMP3_DEADLOCK = -@as(c_int, 27);
pub const DRMP3_TOO_MANY_LINKS = -@as(c_int, 28);
pub const DRMP3_NOT_IMPLEMENTED = -@as(c_int, 29);
pub const DRMP3_NO_MESSAGE = -@as(c_int, 30);
pub const DRMP3_BAD_MESSAGE = -@as(c_int, 31);
pub const DRMP3_NO_DATA_AVAILABLE = -@as(c_int, 32);
pub const DRMP3_INVALID_DATA = -@as(c_int, 33);
pub const DRMP3_TIMEOUT = -@as(c_int, 34);
pub const DRMP3_NO_NETWORK = -@as(c_int, 35);
pub const DRMP3_NOT_UNIQUE = -@as(c_int, 36);
pub const DRMP3_NOT_SOCKET = -@as(c_int, 37);
pub const DRMP3_NO_ADDRESS = -@as(c_int, 38);
pub const DRMP3_BAD_PROTOCOL = -@as(c_int, 39);
pub const DRMP3_PROTOCOL_UNAVAILABLE = -@as(c_int, 40);
pub const DRMP3_PROTOCOL_NOT_SUPPORTED = -@as(c_int, 41);
pub const DRMP3_PROTOCOL_FAMILY_NOT_SUPPORTED = -@as(c_int, 42);
pub const DRMP3_ADDRESS_FAMILY_NOT_SUPPORTED = -@as(c_int, 43);
pub const DRMP3_SOCKET_NOT_SUPPORTED = -@as(c_int, 44);
pub const DRMP3_CONNECTION_RESET = -@as(c_int, 45);
pub const DRMP3_ALREADY_CONNECTED = -@as(c_int, 46);
pub const DRMP3_NOT_CONNECTED = -@as(c_int, 47);
pub const DRMP3_CONNECTION_REFUSED = -@as(c_int, 48);
pub const DRMP3_NO_HOST = -@as(c_int, 49);
pub const DRMP3_IN_PROGRESS = -@as(c_int, 50);
pub const DRMP3_CANCELLED = -@as(c_int, 51);
pub const DRMP3_MEMORY_ALREADY_MAPPED = -@as(c_int, 52);
pub const DRMP3_AT_END = -@as(c_int, 53);
pub const DRMP3_MAX_PCM_FRAMES_PER_MP3_FRAME = @as(c_int, 1152);
pub const DRMP3_MAX_SAMPLES_PER_FRAME = DRMP3_MAX_PCM_FRAMES_PER_MP3_FRAME * @as(c_int, 2);
pub const DRMP3_GNUC_INLINE_HINT = @compileError("unable to translate C expr: unexpected token 'inline'");
// libs/dr_libs/dr_mp3.h:225:17
pub const DRMP3_INLINE = @compileError("unable to translate macro: undefined identifier `always_inline`");
// libs/dr_libs/dr_mp3.h:229:17
pub const DRMP3_MAX_BITRESERVOIR_BYTES = @as(c_int, 511);
pub const DRMP3_MAX_FREE_FORMAT_FRAME_SIZE = @as(c_int, 2304);
pub const DRMP3_MAX_L3_FRAME_PAYLOAD_BYTES = DRMP3_MAX_FREE_FORMAT_FRAME_SIZE;
