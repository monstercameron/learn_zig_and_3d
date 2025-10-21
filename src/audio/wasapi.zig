//! WASAPI (Windows Audio Session API) Interface Definitions
//! This file contains the Zig translations of the core COM interfaces
//! required to interact with the Windows audio subsystem.

const std = @import("std");
const windows = std.os.windows;

// COM GUID structure
pub const GUID = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

// Base COM interface
pub const IUnknown = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        queryInterface: *const fn (self: *const IUnknown, riid: *const GUID, ppvObject: *?*anyopaque) callconv(.Stdcall) windows.HRESULT,
        addRef: *const fn (self: *const IUnknown) callconv(.Stdcall) u32,
        release: *const fn (self: *const IUnknown) callconv(.Stdcall) u32,
    };

    pub fn release(self: *const IUnknown) u32 {
        return self.vtable.release(self);
    }
};

// --- Core Audio Interfaces ---

// Represents an audio endpoint device (e.g., speakers)
pub const IMMDevice = extern struct {
    vtable: *const VTable,
    pub const VTable = extern struct {
        base: IUnknown.VTable,
        activate: *const fn (self: *const IMMDevice, iid: *const GUID, dwClsCtx: u32, pActivationParams: ?*anyopaque, ppInterface: *?*anyopaque) callconv(.Stdcall) windows.HRESULT,
        // ... other methods we don't need yet
    };

    pub fn activate(self: *const IMMDevice, iid: *const GUID, ppInterface: *?*anyopaque) windows.HRESULT {
        // CLSCTX_ALL indicates we want an in-process server
        const CLSCTX_ALL = 0x1 | 0x2 | 0x4 | 0x10;
        return self.vtable.activate(self, iid, CLSCTX_ALL, null, ppInterface);
    }

    pub fn release(self: *const IMMDevice) u32 {
        return self.vtable.base.release(@ptrCast(self));
    }
};

// Enumerates audio endpoint devices
pub const IMMDeviceEnumerator = extern struct {
    vtable: *const VTable,
    pub const VTable = extern struct {
        base: IUnknown.VTable,
        enumAudioEndpoints: *const fn (self: *const IMMDeviceEnumerator, eDataFlow: i32, dwStateMask: u32, ppDevices: *?*anyopaque) callconv(.Stdcall) windows.HRESULT,
        getDefaultAudioEndpoint: *const fn (self: *const IMMDeviceEnumerator, eDataFlow: i32, eRole: i32, ppEndpoint: *?*IMMDevice) callconv(.Stdcall) windows.HRESULT,
        // ... other methods
    };

    pub fn getDefaultAudioEndpoint(self: *const IMMDeviceEnumerator, dataFlow: i32, role: i32, ppEndpoint: *?*IMMDevice) windows.HRESULT {
        return self.vtable.getDefaultAudioEndpoint(self, dataFlow, role, ppEndpoint);
    }

    pub fn release(self: *const IMMDeviceEnumerator) u32 {
        return self.vtable.base.release(@ptrCast(self));
    }
};

// Provides access to the audio client for an endpoint device
pub const IAudioClient = extern struct {
    vtable: *const VTable,
    pub const VTable = extern struct {
        base: IUnknown.VTable,
        initialize: *const fn(self: *const IAudioClient, share_mode: i32, stream_flags: u32, hns_buffer_duration: i64, hns_periodicity: i64, p_format: *const WAVEFORMATEX, audio_session_guid: ?*const GUID) callconv(.Stdcall) windows.HRESULT,
        getBufferSize: *const fn(self: *const IAudioClient, p_num_buffer_frames: *u32) callconv(.Stdcall) windows.HRESULT,
        getStreamLatency: *const fn(self: *const IAudioClient, phns_latency: *i64) callconv(.Stdcall) windows.HRESULT,
        getCurrentPadding: *const fn(self: *const IAudioClient, p_num_padding_frames: *u32) callconv(.Stdcall) windows.HRESULT,
        isFormatSupported: *const fn(self: *const IAudioClient, share_mode: i32, p_format: *const WAVEFORMATEX, pp_closest_match: ?*?*WAVEFORMATEX) callconv(.Stdcall) windows.HRESULT,
        getMixFormat: *const fn(self: *const IAudioClient, pp_device_format: *?*WAVEFORMATEX) callconv(.Stdcall) windows.HRESULT,
        getService: *const fn(self: *const IAudioClient, riid: *const GUID, ppv: *?*anyopaque) callconv(.Stdcall) windows.HRESULT,
        start: *const fn(self: *const IAudioClient) callconv(.Stdcall) windows.HRESULT,
        stop: *const fn(self: *const IAudioClient) callconv(.Stdcall) windows.HRESULT,
        reset: *const fn(self: *const IAudioClient) callconv(.Stdcall) windows.HRESULT,
        // ... other methods
    };

    pub fn getService(self: *const IAudioClient, iid: *const GUID, ppv: *?*anyopaque) windows.HRESULT {
        return self.vtable.getService(self, iid, ppv);
    }

    pub fn getMixFormat(self: *const IAudioClient, pp_device_format: *?*WAVEFORMATEX) windows.HRESULT {
        return self.vtable.getMixFormat(self, pp_device_format);
    }

     pub fn initialize(self: *const IAudioClient, share_mode: i32, stream_flags: u32, hns_buffer_duration: i64, hns_periodicity: i64, p_format: *const WAVEFORMATEX) windows.HRESULT {
        return self.vtable.initialize(self, share_mode, stream_flags, hns_buffer_duration, hns_periodicity, p_format, null);
    }

    pub fn getBufferSize(self: *const IAudioClient, p_num_buffer_frames: *u32) windows.HRESULT {
        return self.vtable.getBufferSize(self, p_num_buffer_frames);
    }

    pub fn start(self: *const IAudioClient) windows.HRESULT {
        return self.vtable.start(self);
    }

    pub fn stop(self: *const IAudioClient) windows.HRESULT {
        return self.vtable.stop(self);
    }

    pub fn release(self: *const IAudioClient) u32 {
        return self.vtable.base.release(@ptrCast(self));
    }
};

