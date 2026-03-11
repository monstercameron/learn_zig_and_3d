const std = @import("std");
const builtin = @import("builtin");

pub const VectorBackend = enum {
    scalar,
    neon,
    sse2,
    avx2,
    avx512,
};

pub const InstructionSetSupport = struct {
    neon: bool = false,
    sse2: bool = false,
    xsave: bool = false,
    osxsave: bool = false,
    os_avx_state: bool = false,
    avx: bool = false,
    fma: bool = false,
    avx2: bool = false,
    os_avx512_state: bool = false,
    avx512f: bool = false,
    avx512bw: bool = false,
    os_amx_state: bool = false,
    amx_tile: bool = false,
    amx_int8: bool = false,
    amx_bf16: bool = false,

    pub fn preferredVectorBackend(self: InstructionSetSupport) VectorBackend {
        if (self.avx512f and self.os_avx512_state) return .avx512;
        if (self.avx2 and self.os_avx_state) return .avx2;
        if (self.sse2) return .sse2;
        if (self.neon) return .neon;
        return .scalar;
    }
};

const CpuidRegs = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};

var cached_support: ?InstructionSetSupport = null;

pub fn detect() InstructionSetSupport {
    if (cached_support) |support| return support;
    const support = detectUncached();
    cached_support = support;
    return support;
}

fn detectUncached() InstructionSetSupport {
    switch (builtin.target.cpu.arch) {
        .x86, .x86_64 => return detectX86(),
        .aarch64 => return detectAarch64(),
        .arm => return detectArm(),
        else => return .{},
    }
}

fn detectAarch64() InstructionSetSupport {
    var support = InstructionSetSupport{};
    support.neon = std.Target.aarch64.featureSetHas(builtin.target.cpu.features, .neon);
    return support;
}

fn detectArm() InstructionSetSupport {
    var support = InstructionSetSupport{};
    support.neon = std.Target.arm.featureSetHas(builtin.target.cpu.features, .neon);
    return support;
}

fn detectX86() InstructionSetSupport {
    var support = InstructionSetSupport{};
    const leaf0 = cpuid(0, 0);
    const max_basic_leaf = leaf0.eax;

    if (max_basic_leaf < 1) return support;

    const leaf1 = cpuid(1, 0);
    support.sse2 = hasBit(leaf1.edx, 26);
    support.xsave = hasBit(leaf1.ecx, 26);
    support.osxsave = hasBit(leaf1.ecx, 27);

    if (support.osxsave) {
        const xcr0 = xgetbv(0);
        support.os_avx_state = (xcr0 & 0x6) == 0x6;
        support.os_avx512_state = (xcr0 & 0xE6) == 0xE6;
        support.os_amx_state = (xcr0 & 0x60000) == 0x60000;
    }

    support.avx = hasBit(leaf1.ecx, 28) and support.os_avx_state;
    support.fma = hasBit(leaf1.ecx, 12) and support.os_avx_state;

    if (max_basic_leaf < 7) return support;

    const leaf7 = cpuid(7, 0);
    support.avx2 = hasBit(leaf7.ebx, 5) and support.os_avx_state;
    support.avx512f = hasBit(leaf7.ebx, 16) and support.os_avx512_state;
    support.avx512bw = hasBit(leaf7.ebx, 30) and support.os_avx512_state;
    support.amx_bf16 = hasBit(leaf7.edx, 22) and support.os_amx_state;
    support.amx_tile = hasBit(leaf7.edx, 24) and support.os_amx_state;
    support.amx_int8 = hasBit(leaf7.edx, 25) and support.os_amx_state;

    return support;
}

fn hasBit(value: u32, bit_index: u5) bool {
    return (value & (@as(u32, 1) << bit_index)) != 0;
}

fn cpuid(leaf: u32, subleaf: u32) CpuidRegs {
    var eax = leaf;
    var ebx: u32 = undefined;
    var ecx = subleaf;
    var edx: u32 = undefined;

    asm volatile ("cpuid"
        : [eax] "+{eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "+{ecx}" (ecx),
          [edx] "={edx}" (edx),
        :
        : .{ .memory = true }
    );

    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

fn xgetbv(xcr: u32) u64 {
    var eax: u32 = undefined;
    var edx: u32 = undefined;

    asm volatile ("xgetbv"
        : [eax] "={eax}" (eax),
          [edx] "={edx}" (edx),
        : [ecx] "{ecx}" (xcr),
        : .{ .memory = true }
    );

    return (@as(u64, edx) << 32) | @as(u64, eax);
}
