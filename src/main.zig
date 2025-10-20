//! # Main Entry Point
//!
//! This module orchestrates the application lifecycle:
//! 1. Initializes the window
//! 2. Sets up rendering
//! 3. Enters the event/message loop
//!
//! **Single Concern**: Application orchestration and event loop management
//!
//! **JavaScript Equivalent**:
//! ```javascript
//! // Initialize window and renderer
//! const window = new Window("Title", 800, 600);
//! const renderer = new Renderer(window.handle, 800, 600);
//! renderer.renderHelloWorld();
//!
//! // Event loop - like requestAnimationFrame or setInterval
//! while (true) {
//!   const msg = getNextMessage();
//!   if (!msg) break;
//!   handleMessage(msg);
//! }
//! ```

const std = @import("std");
const windows = std.os.windows;

// Windows message structure - contains information about a window event
// Similar to JavaScript event objects: { type, target, data, timestamp }
const MSG = extern struct {
    hwnd: windows.HWND, // Which window the message is for
    message: u32, // Type of message (WM_PAINT, WM_CLOSE, etc.)
    wParam: windows.WPARAM, // First parameter (event-specific data)
    lParam: windows.LPARAM, // Second parameter (event-specific data)
    time: u32, // When the message was generated (timestamp)
    pt: windows.POINT, // Mouse position when message occurred
};

// Windows API function declarations - these are the "system event handlers"
// Like addEventListener() but at the OS level
extern "user32" fn GetMessageW(
    lpMsg: *MSG,
    hWnd: ?windows.HWND,
    wMsgFilterMin: u32,
    wMsgFilterMax: u32,
) i32;

extern "user32" fn TranslateMessage(lpMsg: *const MSG) bool;

extern "user32" fn DispatchMessageW(lpMsg: *const MSG) windows.LRESULT;

// Import modules - each handles one specific concern
const Window = @import("window.zig").Window;
const Renderer = @import("renderer.zig").Renderer;

/// Application entry point
/// This is where Zig starts execution when the program runs
pub fn main() !void {
    // ========== INITIALIZATION PHASE ==========
    // Create a window - like document.createElement("canvas") in JavaScript
    // The 'defer' keyword ensures cleanup happens automatically when this scope ends
    // Similar to try/finally in JavaScript: resources are freed even if errors occur
    var window = try Window.init("Zig Windows Hello World", 800, 600);
    defer window.deinit();

    // Create a renderer - like getting a 2D context: canvas.getContext("2d")
    var renderer = try Renderer.init(window.hwnd, 800, 600);
    defer renderer.deinit();

    // ========== INITIAL RENDER PHASE ==========
    // Draw initial content - like drawing to canvas before the loop
    renderer.renderHelloWorld();

    // ========== EVENT LOOP PHASE ==========
    // The main event loop - this is like:
    // while (applicationRunning) { processUserInput(); render(); }
    // GetMessageW() blocks until a message arrives (like await)
    // Returns 0 when WM_QUIT is received, signaling app should exit
    var msg: MSG = undefined;
    while (GetMessageW(&msg, null, 0, 0) != 0) {
        // TranslateMessage handles keyboard input (like converting keycodes)
        _ = TranslateMessage(&msg);

        // DispatchMessageW sends the message to the appropriate window
        // This calls our WindowProc callback from window.zig
        _ = DispatchMessageW(&msg);
    }
}
