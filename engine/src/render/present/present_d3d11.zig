const std = @import("std");
const windows = std.os.windows;
const Bitmap = @import("../../assets/bitmap.zig").Bitmap;

const HRESULT = windows.HRESULT;
const UINT = u32;
const BOOL = windows.BOOL;
const HMODULE = windows.HMODULE;

const DXGI_FORMAT_B8G8R8A8_UNORM: UINT = 87;
const DXGI_USAGE_RENDER_TARGET_OUTPUT: UINT = 0x20;
const DXGI_SWAP_EFFECT_DISCARD: UINT = 0;
const D3D_DRIVER_TYPE_HARDWARE: UINT = 1;
const D3D11_SDK_VERSION: UINT = 7;

const DXGI_RATIONAL = extern struct {
    Numerator: UINT,
    Denominator: UINT,
};

const DXGI_MODE_DESC = extern struct {
    Width: UINT,
    Height: UINT,
    RefreshRate: DXGI_RATIONAL,
    Format: UINT,
    ScanlineOrdering: UINT,
    Scaling: UINT,
};

const DXGI_SAMPLE_DESC = extern struct {
    Count: UINT,
    Quality: UINT,
};

const DXGI_SWAP_CHAIN_DESC = extern struct {
    BufferDesc: DXGI_MODE_DESC,
    SampleDesc: DXGI_SAMPLE_DESC,
    BufferUsage: UINT,
    BufferCount: UINT,
    OutputWindow: windows.HWND,
    Windowed: BOOL,
    SwapEffect: UINT,
    Flags: UINT,
};

const IUnknown = extern struct {
    lpVtbl: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const fn (*IUnknown, *const windows.GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IUnknown) callconv(.winapi) u32,
        Release: *const fn (*IUnknown) callconv(.winapi) u32,
    };
};

const IDXGISwapChain = extern struct {
    lpVtbl: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const fn (*IDXGISwapChain, *const windows.GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IDXGISwapChain) callconv(.winapi) u32,
        Release: *const fn (*IDXGISwapChain) callconv(.winapi) u32,
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        GetPrivateData: *const anyopaque,
        GetParent: *const anyopaque,
        GetDevice: *const anyopaque,
        Present: *const fn (*IDXGISwapChain, UINT, UINT) callconv(.winapi) HRESULT,
        GetBuffer: *const fn (*IDXGISwapChain, UINT, *const windows.GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        SetFullscreenState: *const anyopaque,
        GetFullscreenState: *const anyopaque,
        GetDesc: *const anyopaque,
        ResizeBuffers: *const fn (*IDXGISwapChain, UINT, UINT, UINT, UINT, UINT) callconv(.winapi) HRESULT,
        ResizeTarget: *const anyopaque,
        GetContainingOutput: *const anyopaque,
        GetFrameStatistics: *const anyopaque,
        GetLastPresentCount: *const anyopaque,
    };
};

const ID3D11Device = IUnknown;
const ID3D11Resource = IUnknown;

const D3D11_BOX = extern struct {
    left: UINT,
    top: UINT,
    front: UINT,
    right: UINT,
    bottom: UINT,
    back: UINT,
};

const ID3D11DeviceContext = extern struct {
    lpVtbl: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const fn (*ID3D11DeviceContext, *const windows.GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ID3D11DeviceContext) callconv(.winapi) u32,
        Release: *const fn (*ID3D11DeviceContext) callconv(.winapi) u32,
        GetDevice: *const anyopaque,
        GetPrivateData: *const anyopaque,
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        VSSetConstantBuffers: *const anyopaque,
        PSSetShaderResources: *const anyopaque,
        PSSetShader: *const anyopaque,
        PSSetSamplers: *const anyopaque,
        VSSetShader: *const anyopaque,
        DrawIndexed: *const anyopaque,
        Draw: *const anyopaque,
        Map: *const anyopaque,
        Unmap: *const anyopaque,
        PSSetConstantBuffers: *const anyopaque,
        IASetInputLayout: *const anyopaque,
        IASetVertexBuffers: *const anyopaque,
        IASetIndexBuffer: *const anyopaque,
        DrawIndexedInstanced: *const anyopaque,
        DrawInstanced: *const anyopaque,
        GSSetConstantBuffers: *const anyopaque,
        GSSetShader: *const anyopaque,
        IASetPrimitiveTopology: *const anyopaque,
        VSSetShaderResources: *const anyopaque,
        VSSetSamplers: *const anyopaque,
        Begin: *const anyopaque,
        End: *const anyopaque,
        GetData: *const anyopaque,
        SetPredication: *const anyopaque,
        GSSetShaderResources: *const anyopaque,
        GSSetSamplers: *const anyopaque,
        OMSetRenderTargets: *const anyopaque,
        OMSetRenderTargetsAndUnorderedAccessViews: *const anyopaque,
        OMSetBlendState: *const anyopaque,
        OMSetDepthStencilState: *const anyopaque,
        SOSetTargets: *const anyopaque,
        DrawAuto: *const anyopaque,
        DrawIndexedInstancedIndirect: *const anyopaque,
        DrawInstancedIndirect: *const anyopaque,
        Dispatch: *const anyopaque,
        DispatchIndirect: *const anyopaque,
        RSSetState: *const anyopaque,
        RSSetViewports: *const anyopaque,
        RSSetScissorRects: *const anyopaque,
        CopySubresourceRegion: *const anyopaque,
        CopyResource: *const anyopaque,
        UpdateSubresource: *const fn (*ID3D11DeviceContext, *ID3D11Resource, UINT, ?*const D3D11_BOX, *const anyopaque, UINT, UINT) callconv(.winapi) void,
    };
};

