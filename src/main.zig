// src/main.zig - Main entry point for the Zig Windows API application
// This file initializes the application, creates a window, sets up rendering,
// and enters the message loop to handle user input and drawing.

const std = @import("std");
const windows = std.os.windows;

// Define MSG type
const MSG = extern struct {
    hwnd: windows.HWND,
    message: u32,
    wParam: windows.WPARAM,
    lParam: windows.LPARAM,
    time: u32,
    pt: windows.POINT,
};

// Extern declarations
extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: ?windows.HWND, wMsgFilterMin: u32, wMsgFilterMax: u32) i32;
extern "user32" fn TranslateMessage(lpMsg: *const MSG) bool;
extern "user32" fn DispatchMessageW(lpMsg: *const MSG) windows.LRESULT;
const gdi32 = windows.gdi32;

// Import our custom modules for window and rendering
const Window = @import("window.zig").Window;
const Renderer = @import("renderer.zig").Renderer;

pub fn main() !void {
    // Initialize the window with a title and size
    var window = try Window.init("Zig Windows Hello World", 800, 600);
    defer window.deinit(); // Ensure window is properly cleaned up

    // Create a renderer that will handle bitmap creation and drawing
    var renderer = try Renderer.init(window.hwnd, 800, 600);
    defer renderer.deinit();

    // Render a simple "Hello World" by filling the bitmap with a color
    renderer.renderHelloWorld();

    // Enter the main message loop to process Windows messages
    var msg: MSG = undefined;
    while (GetMessageW(&msg, null, 0, 0) != 0) {
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }
}
