import ctypes
import os
import subprocess
import sys
import time
from collections import Counter
from ctypes import wintypes


TH32CS_SNAPTHREAD = 0x00000004
TH32CS_SNAPMODULE = 0x00000008
TH32CS_SNAPMODULE32 = 0x00000010
THREAD_SUSPEND_RESUME = 0x0002
THREAD_GET_CONTEXT = 0x0008
THREAD_QUERY_INFORMATION = 0x0040
THREAD_ALL_ACCESS = 0x1F03FF
PROCESS_QUERY_INFORMATION = 0x0400
PROCESS_VM_READ = 0x0010

CONTEXT_AMD64 = 0x00100000
CONTEXT_CONTROL = CONTEXT_AMD64 | 0x00000001
CONTEXT_INTEGER = CONTEXT_AMD64 | 0x00000002
CONTEXT_FULL = CONTEXT_CONTROL | CONTEXT_INTEGER

IMAGE_FILE_MACHINE_AMD64 = 0x8664
ADDR_MODE_FLAT = 3
MAX_SYM_NAME = 1024
SYMOPT_UNDNAME = 0x00000002
SYMOPT_DEFERRED_LOADS = 0x00000004
SYMOPT_LOAD_LINES = 0x00000010

kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
dbghelp = ctypes.WinDLL("dbghelp", use_last_error=True)


class THREADENTRY32(ctypes.Structure):
    _fields_ = [
        ("dwSize", wintypes.DWORD),
        ("cntUsage", wintypes.DWORD),
        ("th32ThreadID", wintypes.DWORD),
        ("th32OwnerProcessID", wintypes.DWORD),
        ("tpBasePri", wintypes.LONG),
        ("tpDeltaPri", wintypes.LONG),
        ("dwFlags", wintypes.DWORD),
    ]


class MODULEENTRY32(ctypes.Structure):
    _fields_ = [
        ("dwSize", wintypes.DWORD),
        ("th32ModuleID", wintypes.DWORD),
        ("th32ProcessID", wintypes.DWORD),
        ("GlblcntUsage", wintypes.DWORD),
        ("ProccntUsage", wintypes.DWORD),
        ("modBaseAddr", ctypes.POINTER(ctypes.c_byte)),
        ("modBaseSize", wintypes.DWORD),
        ("hModule", wintypes.HMODULE),
        ("szModule", ctypes.c_char * 256),
        ("szExePath", ctypes.c_char * wintypes.MAX_PATH),
    ]


class M128A(ctypes.Structure):
    _fields_ = [("Low", ctypes.c_ulonglong), ("High", ctypes.c_longlong)]


class XMM_SAVE_AREA32(ctypes.Structure):
    _fields_ = [
        ("ControlWord", wintypes.WORD),
        ("StatusWord", wintypes.WORD),
        ("TagWord", ctypes.c_byte),
        ("Reserved1", ctypes.c_byte),
        ("ErrorOpcode", wintypes.WORD),
        ("ErrorOffset", wintypes.DWORD),
        ("ErrorSelector", wintypes.WORD),
        ("Reserved2", wintypes.WORD),
        ("DataOffset", wintypes.DWORD),
        ("DataSelector", wintypes.WORD),
        ("Reserved3", wintypes.WORD),
        ("MxCsr", wintypes.DWORD),
        ("MxCsr_Mask", wintypes.DWORD),
        ("FloatRegisters", M128A * 8),
        ("XmmRegisters", M128A * 16),
        ("Reserved4", ctypes.c_byte * 96),
    ]


