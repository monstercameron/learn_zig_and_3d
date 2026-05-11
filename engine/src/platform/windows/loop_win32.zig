const std = @import("std");
const platform_types = @import("../types.zig");
const window_module = @import("../window.zig");
const log = @import("../../core/log.zig");

const windows = std.os.windows;
const platform_logger = log.get("platform.loop");

pub fn registerRawMouseInput(hwnd: window_module.NativeHandle) !void {
    const device = RAWINPUTDEVICE{
        .usUsagePage = HID_USAGE_PAGE_GENERIC,
        .usUsage = HID_USAGE_GENERIC_MOUSE,
        .dwFlags = 0,
        .hwndTarget = hwnd,
    };
    if (RegisterRawInputDevices(@ptrCast(&device), 1, @sizeOf(RAWINPUTDEVICE)) == 0) {
        return error.RawInputRegistrationFailed;
    }
}

pub fn setCursor(style: platform_types.CursorStyle) void {
    switch (style) {
        .hidden => _ = SetCursor(null),
        else => {
            const cursor_id: usize = switch (style) {
                .arrow => IDC_ARROW_ID,
                .grab => IDC_HAND_ID,
                .grabbing => IDC_SIZEALL_ID,
                .hidden => unreachable,
            };
            const cursor = LoadCursorW(null, cursorResource(cursor_id));
            _ = SetCursor(cursor);
        },
    }
}

pub fn windowHasFocus(hwnd: window_module.NativeHandle) bool {
    return if (GetFocus()) |focused_hwnd| focused_hwnd == hwnd else false;
}

pub fn setMouseCapture(hwnd: window_module.NativeHandle, enabled: bool) void {
    if (enabled) {
        _ = SetCapture(hwnd);
    } else {
        _ = ReleaseCapture();
    }
}

pub fn centerCursorInWindow(hwnd: window_module.NativeHandle) void {
    var rect: windows.RECT = undefined;
    if (GetClientRect(hwnd, &rect) == 0) return;
    var point = windows.POINT{
        .x = @divTrunc(rect.right - rect.left, 2),
        .y = @divTrunc(rect.bottom - rect.top, 2),
    };
    if (ClientToScreen(hwnd, &point) == 0) return;
    _ = SetCursorPos(point.x, point.y);
}

pub fn pumpEvents(ctx: anytype, comptime Hooks: type) bool {
    var m: MSG = undefined;
    while (PeekMessageW(&m, null, 0, 0, PM_REMOVE) != 0) {
        if (m.message == WM_QUIT) {
            platform_logger.info("received WM_QUIT message, exiting", .{});
            Hooks.handleEvent(ctx, .quit);
            return false;
        }
        if (translateMessageToEvent(m)) |event| {
            Hooks.handleEvent(ctx, event);
        }
        _ = TranslateMessage(&m);
        _ = DispatchMessageW(&m);
    }
    return true;
}

const MSG = extern struct {
    hwnd: windows.HWND,
    message: u32,
    wParam: windows.WPARAM,
    lParam: windows.LPARAM,
    time: u32,
    pt: windows.POINT,
};

const RAWINPUTDEVICE = extern struct {
    usUsagePage: u16,
    usUsage: u16,
    dwFlags: u32,
    hwndTarget: ?windows.HWND,
};

const RAWINPUTHEADER = extern struct {
    dwType: u32,
    dwSize: u32,
    hDevice: ?windows.HANDLE,
    wParam: windows.WPARAM,
};

const RAWMOUSE_BUTTONS = extern union {
    ulButtons: u32,
    buttons: extern struct {
        usButtonFlags: u16,
        usButtonData: u16,
    },
};

const RAWMOUSE = extern struct {
    usFlags: u16,
    buttons: RAWMOUSE_BUTTONS,
    ulRawButtons: u32,
    lLastX: i32,
    lLastY: i32,
    ulExtraInformation: u32,
};

const RAWINPUTMOUSE = extern struct {
    header: RAWINPUTHEADER,
    mouse: RAWMOUSE,
};

