"""Write test against a virtual iPod (see virtual_ipod.py) of one model.

Selects ONLY the named virtual volume (never a real iPod), adds songs that need
no conversion and some that do, checks the library on disk with iOpenPod's
parser and independently with libgpod, then removes them again.
Usage: python tools/engine_model_test.py VOLUME_NAME FILE [FILE ...]
"""

from __future__ import annotations

import ctypes
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from engine_client import Client  # noqa: E402


def libgpod_track_count(mount: str) -> int | None:
    """Independent check: can libgpod parse what the engine wrote?"""
    path = os.environ.get("LIBGPOD")
    if not path:
        return None
    lib = ctypes.CDLL(path)
    lib.itdb_parse.restype = ctypes.c_void_p
    lib.itdb_parse.argtypes = [ctypes.c_char_p, ctypes.c_void_p]
    lib.itdb_tracks_number.argtypes = [ctypes.c_void_p]
    lib.itdb_free.argtypes = [ctypes.c_void_p]
    db = lib.itdb_parse(mount.encode(), None)
    if not db:
        return -1
    count = lib.itdb_tracks_number(db)
    lib.itdb_free(db)
    return count


def main(volume: str, files: list[str]) -> int:
    c = Client()
    failures = 0

    def check(label, ok, detail=""):
        nonlocal failures
        failures += not ok
        print(f"{'PASS' if ok else 'FAIL'} {label} {detail}", flush=True)

    try:
        c.wait_event("engine.ready", timeout=30)
        device = None
        for _ in range(30):
            st = c.call("device.status")["result"]
            device = next((d for d in st["devices"] if d["name"] == volume), None)
            if device:
                break
            time.sleep(1)
        check("detected", device is not None, device and f"{device['model']} ready={device['ready']}")
        if not device:
            return 1
        if not device["ready"]:
            check("usable", False, device["message"])
            return 1
        if not device["active"]:
            for attempt in range(30):  # the engine may still be opening another iPod
                r = c.call("device.select", {"id": device["id"]})
                if "error" not in r:
                    break
                time.sleep(2)
            else:
                check("select", False, r["error"]["message"])
                return 1
            for _ in range(90):
                st = c.call("device.status")["result"]
                if st.get("id") == device["id"] and not st.get("busy"):
                    break
                time.sleep(1)
        st = c.call("device.status")["result"]
        if st.get("name") != volume:  # never write to anything but the virtual iPod
            check("active is the virtual iPod", False, st.get("name"))
            return 1
        mount = st["mountPath"]
        start = st["songs"]

        r = c.call("send.add", {"paths": files}, timeout=600)
        result = r.get("result") or {}
        check("songs added", result.get("added") == len(files), result or r.get("error"))
        snap = c.call("library.snapshot")["result"]
        check("library lists them", len(snap["tracks"]) == start + len(files), f"{start} -> {len(snap['tracks'])}")
        missing = [t["title"] for t in snap["tracks"]
                   if not (Path(mount) / t["location"].replace(":", "/").lstrip("/")).exists()]
        check("files exist on the iPod", not missing, missing[:3])
        gp = libgpod_track_count(mount)
        if gp is not None:
            check("libgpod reads the library", gp == start + len(files), f"libgpod sees {gp}")

        ids = [t["id"] for t in snap["tracks"]]
        r = c.call("tracks.remove", {"ids": ids}, timeout=300)
        check("removed", "result" in r, r.get("error"))
        check("back to start", c.call("device.status")["result"]["songs"] == start)
    finally:
        c.close()
    print("FAILURES", failures, flush=True)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2:]))