class CONTEXT(ctypes.Structure):
    _fields_ = [
        ("P1Home", ctypes.c_ulonglong),
        ("P2Home", ctypes.c_ulonglong),
        ("P3Home", ctypes.c_ulonglong),
        ("P4Home", ctypes.c_ulonglong),
        ("P5Home", ctypes.c_ulonglong),
        ("P6Home", ctypes.c_ulonglong),
        ("ContextFlags", wintypes.DWORD),
        ("MxCsr", wintypes.DWORD),
        ("SegCs", wintypes.WORD),
        ("SegDs", wintypes.WORD),
        ("SegEs", wintypes.WORD),
        ("SegFs", wintypes.WORD),
        ("SegGs", wintypes.WORD),
        ("SegSs", wintypes.WORD),
        ("EFlags", wintypes.DWORD),
        ("Dr0", ctypes.c_ulonglong),
        ("Dr1", ctypes.c_ulonglong),
        ("Dr2", ctypes.c_ulonglong),
        ("Dr3", ctypes.c_ulonglong),
        ("Dr6", ctypes.c_ulonglong),
        ("Dr7", ctypes.c_ulonglong),
        ("Rax", ctypes.c_ulonglong),
        ("Rcx", ctypes.c_ulonglong),
        ("Rdx", ctypes.c_ulonglong),
        ("Rbx", ctypes.c_ulonglong),
        ("Rsp", ctypes.c_ulonglong),
        ("Rbp", ctypes.c_ulonglong),
        ("Rsi", ctypes.c_ulonglong),
        ("Rdi", ctypes.c_ulonglong),
        ("R8", ctypes.c_ulonglong),
        ("R9", ctypes.c_ulonglong),
        ("R10", ctypes.c_ulonglong),
        ("R11", ctypes.c_ulonglong),
        ("R12", ctypes.c_ulonglong),
        ("R13", ctypes.c_ulonglong),
        ("R14", ctypes.c_ulonglong),
        ("R15", ctypes.c_ulonglong),
        ("Rip", ctypes.c_ulonglong),
        ("FltSave", XMM_SAVE_AREA32),
        ("VectorRegister", M128A * 26),
        ("VectorControl", ctypes.c_ulonglong),
        ("DebugControl", ctypes.c_ulonglong),
        ("LastBranchToRip", ctypes.c_ulonglong),
        ("LastBranchFromRip", ctypes.c_ulonglong),
        ("LastExceptionToRip", ctypes.c_ulonglong),
        ("LastExceptionFromRip", ctypes.c_ulonglong),
    ]


class ADDRESS64(ctypes.Structure):
    _fields_ = [
        ("Offset", ctypes.c_ulonglong),
        ("Segment", wintypes.WORD),
        ("Mode", wintypes.DWORD),
    ]


class KDHELP64(ctypes.Structure):
    _fields_ = [
        ("Thread", ctypes.c_ulonglong),
        ("ThCallbackStack", wintypes.DWORD),
        ("ThCallbackBStore", wintypes.DWORD),
        ("NextCallback", wintypes.DWORD),
        ("FramePointer", wintypes.DWORD),
        ("KiCallUserMode", ctypes.c_ulonglong),
        ("KeUserCallbackDispatcher", ctypes.c_ulonglong),
        ("SystemRangeStart", ctypes.c_ulonglong),
        ("KiUserExceptionDispatcher", ctypes.c_ulonglong),
        ("StackBase", ctypes.c_ulonglong),
        ("StackLimit", ctypes.c_ulonglong),
        ("Reserved", ctypes.c_ulonglong * 5),
    ]


class STACKFRAME64(ctypes.Structure):
    _fields_ = [
        ("AddrPC", ADDRESS64),
        ("AddrReturn", ADDRESS64),
        ("AddrFrame", ADDRESS64),
        ("AddrStack", ADDRESS64),
        ("AddrBStore", ADDRESS64),
        ("FuncTableEntry", ctypes.c_void_p),
        ("Params", ctypes.c_ulonglong * 4),
        ("Far", wintypes.BOOL),
        ("Virtual", wintypes.BOOL),
        ("Reserved", ctypes.c_ulonglong * 3),
        ("KdHelp", KDHELP64),
    ]


class SYMBOL_INFO(ctypes.Structure):
    _fields_ = [
        ("SizeOfStruct", wintypes.ULONG),
        ("TypeIndex", wintypes.ULONG),
        ("Reserved", ctypes.c_ulonglong * 2),
        ("Index", wintypes.ULONG),
        ("Size", wintypes.ULONG),
        ("ModBase", ctypes.c_ulonglong),
        ("Flags", wintypes.ULONG),
        ("Value", ctypes.c_ulonglong),
        ("Address", ctypes.c_ulonglong),
        ("Register", wintypes.ULONG),
        ("Scope", wintypes.ULONG),
        ("Tag", wintypes.ULONG),
        ("NameLen", wintypes.ULONG),
        ("MaxNameLen", wintypes.ULONG),
        ("Name", ctypes.c_char * MAX_SYM_NAME),
    ]


kernel32.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
kernel32.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
kernel32.Thread32First.argtypes = [wintypes.HANDLE, ctypes.POINTER(THREADENTRY32)]
kernel32.Thread32First.restype = wintypes.BOOL
kernel32.Thread32Next.argtypes = [wintypes.HANDLE, ctypes.POINTER(THREADENTRY32)]
kernel32.Thread32Next.restype = wintypes.BOOL
kernel32.Module32First.argtypes = [wintypes.HANDLE, ctypes.POINTER(MODULEENTRY32)]
kernel32.Module32First.restype = wintypes.BOOL
kernel32.Module32Next.argtypes = [wintypes.HANDLE, ctypes.POINTER(MODULEENTRY32)]
kernel32.Module32Next.restype = wintypes.BOOL
kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
kernel32.OpenProcess.restype = wintypes.HANDLE
kernel32.OpenThread.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
kernel32.OpenThread.restype = wintypes.HANDLE
kernel32.SuspendThread.argtypes = [wintypes.HANDLE]
kernel32.SuspendThread.restype = wintypes.DWORD
kernel32.ResumeThread.argtypes = [wintypes.HANDLE]
kernel32.ResumeThread.restype = wintypes.DWORD
kernel32.GetThreadContext.argtypes = [wintypes.HANDLE, ctypes.POINTER(CONTEXT)]
kernel32.GetThreadContext.restype = wintypes.BOOL
kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
kernel32.CloseHandle.restype = wintypes.BOOL
kernel32.GetCurrentProcessId.restype = wintypes.DWORD