extern "d3d11" fn D3D11CreateDeviceAndSwapChain(
    pAdapter: ?*anyopaque,
    DriverType: UINT,
    Software: ?HMODULE,
    Flags: UINT,
    pFeatureLevels: ?[*]const UINT,
    FeatureLevels: UINT,
    SDKVersion: UINT,
    pSwapChainDesc: *const DXGI_SWAP_CHAIN_DESC,
    ppSwapChain: *?*IDXGISwapChain,
    ppDevice: *?*ID3D11Device,
    pFeatureLevel: ?*UINT,
    ppImmediateContext: *?*ID3D11DeviceContext,
) callconv(.winapi) HRESULT;

const IID_ID3D11Texture2D = windows.GUID{
    .Data1 = 0x6f15aaf2,
    .Data2 = 0xd208,
    .Data3 = 0x4e89,
    .Data4 = .{ 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c },
};

pub const Backend = struct {
    swap_chain: ?*IDXGISwapChain = null,
    device: ?*ID3D11Device = null,
    context: ?*ID3D11DeviceContext = null,
    backbuffer: ?*ID3D11Resource = null,
    width: i32,
    height: i32,
    hwnd: windows.HWND,

    pub fn init(hwnd: windows.HWND, width: i32, height: i32) !Backend {
        var swap_chain: ?*IDXGISwapChain = null;
        var device: ?*ID3D11Device = null;
        var context: ?*ID3D11DeviceContext = null;

        const desc = DXGI_SWAP_CHAIN_DESC{
            .BufferDesc = .{
                .Width = @intCast(width),
                .Height = @intCast(height),
                .RefreshRate = .{ .Numerator = 0, .Denominator = 1 },
                .Format = DXGI_FORMAT_B8G8R8A8_UNORM,
                .ScanlineOrdering = 0,
                .Scaling = 0,
            },
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT,
            .BufferCount = 2,
            .OutputWindow = hwnd,
            .Windowed = windows.TRUE,
            .SwapEffect = DXGI_SWAP_EFFECT_DISCARD,
            .Flags = 0,
        };

        const hr = D3D11CreateDeviceAndSwapChain(
            null,
            D3D_DRIVER_TYPE_HARDWARE,
            null,
            0,
            null,
            0,
            D3D11_SDK_VERSION,
            &desc,
            &swap_chain,
            &device,
            null,
            &context,
        );
        if (hr < 0 or swap_chain == null or device == null or context == null) {
            if (context) |ctx| releaseContext(ctx);
            if (device) |dev| releaseUnknown(@ptrCast(dev));
            if (swap_chain) |sc| _ = sc.lpVtbl.Release(sc);
            return error.D3D11PresentInitFailed;
        }

        var backend = Backend{
            .swap_chain = swap_chain,
            .device = device,
            .context = context,
            .backbuffer = null,
            .width = width,
            .height = height,
            .hwnd = hwnd,
        };
        try backend.acquireBackbuffer();
        return backend;
    }

    pub fn deinit(self: *Backend) void {
        if (self.backbuffer) |buffer| releaseUnknown(@ptrCast(buffer));
        if (self.context) |ctx| releaseContext(ctx);
        if (self.device) |dev| releaseUnknown(@ptrCast(dev));
        if (self.swap_chain) |sc| _ = sc.lpVtbl.Release(sc);
        self.* = undefined;
    }

    pub fn present(self: *Backend, bitmap: *const Bitmap, vsync: bool) !void {
        if (bitmap.width != self.width or bitmap.height != self.height) {
            try self.resize(bitmap.width, bitmap.height);
        }
        const ctx = self.context orelse return error.D3D11PresentContextMissing;
        const backbuffer = self.backbuffer orelse return error.D3D11PresentBackbufferMissing;
        ctx.lpVtbl.UpdateSubresource(
            ctx,
            backbuffer,
            0,
            null,
            bitmap.pixels.ptr,
            @as(UINT, @intCast(bitmap.width * @sizeOf(u32))),
            0,
        );
        const sc = self.swap_chain orelse return error.D3D11PresentSwapChainMissing;
        const hr = sc.lpVtbl.Present(sc, if (vsync) 1 else 0, 0);
        if (hr < 0) return error.D3D11PresentFailed;
    }

    pub fn resize(self: *Backend, width: i32, height: i32) !void {
        if (width <= 0 or height <= 0) return;
        if (self.backbuffer) |buffer| {
            releaseUnknown(@ptrCast(buffer));
            self.backbuffer = null;
        }
        const sc = self.swap_chain orelse return error.D3D11PresentSwapChainMissing;
        const hr = sc.lpVtbl.ResizeBuffers(sc, 0, @intCast(width), @intCast(height), DXGI_FORMAT_B8G8R8A8_UNORM, 0);
        if (hr < 0) return error.D3D11PresentResizeFailed;
        self.width = width;
        self.height = height;
        try self.acquireBackbuffer();
    }

    fn acquireBackbuffer(self: *Backend) !void {
        const sc = self.swap_chain orelse return error.D3D11PresentSwapChainMissing;
        var backbuffer: ?*anyopaque = null;
        const hr = sc.lpVtbl.GetBuffer(sc, 0, &IID_ID3D11Texture2D, &backbuffer);
        if (hr < 0 or backbuffer == null) return error.D3D11PresentBackbufferMissing;
        self.backbuffer = @ptrCast(@alignCast(backbuffer));
    }
};

fn releaseUnknown(ptr: *IUnknown) void {
    _ = ptr.lpVtbl.Release(ptr);
}

fn releaseContext(ctx: *ID3D11DeviceContext) void {
    _ = ctx.lpVtbl.Release(ctx);
}
