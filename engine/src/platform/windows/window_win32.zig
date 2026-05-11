const std = @import("std");
const platform_types = @import("../types.zig");
const windows = std.os.windows;

pub const NativeHandle = windows.HWND;

pub const Window = struct {
    hwnd: windows.HWND,

    pub fn init(desc: platform_types.WindowDesc) !Window {
        const hinstance = GetModuleHandleW(null);
        ensureDpiAwarenessConfigured();

        var title_wide: [256:0]u16 = undefined;
        const title_len = std.unicode.utf8ToUtf16Le(&title_wide, desc.title) catch return error.InvalidTitle;
        title_wide[title_len] = 0;

        try ensureWindowClassRegistered(hinstance);

        var window_rect = windows.RECT{
            .left = 0,
            .top = 0,
            .right = desc.width,
            .bottom = desc.height,
        };
        if (AdjustWindowRectEx(&window_rect, WS_OVERLAPPEDWINDOW, windows.FALSE, 0) == 0) {
            return error.WindowCreationFailed;
        }

        const hwnd = CreateWindowExW(
            0,
            &CLASS_NAME_WIDE,
            &title_wide,
            WS_OVERLAPPEDWINDOW,
            100,
            100,
            window_rect.right - window_rect.left,
            window_rect.bottom - window_rect.top,
            null,
            null,
            hinstance,
            null,
        ) orelse return error.WindowCreationFailed;

        if (desc.visible) {
            _ = ShowWindow(hwnd, SW_SHOW);
            _ = UpdateWindow(hwnd);
            _ = SetForegroundWindow(hwnd);
            _ = SetFocus(hwnd);
        }

        return .{ .hwnd = hwnd };
    }

    pub fn deinit(self: *Window) void {
        if (IsWindow(self.hwnd) != 0) _ = DestroyWindow(self.hwnd);
    }

    pub fn setTitle(self: *const Window, title: []const u8) void {
        var title_wide: [512:0]u16 = undefined;
        const title_len = std.unicode.utf8ToUtf16Le(&title_wide, title) catch return;
        title_wide[title_len] = 0;
        _ = SetWindowTextW(self.hwnd, &title_wide);
    }
};

const WS_OVERLAPPEDWINDOW = 0xcf0000;
const SW_SHOW = 5;
const WM_DESTROY = 2;
const CLASS_NAME_WIDE = [_:0]u16{ 'Z', 'i', 'g', 'W', 'i', 'n', 'd', 'o', 'w', 'C', 'l', 'a', 's', 's' };
const ERROR_CLASS_ALREADY_EXISTS: u32 = 1410;

const WNDCLASSW = extern struct {
    style: u32,
    lpfnWndProc: *anyopaque,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: windows.HINSTANCE,
    hIcon: ?windows.HICON,
    hCursor: ?windows.HCURSOR,
    hbrBackground: ?windows.HBRUSH,
    lpszMenuName: ?[*:0]const u16,
    lpszClassName: ?[*:0]const u16,
};

extern "user32" fn RegisterClassW(lpWndClass: *const WNDCLASSW) u16;
extern "user32" fn CreateWindowExW(dwExStyle: u32, lpClassName: [*:0]const u16, lpWindowName: [*:0]const u16, dwStyle: u32, x: i32, y: i32, nWidth: i32, nHeight: i32, hWndParent: ?windows.HWND, hMenu: ?windows.HMENU, hInstance: windows.HINSTANCE, lpParam: ?*anyopaque) ?windows.HWND;
extern "user32" fn AdjustWindowRectEx(lpRect: *windows.RECT, dwStyle: u32, bMenu: windows.BOOL, dwExStyle: u32) windows.BOOL;
extern "user32" fn ShowWindow(hWnd: windows.HWND, nCmdShow: i32) i32;
extern "user32" fn UpdateWindow(hWnd: windows.HWND) i32;
extern "user32" fn DestroyWindow(hWnd: windows.HWND) i32;
extern "user32" fn PostQuitMessage(nExitCode: i32) void;
extern "user32" fn DefWindowProcW(hWnd: windows.HWND, Msg: u32, wParam: windows.WPARAM, lParam: windows.LPARAM) windows.LRESULT;
extern "user32" fn SetWindowTextW(hWnd: windows.HWND, lpString: [*:0]const u16) i32;
extern "user32" fn SetForegroundWindow(hWnd: windows.HWND) bool;
extern "user32" fn SetFocus(hWnd: windows.HWND) ?windows.HWND;
extern "user32" fn IsWindow(hWnd: windows.HWND) windows.BOOL;
extern "user32" fn SetProcessDPIAware() windows.BOOL;
extern "user32" fn SetProcessDpiAwarenessContext(value: ?*anyopaque) windows.BOOL;
extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const u16) windows.HINSTANCE;
extern "kernel32" fn GetLastError() windows.DWORD;

var window_class_registered = false;
var dpi_awareness_configured = false;
const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -4))));

export fn WindowProc(hwnd: windows.HWND, msg: u32, wParam: windows.WPARAM, lParam: windows.LPARAM) windows.LRESULT {
    return switch (msg) {
        WM_DESTROY => {
            PostQuitMessage(0);
            return 0;
        },
        else => DefWindowProcW(hwnd, msg, wParam, lParam),
    };
}

fn ensureWindowClassRegistered(hinstance: windows.HINSTANCE) !void {
    if (window_class_registered) return;

    var wc: WNDCLASSW = std.mem.zeroes(WNDCLASSW);
    wc.lpfnWndProc = @ptrCast(@constCast(&WindowProc));
    wc.hInstance = hinstance;
    wc.lpszClassName = &CLASS_NAME_WIDE;

    if (RegisterClassW(&wc) == 0 and GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        return error.ClassRegistrationFailed;
    }
    window_class_registered = true;
}

fn ensureDpiAwarenessConfigured() void {
    if (dpi_awareness_configured) return;
    dpi_awareness_configured = true;

    if (SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) != 0) return;
    _ = SetProcessDPIAware();
}