dbghelp.SymSetOptions.argtypes = [wintypes.DWORD]
dbghelp.SymSetOptions.restype = wintypes.DWORD
dbghelp.SymInitialize.argtypes = [wintypes.HANDLE, wintypes.LPCSTR, wintypes.BOOL]
dbghelp.SymInitialize.restype = wintypes.BOOL
dbghelp.SymCleanup.argtypes = [wintypes.HANDLE]
dbghelp.SymCleanup.restype = wintypes.BOOL
dbghelp.StackWalk64.argtypes = [
    wintypes.DWORD,
    wintypes.HANDLE,
    wintypes.HANDLE,
    ctypes.POINTER(STACKFRAME64),
    ctypes.POINTER(CONTEXT),
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.c_void_p,
    ctypes.c_void_p,
]
dbghelp.StackWalk64.restype = wintypes.BOOL
dbghelp.SymFunctionTableAccess64.argtypes = [wintypes.HANDLE, ctypes.c_ulonglong]
dbghelp.SymFunctionTableAccess64.restype = ctypes.c_void_p
dbghelp.SymGetModuleBase64.argtypes = [wintypes.HANDLE, ctypes.c_ulonglong]
dbghelp.SymGetModuleBase64.restype = ctypes.c_ulonglong
dbghelp.SymFromAddr.argtypes = [
    wintypes.HANDLE,
    ctypes.c_ulonglong,
    ctypes.POINTER(ctypes.c_ulonglong),
    ctypes.POINTER(SYMBOL_INFO),
]
dbghelp.SymFromAddr.restype = wintypes.BOOL
dbghelp.SymLoadModuleEx.argtypes = [
    wintypes.HANDLE,
    wintypes.HANDLE,
    wintypes.LPCSTR,
    wintypes.LPCSTR,
    ctypes.c_ulonglong,
    wintypes.DWORD,
    ctypes.c_void_p,
    wintypes.DWORD,
]
dbghelp.SymLoadModuleEx.restype = ctypes.c_ulonglong


def check_handle(handle, name):
    if not handle or handle == wintypes.HANDLE(-1).value:
        raise OSError(f"{name} failed: {ctypes.get_last_error():#x}")
    return handle


def iter_threads(pid):
    snapshot = check_handle(kernel32.CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0), "CreateToolhelp32Snapshot")
    try:
        entry = THREADENTRY32()
        entry.dwSize = ctypes.sizeof(THREADENTRY32)
        ok = kernel32.Thread32First(snapshot, ctypes.byref(entry))
        while ok:
            if entry.th32OwnerProcessID == pid:
                yield entry.th32ThreadID
            ok = kernel32.Thread32Next(snapshot, ctypes.byref(entry))
    finally:
        kernel32.CloseHandle(snapshot)


def iter_modules(pid):
    flags = TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32
    snapshot = check_handle(kernel32.CreateToolhelp32Snapshot(flags, pid), "CreateToolhelp32Snapshot(modules)")
    try:
        entry = MODULEENTRY32()
        entry.dwSize = ctypes.sizeof(MODULEENTRY32)
        ok = kernel32.Module32First(snapshot, ctypes.byref(entry))
        while ok:
            yield ctypes.cast(entry.modBaseAddr, ctypes.c_void_p).value, entry.modBaseSize, entry.szExePath.split(b"\0", 1)[0].decode("utf-8", errors="replace")
            ok = kernel32.Module32Next(snapshot, ctypes.byref(entry))
    finally:
        kernel32.CloseHandle(snapshot)


def symbolize(process, addr):
    displacement = ctypes.c_ulonglong()
    symbol = SYMBOL_INFO()
    symbol.SizeOfStruct = ctypes.sizeof(SYMBOL_INFO)
    symbol.MaxNameLen = MAX_SYM_NAME
    if dbghelp.SymFromAddr(process, addr, ctypes.byref(displacement), ctypes.byref(symbol)):
        return symbol.Name[: symbol.NameLen].decode("utf-8", errors="replace")
    return f"0x{addr:x}"


