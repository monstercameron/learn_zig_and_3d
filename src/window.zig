const std = @import("std");
const windows = std.os.windows;

const WS_OVERLAPPEDWINDOW = 0xcf0000;
const SW_SHOW = 5;
const WM_DESTROY = 2;
const WM_CLOSE = 16;
const WM_PAINT = 15;

const CLASS_NAME_WIDE = [_:0]u16{ 'Z', 'i', 'g', 'W', 'i', 'n', 'd', 'o', 'w', 'C', 'l', 'a', 's', 's' };

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
extern "user32" fn ShowWindow(hWnd: windows.HWND, nCmdShow: i32) i32;
extern "user32" fn UpdateWindow(hWnd: windows.HWND) i32;
extern "user32" fn DestroyWindow(hWnd: windows.HWND) i32;
extern "user32" fn PostQuitMessage(nExitCode: i32) void;
extern "user32" fn DefWindowProcW(hWnd: windows.HWND, Msg: u32, wParam: windows.WPARAM, lParam: windows.LPARAM) windows.LRESULT;
extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const u16) windows.HINSTANCE;

// Window procedure wrapped to match what Windows expects
export fn WindowProc(hwnd: windows.HWND, msg: u32, wParam: windows.WPARAM, lParam: windows.LPARAM) windows.LRESULT {
    return switch (msg) {
        WM_DESTROY => {
            PostQuitMessage(0);
            return 0;
        },
        WM_CLOSE => {
            PostQuitMessage(0);
            return 0;
        },
        else => DefWindowProcW(hwnd, msg, wParam, lParam),
    };
}

pub const Window = struct {
    hwnd: windows.HWND,

    pub fn init(title: []const u8, width: i32, height: i32) !Window {
        var title_wide: [256:0]u16 = undefined;
        const title_len = std.unicode.utf8ToUtf16Le(&title_wide, title) catch return error.InvalidTitle;
        title_wide[title_len] = 0;

        const hinstance = GetModuleHandleW(null);

        var wc: WNDCLASSW = undefined;
        wc.style = 0;
        wc.lpfnWndProc = @ptrCast(@constCast(&WindowProc));
        wc.cbClsExtra = 0;
        wc.cbWndExtra = 0;
        wc.hInstance = hinstance;
        wc.hIcon = null;
        wc.hCursor = null;
        wc.hbrBackground = null;
        wc.lpszMenuName = null;
        wc.lpszClassName = &CLASS_NAME_WIDE;

        if (RegisterClassW(&wc) == 0) {
            std.debug.print("RegisterClassW failed\n", .{});
            return error.ClassRegistrationFailed;
        }

        std.debug.print("RegisterClassW succeeded\n", .{});

        const hwnd = CreateWindowExW(0, &CLASS_NAME_WIDE, &title_wide, WS_OVERLAPPEDWINDOW, 100, 100, width, height, null, null, hinstance, null) orelse {
            std.debug.print("CreateWindowExW failed\n", .{});
            return error.WindowCreationFailed;
        };

        _ = ShowWindow(hwnd, SW_SHOW);
        _ = UpdateWindow(hwnd);

        return Window{ .hwnd = hwnd };
    }

    pub fn deinit(self: *Window) void {
        _ = DestroyWindow(self.hwnd);
    }
};
