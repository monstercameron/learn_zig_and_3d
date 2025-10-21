//! # Native Window Management
//!
//! This module handles the low-level, OS-specific process of creating, managing,
//! and destroying a native desktop window.
//!
//! ## JavaScript Analogy
//!
//! For a web developer, the browser *is* the window. You never have to create it.
//! A closer analogy is a desktop application framework like Electron. This file is like
//! the native code inside Electron that creates a `BrowserWindow`. It involves several
//! steps that are normally hidden from a JavaScript developer:
//!
//! 1.  **Registering a "Window Class"**: You first define a *template* or *blueprint* for your
//!     window, specifying things like its event handler function.
//! 2.  **Creating a Window Instance**: You then create an actual window from that template.
//! 3.  **Showing the Window**: Creating a window doesn't make it visible; you have to explicitly show it.

const std = @import("std");
const windows = std.os.windows;

// ========== WINDOWS API CONSTANTS ==========
const WS_OVERLAPPEDWINDOW = 0xcf0000; // A standard window style with a title bar, borders, and min/max/close buttons.
const SW_SHOW = 5; // Command to make the window visible.
const WM_DESTROY = 2; // Message sent when a window is being destroyed.
const WM_CLOSE = 16; // Message sent when the user clicks the close button.
const WM_KEYDOWN = 0x0100;
const WM_KEYUP = 0x0101;
const WM_SYSKEYDOWN = 0x0104;
const WM_SYSKEYUP = 0x0105;
const VK_ESCAPE = 0x1B;

// A unique name for our window class, required by the OS. Must be a UTF-16 string.
const CLASS_NAME_WIDE = [_:0]u16{ 'Z', 'i', 'g', 'W', 'i', 'n', 'd', 'o', 'w', 'C', 'l', 'a', 's', 's' };

// ========== WINDOWS API STRUCTURES ==========

/// `WNDCLASSW`: The "blueprint" for a window. We fill this out to tell Windows
/// what our windows will be like before we create them.
const WNDCLASSW = extern struct {
    style: u32,
    lpfnWndProc: *anyopaque, // CRITICAL: A pointer to our event handler function (`WindowProc`).
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: windows.HINSTANCE, // A handle to our application instance.
    hIcon: ?windows.HICON,
    hCursor: ?windows.HCURSOR,
    hbrBackground: ?windows.HBRUSH,
    lpszMenuName: ?[*:0]const u16,
    lpszClassName: ?[*:0]const u16, // The unique name for this blueprint.
};

// ========== WINDOWS API FUNCTION DECLARATIONS ==========
// These are C functions from the Windows `user32.dll` and `kernel32.dll` libraries.

extern "user32" fn RegisterClassW(lpWndClass: *const WNDCLASSW) u16;
extern "user32" fn CreateWindowExW(dwExStyle: u32, lpClassName: [*:0]const u16, lpWindowName: [*:0]const u16, dwStyle: u32, x: i32, y: i32, nWidth: i32, nHeight: i32, hWndParent: ?windows.HWND, hMenu: ?windows.HMENU, hInstance: windows.HINSTANCE, lpParam: ?*anyopaque) ?windows.HWND;
extern "user32" fn ShowWindow(hWnd: windows.HWND, nCmdShow: i32) i32;
extern "user32" fn UpdateWindow(hWnd: windows.HWND) i32;
extern "user32" fn DestroyWindow(hWnd: windows.HWND) i32;
extern "user32" fn PostQuitMessage(nExitCode: i32) void;
extern "user32" fn DefWindowProcW(hWnd: windows.HWND, Msg: u32, wParam: windows.WPARAM, lParam: windows.LPARAM) windows.LRESULT;
extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const u16) windows.HINSTANCE;
extern "user32" fn SetWindowTextW(hWnd: windows.HWND, lpString: [*:0]const u16) i32;
extern "user32" fn SetForegroundWindow(hWnd: windows.HWND) bool;
extern "user32" fn SetFocus(hWnd: windows.HWND) ?windows.HWND;

// ========== WINDOW MESSAGE HANDLER (CALLBACK) ==========