def capture_stack(process, thread):
    ctx = CONTEXT()
    ctx.ContextFlags = CONTEXT_FULL
    if not kernel32.GetThreadContext(thread, ctypes.byref(ctx)):
        return []

    frame = STACKFRAME64()
    frame.AddrPC.Offset = ctx.Rip
    frame.AddrPC.Mode = ADDR_MODE_FLAT
    frame.AddrFrame.Offset = ctx.Rbp
    frame.AddrFrame.Mode = ADDR_MODE_FLAT
    frame.AddrStack.Offset = ctx.Rsp
    frame.AddrStack.Mode = ADDR_MODE_FLAT

    stack = []
    for _ in range(64):
        if frame.AddrPC.Offset == 0:
            break
        stack.append(symbolize(process, frame.AddrPC.Offset))
        ok = dbghelp.StackWalk64(
            IMAGE_FILE_MACHINE_AMD64,
            process,
            thread,
            ctypes.byref(frame),
            ctypes.byref(ctx),
            None,
            dbghelp.SymFunctionTableAccess64,
            dbghelp.SymGetModuleBase64,
            None,
        )
        if not ok:
            break
    return stack


def sample_process(pid, duration_s=1.0, interval_s=0.01):
    process = check_handle(kernel32.OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, False, pid), "OpenProcess")
    dbghelp.SymSetOptions(SYMOPT_UNDNAME | SYMOPT_DEFERRED_LOADS | SYMOPT_LOAD_LINES)
    symbol_path = os.environ.get("_NT_SYMBOL_PATH", "").encode()
    if not dbghelp.SymInitialize(process, symbol_path if symbol_path else None, True):
        raise OSError(f"SymInitialize failed: {ctypes.get_last_error():#x}")
    for base, size, path in iter_modules(pid):
        dbghelp.SymLoadModuleEx(process, None, path.encode("utf-8"), None, base, size, None, 0)

    leaf_counter = Counter()
    stack_counter = Counter()
    inclusive_counter = Counter()
    try:
        deadline = time.perf_counter() + duration_s
        while time.perf_counter() < deadline:
            for tid in iter_threads(pid):
                thread = kernel32.OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION, False, tid)
                if not thread:
                    continue
                try:
                    if kernel32.SuspendThread(thread) == 0xFFFFFFFF:
                        continue
                    try:
                        stack = capture_stack(process, thread)
                    finally:
                        kernel32.ResumeThread(thread)
                finally:
                    kernel32.CloseHandle(thread)

                if not stack:
                    continue
                leaf_counter[stack[0]] += 1
                stack_counter[" -> ".join(stack[:8])] += 1
                for frame in stack[:16]:
                    inclusive_counter[frame] += 1
            time.sleep(interval_s)
    finally:
        dbghelp.SymCleanup(process)
        kernel32.CloseHandle(process)

    return leaf_counter, inclusive_counter, stack_counter


def main():
    if len(sys.argv) < 2:
        print("usage: native_stack_sampler.py <pid> [duration_seconds]\n   or: native_stack_sampler.py --launch <exe> [warmup_seconds] [duration_seconds]", file=sys.stderr)
        raise SystemExit(2)

    launched = None
    if sys.argv[1] == "--launch":
        if len(sys.argv) < 3:
            raise SystemExit("--launch requires an executable path")
        exe_path = sys.argv[2]
        warmup = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0
        duration = float(sys.argv[4]) if len(sys.argv) > 4 else 1.0
        ttl_seconds = max(3.0, warmup + duration + 1.0)
        launch_env = os.environ.copy()
        launch_env["ZIG_RENDER_TTL_SECONDS"] = f"{ttl_seconds:g}"
        launched = subprocess.Popen([exe_path], env=launch_env)
        time.sleep(warmup)
        pid = launched.pid
    else:
        pid = int(sys.argv[1])
        duration = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0

    leaf_counter = inclusive_counter = stack_counter = None
    try:
        leaf_counter, inclusive_counter, stack_counter = sample_process(pid, duration_s=duration)
    finally:
        if launched is not None:
            launched.terminate()
            try:
                launched.wait(timeout=5)
            except subprocess.TimeoutExpired:
                launched.kill()
                launched.wait(timeout=5)

    print("TOP LEAF FRAMES")
    for name, count in leaf_counter.most_common(20):
        print(f"{count:5d}  {name}")

    print("\nTOP INCLUSIVE FRAMES")
    for name, count in inclusive_counter.most_common(30):
        print(f"{count:5d}  {name}")

    print("\nTOP STACKS")
    for stack, count in stack_counter.most_common(20):
        print(f"{count:5d}  {stack}")


if __name__ == "__main__":
    main()
