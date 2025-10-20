//! # Window Management Module
//!
//! This module handles all window creation and life*cycle management.
//!
//! **Single Concern**: Creating, displaying, and managing a native Windows window
//!
//! **JavaScript Equivalent**:
//! ```javascript
//! // Creating a window in JavaScript doesn't exist natively (browser context)
//! // But conceptually it's like:
//! class Window {
//!   constructor(title, width, height) {
//!     this.hwnd = OS.createWindow(title, width, height);
//!     this.show();
//!   }
//!
//!   // Event handler like: window.addEventListener('close')
//!   static onWindowMessage(hwnd, msgType, wParam, lParam) {
//!     if (msgType === 'DESTROY') {
//!       OS.postQuitMessage(0);
//!     }
//!   }
//! }
//! ```

const std = @import("std");
const windows = std.os.windows;

// ========== CONSTANTS ==========
// Window style flags - control window appearance and behavior
const WS_OVERLAPPEDWINDOW = 0xcf0000; // Standard window: title bar, menu, borders, etc.
const SW_SHOW = 5; // Show command for ShowWindow()
const WM_DESTROY = 2; // Message: window is being destroyed
const WM_CLOSE = 16; // Message: close button clicked

// Window class name - UTF-16 null-terminated string
// This is a unique identifier for our window class
// Similar to custom HTML elements or CSS class names
const CLASS_NAME_WIDE = [_:0]u16{ 'Z', 'i', 'g', 'W', 'i', 'n', 'd', 'o', 'w', 'C', 'l', 'a', 's', 's' };

// ========== WINDOWS API STRUCTURES ==========
// WNDCLASSW - Defines properties of a window class
// Like a blueprint/template for creating windows
// Similar to a CSS class defining styles and behavior
const WNDCLASSW = extern struct {
    style: u32, // Visual style flags (e.g., redraw behavior)
    lpfnWndProc: *anyopaque, // Pointer to message handler function (the callback)
    cbClsExtra: i32, // Extra memory for class (usually 0)
    cbWndExtra: i32, // Extra memory for each window (usually 0)
    hInstance: windows.HINSTANCE, // Module handle (which app instance)
    hIcon: ?windows.HICON, // Window icon image
    hCursor: ?windows.HCURSOR, // Mouse cursor shape
    hbrBackground: ?windows.HBRUSH, // Background color brush
    lpszMenuName: ?[*:0]const u16, // Menu resource name
    lpszClassName: ?[*:0]const u16, // Class name (our identifier)
};

// ========== WINDOWS API DECLARATIONS ==========
// These are declarations to Windows system functions
// Like importing from "windows.dll"

/// Register a window class - must be done before creating any windows
/// Returns a class atom (unique ID) on success, 0 on failure
extern "user32" fn RegisterClassW(lpWndClass: *const WNDCLASSW) u16;

/// Create a window instance from a registered class
/// Returns window handle (pointer) on success, null on failure
extern "user32" fn CreateWindowExW(
    dwExStyle: u32,
    lpClassName: [*:0]const u16,
    lpWindowName: [*:0]const u16,
    dwStyle: u32,
    x: i32,
    y: i32,
    nWidth: i32,
    nHeight: i32,
    hWndParent: ?windows.HWND,
    hMenu: ?windows.HMENU,
    hInstance: windows.HINSTANCE,
    lpParam: ?*anyopaque,
) ?windows.HWND;

/// Show a window (make it visible on screen)
extern "user32" fn ShowWindow(hWnd: windows.HWND, nCmdShow: i32) i32;

/// Update the window (force redraw)
extern "user32" fn UpdateWindow(hWnd: windows.HWND) i32;

/// Destroy a window and free its resources
extern "user32" fn DestroyWindow(hWnd: windows.HWND) i32;

/// Post a quit message to exit the event loop
extern "user32" fn PostQuitMessage(nExitCode: i32) void;

/// Default window message handler - called for any messages we don't handle
extern "user32" fn DefWindowProcW(
    hWnd: windows.HWND,
    Msg: u32,
    wParam: windows.WPARAM,
    lParam: windows.LPARAM,
) windows.LRESULT;

/// Get the application instance handle
extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const u16) windows.HINSTANCE;

/// Set the window title text
extern "user32" fn SetWindowTextW(hWnd: windows.HWND, lpString: [*:0]const u16) i32;

// Message constants
const WM_KEYDOWN = 0x0100;
const WM_KEYUP = 0x0101;

// Virtual key codes
const VK_LEFT = 0x25;
const VK_RIGHT = 0x27;
const VK_ESCAPE = 0x1B;

