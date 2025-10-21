//! # Main Entry Point: The Heart of the Application
//! 
//! This file is the equivalent of your `index.js` or the main script that kicks everything off.
//! It orchestrates the entire application lifecycle:
//! 1. **Initialization**: Sets up the application window and the renderer.
//! 2. **Event Loop**: Runs the main loop that processes user input and renders frames.
//! 3. **Cleanup**: Ensures all resources are freed when the application closes.
//! 
//! ## JavaScript Analogy
//! 
//! Think of this file as the top-level script in an HTML page.
//! 
//! ```javascript
//! // 1. Initialization
//! const canvas = document.createElement('canvas');
//! const renderer = new Renderer(canvas);
//! 
//! // 2. Event Loop (simplified)
//! function gameLoop() {
//!   const events = getPendingUserEvents(); // e.g., keyboard, mouse
//!   processEvents(events);
//!   renderer.renderScene();
//!   requestAnimationFrame(gameLoop);
//! }
//! 
//! // 3. Start the loop
//! requestAnimationFrame(gameLoop);
//! ```
//! 
const std = @import("std");
const windows = std.os.windows;
const math = @import("math.zig");

// Windows message structure.
// JS Analogy: This is the raw event object from the operating system. A browser
// would normally process this and give you a cleaner `KeyboardEvent` or `MouseEvent`.
const MSG = extern struct {
    hwnd: windows.HWND, // The window handle this message is for.
    message: u32, // The type of message (e.g., WM_KEYDOWN, WM_CLOSE).
    wParam: windows.WPARAM, // Extra event-specific data. For keyboard events, this is the key code.
    lParam: windows.LPARAM, // More event-specific data.
    time: u32, // Timestamp of when the event occurred.
    pt: windows.POINT, // Mouse position when the event occurred.
};

// Windows message type constants.
const WM_KEYDOWN = 0x0100;
const WM_KEYUP = 0x0101;
const WM_CHAR = 0x0102;
const WM_QUIT = 0x12;
const WM_MOUSEMOVE = 0x0200;

// Declarations for Windows API functions.
// JS Analogy: These are low-level functions to interact with the OS event queue.
// Think of them as the underlying native functions a browser's JS engine would call
// to handle events, but here we are calling them directly.
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

// Constant for PeekMessageW: remove the message from the queue after reading.
const PM_REMOVE = 1;

// Windows Sleep function for frame pacing.
extern "kernel32" fn Sleep(dwMilliseconds: u32) void;

// Import other modules from our project.
// JS Analogy: `const Window = require('./window.js');`
const Window = @import("window.zig").Window;
const Renderer = @import("renderer.zig").Renderer;
const obj_loader = @import("obj_loader.zig");
const config = @import("app_config.zig");

