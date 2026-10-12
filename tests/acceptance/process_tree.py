#!/usr/bin/env python3
"""Controlled parent/child probe. Never targets unrelated processes."""
from __future__ import annotations

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def main() -> int:
    mode, folder_text = sys.argv[1:3]
    folder = Path(folder_text)
    if mode == "args":
        (folder / "argv.json").write_text(json.dumps(sys.argv[3:], ensure_ascii=False), encoding="utf-8")
        return 0
    if mode == "next":
        (folder / "next-started").write_text("unexpected", encoding="utf-8")
        return 0
    if mode == "child":
        # Intentionally require group force after the POSIX grace period.
        if os.name != "nt":
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
        (folder / "child-ready").write_text(str(os.getpid()), encoding="utf-8")
        expiry = time.monotonic() + 12
        while time.monotonic() < expiry and not (folder / "stop-child").exists():
            (folder / "heartbeat").write_text(str(time.monotonic_ns()), encoding="utf-8")
            time.sleep(0.03)
        (folder / "child-exited").write_text("done", encoding="utf-8")
        return 0
    if mode == "alive":
        pid = int(sys.argv[2])
        if os.name == "nt":
            import ctypes
            api = ctypes.WinDLL("kernel32", use_last_error=True)
            api.OpenProcess.restype = ctypes.c_void_p
            api.OpenProcess.argtypes = [ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
            api.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
            api.CloseHandle.argtypes = [ctypes.c_void_p]
            handle = api.OpenProcess(0x00100000, False, pid)
            if not handle:
                return 1
            try:
                return 0 if api.WaitForSingleObject(handle, 0) == 258 else 1
            finally:
                api.CloseHandle(handle)
        try:
            state = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0]
            return 0 if state not in ("Z", "X") else 1
        except (FileNotFoundError, ProcessLookupError):
            return 1
    kwargs = {"start_new_session": True} if mode == "detached" else {}
    child = subprocess.Popen([sys.executable, __file__, "child", folder_text], **kwargs)
    (folder / "launched.json").write_text(json.dumps({"parent": os.getpid(), "child": child.pid}), encoding="utf-8")
    expiry = time.monotonic() + 5
    while not (folder / "child-ready").exists() and time.monotonic() < expiry:
        time.sleep(0.01)
    print("parent stdout", flush=True)
    print("parent stderr", file=sys.stderr, flush=True)
    (folder / "parent-ready").write_text("ready", encoding="utf-8")
    if mode == "normal" or mode == "detached":
        return 0
    if mode == "failure":
        return 7
    if os.name != "nt":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    expiry = time.monotonic() + 12
    while time.monotonic() < expiry and not (folder / "stop-parent").exists():
        time.sleep(0.03)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
