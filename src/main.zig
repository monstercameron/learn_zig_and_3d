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

// Windows message constants
const WM_KEYDOWN = 0x0100;
const WM_KEYUP = 0x0101;
const WM_QUIT = 0x12;

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

    // Create a cube mesh with backface culling
    var cube = try Mesh.cube(allocator);
    defer cube.deinit();

    // ========== EVENT LOOP PHASE ==========
    // Continuous rendering loop with frame rate limiting
    // Use PeekMessageW for non-blocking message processing
    // Input handling runs at ~120Hz, rendering is decoupled
    var running = true;

    std.debug.print("Starting main event loop...\n", .{});

    // Message pump function that can be called during rendering
    const MessagePump = struct {
        fn pump(r: *Renderer) bool {
            var m: MSG = undefined;
            var pumped_any = false;
            // Process all pending messages without blocking
            while (PeekMessageW(&m, null, 0, 0, PM_REMOVE) != 0) {
                pumped_any = true;

                // Check if it's a quit message
                if (m.message == WM_QUIT) {
                    std.debug.print("Received WM_QUIT message, exiting\n", .{});
                    return false; // Signal to exit
                }

                // Handle keyboard input at full speed
                if (m.message == WM_KEYDOWN) {
                    const key_code: u32 = @intCast(m.wParam);
                    r.handleKeyInput(key_code, true);
                } else if (m.message == WM_KEYUP) {
                    const key_code: u32 = @intCast(m.wParam);
                    r.handleKeyInput(key_code, false);
                }

                // Process the message
                _ = TranslateMessage(&m);
                _ = DispatchMessageW(&m);
            }
            return true; // Continue running
        }
    };

    var frame_count: u32 = 0;
    while (running) {
        // Process messages at high frequency
        if (!MessagePump.pump(&renderer)) {
            std.debug.print("MessagePump returned false, exiting main loop\n", .{});
            running = false;
            break;
        }

        // Check if it's time to render a new frame (frame rate limiting)
        if (renderer.shouldRenderFrame()) {
            frame_count += 1;
            if (frame_count <= 3) {
                std.debug.print("Rendering frame {}\n", .{frame_count});
            }
            renderer.render3DMeshWithPump(&cube, MessagePump.pump) catch |err| {
                std.debug.print("ERROR during rendering: {}\n", .{err});
                running = false;
                break;
            };
            if (frame_count <= 3) {
                std.debug.print("Frame {} complete\n", .{frame_count});
            }
        }

        // Small sleep to prevent 100% CPU usage when idle
        Sleep(1);
    }

    std.debug.print("Exited main loop after {} frames\n", .{frame_count});
}