/// `WindowProc`: This is the main event handler for our window. The OS calls this function
/// whenever an event occurs (e.g., key press, mouse move, close button click).
/// The `export` keyword makes it callable from outside Zig (i.e., by the C-based Windows OS).
/// JS Analogy: A giant `window.addEventListener` callback that handles *all* event types.
export fn WindowProc(hwnd: windows.HWND, msg: u32, wParam: windows.WPARAM, lParam: windows.LPARAM) windows.LRESULT {
    // We use a switch statement to handle the messages we care about.
    return switch (msg) {
        // User clicked the close button.
        WM_CLOSE => {
            _ = DestroyWindow(hwnd);
            return 0;
        },
        // The window is being destroyed.
        WM_DESTROY => {
            // This posts a `WM_QUIT` message to our application's message queue,
            // which signals the main event loop in `main.zig` to terminate.
            PostQuitMessage(0);
            return 0;
        },
        // User pressed the ESC key.
        WM_KEYDOWN, WM_SYSKEYDOWN => {
            if (wParam == VK_ESCAPE) PostQuitMessage(0);
            // For all other keys, we let the default handler process them.
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        },
        // For any message we don't explicitly handle, we must pass it to the default
        // handler so Windows can perform its standard behavior.
        else => DefWindowProcW(hwnd, msg, wParam, lParam),
    };
}

// ========== WINDOW STRUCT ==========

/// A simple struct that encapsulates a native window handle.
pub const Window = struct {
    hwnd: windows.HWND, // The "handle" is an ID the OS uses to identify our window.

    /// Creates and displays a new native window.
    pub fn init(title: []const u8, width: i32, height: i32) !Window {
        // --- STEP 1: Get Application Handle ---
        // Get a handle to the current running process (.exe file).
        const hinstance = GetModuleHandleW(null);

        var title_wide: [256:0]u16 = undefined;
        const title_len = std.unicode.utf8ToUtf16Le(&title_wide, title) catch return error.InvalidTitle;
        title_wide[title_len] = 0;

        // --- STEP 2: Define and Register the Window Class (Blueprint) ---
    var wc: WNDCLASSW = std.mem.zeroes(WNDCLASSW);
        wc.lpfnWndProc = @ptrCast(@constCast(&WindowProc)); // Tell Windows to use our `WindowProc` function as the event handler.
        wc.hInstance = hinstance;
        wc.lpszClassName = &CLASS_NAME_WIDE;
        // ... (other properties are zeroed out)

        if (RegisterClassW(&wc) == 0) {
            return error.ClassRegistrationFailed;
        }

        // --- STEP 3: Create an Instance of the Window ---
        // Now that the blueprint is registered, create an actual window from it.
        const hwnd = CreateWindowExW(
            0, // Optional extended styles.
            &CLASS_NAME_WIDE, // The name of the class we just registered.
            &title_wide, // The window title converted to UTF-16.
            WS_OVERLAPPEDWINDOW, // The visual style of the window.
            100, 100, // Initial X, Y position.
            width, height, // Initial width, height.
            null, null, // No parent window or menu.
            hinstance, // The application instance handle.
            null,
        ) orelse {
            return error.WindowCreationFailed;
        };

        // --- STEP 4: Show the Window ---
        // Creating the window doesn't make it visible. We must explicitly show it.
        _ = ShowWindow(hwnd, SW_SHOW);
        _ = UpdateWindow(hwnd);
        _ = SetForegroundWindow(hwnd);
        _ = SetFocus(hwnd);

        return Window{ .hwnd = hwnd };
    }

    /// Destroys the native window resource.
    pub fn deinit(self: *Window) void {
        _ = DestroyWindow(self.hwnd);
    }

    /// Updates the text in the window's title bar.
    pub fn setTitle(self: *const Window, title: []const u8) void {
        var title_wide: [512:0]u16 = undefined;
        const title_len = std.unicode.utf8ToUtf16Le(&title_wide, title) catch return;
        title_wide[title_len] = 0;
        _ = SetWindowTextW(self.hwnd, &title_wide);
    }
};