// Used to write audio data to the endpoint buffer
pub const IAudioRenderClient = extern struct {
    vtable: *const VTable,
    pub const VTable = extern struct {
        base: IUnknown.VTable,
        getBuffer: *const fn(self: *const IAudioRenderClient, num_frames_requested: u32, pp_data: *?*u8) callconv(.Stdcall) windows.HRESULT,
        releaseBuffer: *const fn(self: *const IAudioRenderClient, num_frames_written: u32, dw_flags: u32) callconv(.Stdcall) windows.HRESULT,
    };

    pub fn getBuffer(self: *const IAudioRenderClient, num_frames_requested: u32, pp_data: *?*u8) windows.HRESULT {
        return self.vtable.getBuffer(self, num_frames_requested, pp_data);
    }

    pub fn releaseBuffer(self: *const IAudioRenderClient, num_frames_written: u32, flags: u32) windows.HRESULT {
        return self.vtable.releaseBuffer(self, num_frames_written, flags);
    }

    pub fn release(self: *const IAudioRenderClient) u32 {
        return self.vtable.base.release(@ptrCast(self));
    }
};

// --- GUIDs and Constants ---

pub const CLSID_MMDeviceEnumerator = GUID{
    .data1 = 0xBCDE0395,
    .data2 = 0xE52F,
    .data3 = 0x467C,
    .data4 = .{ 0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E },
};

pub const IID_IMMDeviceEnumerator = GUID{
    .data1 = 0xA95664D2,
    .data2 = 0x9614,
    .data3 = 0x4F35,
    .data4 = .{ 0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6 },
};

pub const IID_IAudioClient = GUID{
    .data1 = 0x1CB9AD4C,
    .data2 = 0xDBFA,
    .data3 = 0x4c32,
    .data4 = .{ 0xB1, 0x78, 0xC2, 0xF5, 0x68, 0xA7, 0x03, 0xB2 },
};

pub const IID_IAudioRenderClient = GUID{
    .data1 = 0xF294ACFC,
    .data2 = 0x3146,
    .data3 = 0x4483,
    .data4 = .{ 0xA7, 0xBF, 0xAD, 0xDC, 0xA7, 0x5A, 0x91, 0x26 },
};

pub const WAVE_FORMAT_EXTENSIBLE = 0xFFFE;

pub const WAVEFORMATEX = extern struct {
    wFormatTag: u16,
    nChannels: u16,
    nSamplesPerSec: u32,
    nAvgBytesPerSec: u32,
    nBlockAlign: u16,
    wBitsPerSample: u16,
    cbSize: u16,
};

pub const KSDATAFORMAT_SUBTYPE_IEEE_FLOAT = GUID{
    .data1 = 0x00000003,
    .data2 = 0x0000,
    .data3 = 0x0010,
    .data4 = .{ 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 },
};

pub const WAVEFORMATEXTENSIBLE = extern struct {
    Format: WAVEFORMATEX,
    Samples: extern union {
        wValidBitsPerSample: u16,
        wSamplesPerBlock: u16,
        wReserved: u16,
    },
    dwChannelMask: u32,
    SubFormat: GUID,
};

// --- COM Functions ---

// Initializes the COM library for the calling thread.
extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: u32) callconv(.Stdcall) windows.HRESULT;

// Closes the COM library on the current thread.
extern "ole32" fn CoUninitialize() callconv(.Stdcall) void;

// Creates a single uninitialized object of the class associated with a specified CLSID.
extern "ole32" fn CoCreateInstance(rclsid: *const GUID, pUnkOuter: ?*IUnknown, dwClsContext: u32, riid: *const GUID, ppv: *?*anyopaque) callconv(.Stdcall) windows.HRESULT;

// Frees a block of task memory.
extern "ole32" fn CoTaskMemFree(pv: ?*anyopaque) callconv(.Stdcall) void;