extern "user32" fn PeekMessageW(lpMsg: *MSG, hWnd: ?windows.HWND, wMsgFilterMin: u32, wMsgFilterMax: u32, wRemoveMsg: u32) i32;
extern "user32" fn TranslateMessage(lpMsg: *const MSG) bool;
extern "user32" fn DispatchMessageW(lpMsg: *const MSG) windows.LRESULT;
extern "user32" fn RegisterRawInputDevices(pRawInputDevices: [*]const RAWINPUTDEVICE, uiNumDevices: u32, cbSize: u32) windows.BOOL;
extern "user32" fn GetRawInputData(hRawInput: ?windows.HANDLE, uiCommand: u32, pData: ?*anyopaque, pcbSize: *u32, cbSizeHeader: u32) u32;
extern "user32" fn LoadCursorW(hInstance: ?windows.HINSTANCE, lpCursorName: [*:0]align(1) const u16) ?windows.HCURSOR;
extern "user32" fn SetCapture(hWnd: windows.HWND) ?windows.HWND;
extern "user32" fn ReleaseCapture() windows.BOOL;
extern "user32" fn GetFocus() ?windows.HWND;
extern "user32" fn SetCursor(hCursor: ?windows.HCURSOR) ?windows.HCURSOR;
extern "user32" fn GetClientRect(hWnd: windows.HWND, lpRect: *windows.RECT) windows.BOOL;
extern "user32" fn ClientToScreen(hWnd: windows.HWND, lpPoint: *windows.POINT) windows.BOOL;
extern "user32" fn SetCursorPos(X: i32, Y: i32) windows.BOOL;

const PM_REMOVE = 1;
const WM_KEYDOWN = 0x0100;
const WM_KEYUP = 0x0101;
const WM_SYSKEYDOWN = 0x0104;
const WM_SYSKEYUP = 0x0105;
const WM_CHAR = 0x0102;
const WM_QUIT = 0x12;
const WM_SETFOCUS = 0x0007;
const WM_KILLFOCUS = 0x0008;
const WM_INPUT = 0x00FF;
const WM_MOUSEMOVE = 0x0200;
const WM_LBUTTONDOWN = 0x0201;
const WM_LBUTTONUP = 0x0202;
const WM_RBUTTONDOWN = 0x0204;
const WM_RBUTTONUP = 0x0205;
const WM_SIZE = 0x0005;
const WM_CLOSE = 0x0010;
const SIZE_MINIMIZED: usize = 1;
const SIZE_RESTORED: usize = 0;
const MK_LBUTTON: usize = 0x0001;
const MK_RBUTTON: usize = 0x0002;
const IDC_ARROW_ID: usize = 32512;
const IDC_SIZEALL_ID: usize = 32646;
const IDC_HAND_ID: usize = 32649;
const RID_INPUT: u32 = 0x10000003;
const RIM_TYPEMOUSE: u32 = 0;
const MOUSE_MOVE_ABSOLUTE: u16 = 0x0001;
const HID_USAGE_PAGE_GENERIC: u16 = 0x01;
const HID_USAGE_GENERIC_MOUSE: u16 = 0x02;

fn cursorResource(id: usize) [*:0]align(1) const u16 {
    return @ptrFromInt(id);
}

fn decodeRawMouseDelta(lParam: windows.LPARAM) ?windows.POINT {
    var raw_input: RAWINPUTMOUSE = undefined;
    var size: u32 = @sizeOf(RAWINPUTMOUSE);
    const handle: ?windows.HANDLE = @ptrFromInt(@as(usize, @bitCast(lParam)));
    const copied = GetRawInputData(handle, RID_INPUT, @ptrCast(&raw_input), &size, @sizeOf(RAWINPUTHEADER));
    if (copied == std.math.maxInt(u32) or copied < @sizeOf(RAWINPUTHEADER)) return null;
    if (raw_input.header.dwType != RIM_TYPEMOUSE) return null;
    if ((raw_input.mouse.usFlags & MOUSE_MOVE_ABSOLUTE) != 0) return null;
    if (raw_input.mouse.lLastX == 0 and raw_input.mouse.lLastY == 0) return null;
    return windows.POINT{ .x = raw_input.mouse.lLastX, .y = raw_input.mouse.lLastY };
}

fn decodeMouseCoords(lParam: windows.LPARAM) windows.POINT {
    const raw: usize = @bitCast(lParam);
    const x16: u16 = @intCast(raw & 0xFFFF);
    const y16: u16 = @intCast((raw >> 16) & 0xFFFF);
    const x_component: i16 = @bitCast(x16);
    const y_component: i16 = @bitCast(y16);
    return windows.POINT{ .x = @intCast(x_component), .y = @intCast(y_component) };
}