/// # Application Entry Point
/// This `main` function is where the program execution begins.
/// JS Analogy: Think of this as an `async function main() { ... }` that is called
/// as soon as the script loads. The `!void` means it can return an error but
/// doesn't return a value on success.
pub fn main() !void {
    // ========== INITIALIZATION PHASE ========== 

    // Set up a general-purpose allocator for dynamic memory.
    // JS Analogy: JavaScript has a garbage collector that manages memory for you.
    // In Zig, you often manage memory manually. This line gets us a "tool" for
    // allocating and freeing memory.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // `defer` is like a `finally` block for a specific line. This guarantees
    // that `gpa.deinit()` is called at the end of the `main` function, cleaning up the allocator.
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a window.
    // JS Analogy: `const window = new Window(800, 600);`
    // The `try` keyword is like `await` for a function that might fail. If `Window.init`
    // returns an error, `main` will immediately stop and report the error.
    var window = try Window.init(config.WINDOW_TITLE, 800, 600);
    defer window.deinit(); // Guarantees the window is destroyed on exit.

    // Create a renderer.
    // JS Analogy: `const renderer = canvas.getContext('2d');`
    var renderer = try Renderer.init(window.hwnd, 800, 600, allocator);
    defer renderer.deinit(); // Guarantees the renderer is cleaned up on exit.

    // Load a 3D model from an .obj file.
    var teapot = try obj_loader.load(allocator, "resources/models/teapot.onj");
    defer teapot.deinit(); // Guarantees the mesh memory is freed on exit.
    teapot.centerToOrigin(); // Center the model at (0,0,0).

    renderer.setCameraPosition(math.Vec3.new(0.0, 2.0, -10.0));
    renderer.setCameraOrientation(-0.1, 0.0);

    // ========== EVENT LOOP PHASE ========== 

    // This is the main application loop, similar to `requestAnimationFrame` in JS.
    // We use `PeekMessageW` for a non-blocking loop, which allows us to render
    // frames continuously even if there are no new user input events.
    var running = true;

    std.debug.print("Starting main event loop...\n", .{});

    // The MessagePump is a helper for processing all pending OS events.
    // JS Analogy: This is like the internal logic a browser runs between frames
    // to handle all queued user inputs.
    const MessagePump = struct {
        fn decodeMouseCoords(lParam: windows.LPARAM) windows.POINT {
            const raw: usize = @bitCast(lParam);
            const x16: u16 = @intCast(raw & 0xFFFF);
            const y16: u16 = @intCast((raw >> 16) & 0xFFFF);
            const x_component: i16 = @bitCast(x16);
            const y_component: i16 = @bitCast(y16);
            return windows.POINT{
                .x = @intCast(x_component),
                .y = @intCast(y_component),
            };
        }

        fn pump(r: *Renderer) bool {
            var m: MSG = undefined;
            // Process all pending messages in the queue without blocking.
            while (PeekMessageW(&m, null, 0, 0, PM_REMOVE) != 0) {
                // If we get a quit message, signal the main loop to exit.
                if (m.message == WM_QUIT) {
                    std.debug.print("Received WM_QUIT message, exiting\n", .{});
                    return false; // Signal to exit.
                }

                // Handle keyboard input directly for maximum responsiveness.
                if (m.message == WM_KEYDOWN) {
                    const key_code: u32 = @intCast(m.wParam);
                    r.handleKeyInput(key_code, true);
                } else if (m.message == WM_KEYUP) {
                    const key_code: u32 = @intCast(m.wParam);
                    r.handleKeyInput(key_code, false);
                } else if (m.message == WM_CHAR) {
                    const char_code: u32 = @intCast(m.wParam);
                    r.handleCharInput(char_code);
                } else if (m.message == WM_MOUSEMOVE) {
                    const coords = decodeMouseCoords(m.lParam);
                    r.handleMouseMove(coords.x, coords.y);
                }

                // These two functions are part of the standard Windows message handling.
                // `TranslateMessage` converts key presses into character messages.
                // `DispatchMessageW` sends the message to our main window handler (`WindowProc`).
                _ = TranslateMessage(&m);
                _ = DispatchMessageW(&m);
            }
            return true; // Continue running.
        }
    };

    var frame_count: u32 = 0;
    // The main event loop.
    // JS Analogy: `while(true)` combined with `requestAnimationFrame`.
    while (running) {
        // First, process all pending user input and window events.
        if (!MessagePump.pump(&renderer)) {
            std.debug.print("MessagePump returned false, exiting main loop\n", .{});
            running = false;
            break;
        }

        // Check if it's time to render a new frame, based on our target FPS.
        if (renderer.shouldRenderFrame()) {
            frame_count += 1;
            if (frame_count <= 3) {
                std.debug.print("Rendering frame {}\n", .{frame_count});
            }
            // This is the main drawing call.
            // JS Analogy: `renderer.renderScene(scene);` inside a `requestAnimationFrame` callback.
            renderer.render3DMeshWithPump(&teapot, MessagePump.pump) catch |err| {
                // If rendering fails, log the error and exit the loop.
                if (err == error.RenderInterrupted) {
                    std.debug.print("Render interrupted by shutdown request\n", .{});
                } else {
                    std.debug.print("ERROR during rendering: {}\n", .{err});
                }
                running = false;
                break;
            };
            if (frame_count <= 3) {
                std.debug.print("Frame {} complete\n", .{frame_count});
            }
        }

        // Yield to the OS. This prevents our app from using 100% CPU if it's running
        // faster than the target frame rate.
        // JS Analogy: `setTimeout(0)` - hints to the OS to run other processes.
        Sleep(0);
    }

    std.debug.print("Exited main loop after {} frames\n", .{frame_count});
}