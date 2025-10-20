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

extern "user32" fn PeekMessageW(
    lpMsg: *MSG,
    hWnd: ?windows.HWND,
    wMsgFilterMin: u32,
    wMsgFilterMax: u32,
    wRemoveMsg: u32,
) i32;

extern "user32" fn TranslateMessage(lpMsg: *const MSG) bool;

extern "user32" fn DispatchMessageW(lpMsg: *const MSG) windows.LRESULT;

// PeekMessageW constants
const PM_REMOVE = 1;

// Windows Sleep function for frame pacing
extern "kernel32" fn Sleep(dwMilliseconds: u32) void;

// Import modules - each handles one specific concern
const Window = @import("window.zig").Window;
const Renderer = @import("renderer.zig").Renderer;
const Mesh = @import("mesh.zig").Mesh;

/// Application entry point
/// This is where Zig starts execution when the program runs
pub fn main() !void {
    // ========== INITIALIZATION PHASE ==========
    // Set up general-purpose allocator for dynamic memory
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a window - like document.createElement("canvas") in JavaScript
    // The 'defer' keyword ensures cleanup happens automatically when this scope ends
    // Similar to try/finally in JavaScript: resources are freed even if errors occur
    var window = try Window.init("Zig 3D CPU Rasterizer", 800, 600);
    defer window.deinit();

    // Create a renderer - like getting a 2D context: canvas.getContext("2d")
    var renderer = try Renderer.init(window.hwnd, 800, 600, allocator);
    defer renderer.deinit();

    // Create a 3D cube mesh
    var cube = try Mesh.cube(allocator);
    defer cube.deinit();

    // ========== EVENT LOOP PHASE ==========
    // Continuous rendering loop with frame rate limiting
    // Use PeekMessageW for non-blocking message processing
    // Frame rate limited to 120 FPS with proper pacing
    var msg: MSG = undefined;
    var running = true;
    while (running) {
        // Check for messages without blocking (PM_REMOVE = 1 means remove from queue)
        // PeekMessageW returns non-zero if there was a message to process
        if (PeekMessageW(&msg, null, 0, 0, PM_REMOVE) != 0) {
            // Check if it's a quit message
            if (msg.message == 0x12) { // WM_QUIT = 0x12
                running = false;
                break;
            }

            // Process the message
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }

        // Check if it's time to render a new frame (frame rate limiting)
        if (renderer.shouldRenderFrame()) {
            try renderer.render3DMesh(&cube);
        }
        // Note: No sleep - let it spin tight on frame checking
        // This gives smoother frame pacing than OS sleep granularity
    }
}
