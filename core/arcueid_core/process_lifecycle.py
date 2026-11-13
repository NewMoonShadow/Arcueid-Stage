"""Read-only parent liveness checks, including Windows where kill(pid, 0) kills."""
from __future__ import annotations

import os


def process_is_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    if os.name != 'nt':
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        return True
    import ctypes
    from ctypes import wintypes

    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    kernel.WaitForSingleObject.restype = wintypes.DWORD
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.CloseHandle.restype = wintypes.BOOL
    handle = kernel.OpenProcess(0x00100000, False, pid)  # SYNCHRONIZE, never TERMINATE
    if not handle:
        # Access denied means the process exists but is protected.
        return ctypes.get_last_error() == 5
    try:
        return kernel.WaitForSingleObject(handle, 0) != 0  # WAIT_TIMEOUT (alive)
    finally:
        kernel.CloseHandle(handle)