fn translateMessageToEvent(message: MSG) ?platform_types.PlatformEvent {
    if (message.message == WM_KEYDOWN or message.message == WM_SYSKEYDOWN) {
        return .{ .key = .{ .code = @intCast(message.wParam), .is_down = true } };
    }
    if (message.message == WM_KEYUP or message.message == WM_SYSKEYUP) {
        return .{ .key = .{ .code = @intCast(message.wParam), .is_down = false } };
    }
    if (message.message == WM_CHAR) return .{ .char = @intCast(message.wParam) };
    if (message.message == WM_SETFOCUS) return .{ .focus_changed = true };
    if (message.message == WM_KILLFOCUS) return .{ .focus_changed = false };
    if (message.message == WM_CLOSE) return .close_requested;
    if (message.message == WM_SIZE) {
        const raw: usize = @bitCast(message.lParam);
        const width: i32 = @intCast(raw & 0xFFFF);
        const height: i32 = @intCast((raw >> 16) & 0xFFFF);
        const size_kind: usize = @intCast(message.wParam);
        if (size_kind == SIZE_MINIMIZED) return .minimized;
        if (size_kind == SIZE_RESTORED) return .restored;
        return .{ .resized = .{ .width = width, .height = height } };
    }
    if (message.message == WM_INPUT) {
        if (decodeRawMouseDelta(message.lParam)) |delta| {
            return .{ .raw_mouse_delta = .{ .x = delta.x, .y = delta.y } };
        }
        return null;
    }
    if (message.message == WM_MOUSEMOVE) {
        const coords = decodeMouseCoords(message.lParam);
        const button_mask: usize = @intCast(message.wParam);
        return .{ .mouse_move = .{
            .x = coords.x,
            .y = coords.y,
            .left_down = (button_mask & MK_LBUTTON) != 0,
            .right_down = (button_mask & MK_RBUTTON) != 0,
        } };
    }
    if (message.message == WM_LBUTTONDOWN or message.message == WM_LBUTTONUP) {
        const coords = decodeMouseCoords(message.lParam);
        return .{ .mouse_button = .{
            .button = .left,
            .pressed = message.message == WM_LBUTTONDOWN,
            .x = coords.x,
            .y = coords.y,
        } };
    }
    if (message.message == WM_RBUTTONDOWN or message.message == WM_RBUTTONUP) {
        const coords = decodeMouseCoords(message.lParam);
        return .{ .mouse_button = .{
            .button = .right,
            .pressed = message.message == WM_RBUTTONDOWN,
            .x = coords.x,
            .y = coords.y,
        } };
    }
    return null;
}

test "translate key messages into typed platform events" {
    const msg = MSG{
        .hwnd = null,
        .message = WM_KEYDOWN,
        .wParam = 0x41,
        .lParam = 0,
        .time = 0,
        .pt = .{ .x = 0, .y = 0 },
    };
    const event = translateMessageToEvent(msg) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualDeep(platform_types.PlatformEvent{ .key = .{ .code = 0x41, .is_down = true } }, event);
}

test "translate resize messages into typed platform events" {
    const packed_wh: usize = 640 | (480 << 16);
    const msg = MSG{
        .hwnd = null,
        .message = WM_SIZE,
        .wParam = 2,
        .lParam = @bitCast(packed_wh),
        .time = 0,
        .pt = .{ .x = 0, .y = 0 },
    };
    const event = translateMessageToEvent(msg) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualDeep(platform_types.PlatformEvent{ .resized = .{ .width = 640, .height = 480 } }, event);
}

test "translate focus loss into lifecycle event" {
    const msg = MSG{
        .hwnd = null,
        .message = WM_KILLFOCUS,
        .wParam = 0,
        .lParam = 0,
        .time = 0,
        .pt = .{ .x = 0, .y = 0 },
    };
    const event = translateMessageToEvent(msg) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualDeep(platform_types.PlatformEvent{ .focus_changed = false }, event);
}

test "translate close request into lifecycle event" {
    const msg = MSG{
        .hwnd = null,
        .message = WM_CLOSE,
        .wParam = 0,
        .lParam = 0,
        .time = 0,
        .pt = .{ .x = 0, .y = 0 },
    };
    const event = translateMessageToEvent(msg) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualDeep(platform_types.PlatformEvent.close_requested, event);
}