// ========== WINDOW MESSAGE HANDLER ==========
/// This is the callback function that receives all window messages
/// Similar to addEventListener() callback in JavaScript
/// Called by Windows whenever something happens (clicks, closes, repaints, etc.)
/// The 'export' keyword makes it visible to the Windows API (C calling convention)
export fn WindowProc(
    hwnd: windows.HWND,
    msg: u32,
    wParam: windows.WPARAM,
    lParam: windows.LPARAM,
) windows.LRESULT {
    return switch (msg) {
        // User clicked the close button or Alt+F4
        WM_CLOSE => {
            // Post a quit message to exit gracefully
            PostQuitMessage(0);
            return 0;
        },
        // Window is being destroyed
        WM_DESTROY => {
            PostQuitMessage(0);
            return 0;
        },
        // Keyboard key pressed
        WM_KEYDOWN => {
            const vkey = wParam;
            // ESC key exits the program
            if (vkey == VK_ESCAPE) {
                PostQuitMessage(0);
                return 0;
            }
            // Let the default handler process all other keys (will send to main loop)
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        },
        // Any other message - use default handling
        else => DefWindowProcW(hwnd, msg, wParam, lParam),
    };
}

// ========== WINDOW STRUCT ==========
/// Encapsulates window management
/// Like a class in JavaScript: window.close() would be Window.deinit()
pub const Window = struct {
    hwnd: windows.HWND, // Handle to the window - like a reference/ID

    /// Initialize a new window
    /// Similar to: new Window(title, width, height) in JavaScript
    pub fn init(title: []const u8, width: i32, height: i32) !Window {
        // ===== STEP 1: Convert title to UTF-16 =====
        // Windows APIs require UTF-16 (wide character) strings
        // JavaScript strings are UTF-16 internally, so this is automatic in JS
        var title_wide: [256:0]u16 = undefined;
        const title_len = std.unicode.utf8ToUtf16Le(&title_wide, title) catch return error.InvalidTitle;
        title_wide[title_len] = 0; // Null-terminate the string

        // ===== STEP 2: Get application instance =====
        // Every application needs a reference to itself
        // Like globalThis in JavaScript or window in browser
        const hinstance = GetModuleHandleW(null);

        // ===== STEP 3: Register window class =====
        // Define what our window looks like and behaves like
        // This is a one-time setup - like defining a custom element
        var wc: WNDCLASSW = undefined;
        wc.style = 0;
        wc.lpfnWndProc = @ptrCast(@constCast(&WindowProc)); // Point to our message handler
        wc.cbClsExtra = 0;
        wc.cbWndExtra = 0;
        wc.hInstance = hinstance;
        wc.hIcon = null;
        wc.hCursor = null;
        wc.hbrBackground = null;
        wc.lpszMenuName = null;
        wc.lpszClassName = &CLASS_NAME_WIDE;

        // Register the class
        if (RegisterClassW(&wc) == 0) {
            return error.ClassRegistrationFailed;
        }

        // ===== STEP 4: Create the window =====
        // Now that we have a class defined, instantiate a window from it
        // Like: const elem = document.createElement("div")
        const hwnd = CreateWindowExW(
            0, // Extended window style
            &CLASS_NAME_WIDE, // Use our registered class
            &title_wide, // Window title
            WS_OVERLAPPEDWINDOW, // Standard window style
            100, // X position
            100, // Y position
            width, // Width
            height, // Height
            null, // No parent window
            null, // No menu
            hinstance, // Application instance
            null, // Extra parameters
        ) orelse {
            return error.WindowCreationFailed;
        };

        // ===== STEP 5: Show the window =====
        // Make it visible on screen
        // Like: elem.style.display = "block"
        _ = ShowWindow(hwnd, SW_SHOW);
        _ = UpdateWindow(hwnd);

        return Window{ .hwnd = hwnd };
    }

    /// Clean up window resources
    /// Called automatically with 'defer' in main.zig
    /// Similar to destructor or cleanup() in JavaScript
    pub fn deinit(self: *Window) void {
        _ = DestroyWindow(self.hwnd);
    }

    /// Update the window title text
    pub fn setTitle(self: *const Window, title: []const u8) void {
        var title_wide: [512:0]u16 = undefined;
        const title_len = std.unicode.utf8ToUtf16Le(&title_wide, title) catch return;
        title_wide[title_len] = 0; // Null-terminate the string
        _ = SetWindowTextW(self.hwnd, &title_wide);
    }
};
