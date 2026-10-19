"""Create "virtual iPods": disk images laid out like a freshly restored iPod of a
given model, so detection and writing can be tested without the hardware.

The empty library is created by libgpod's itdb_init_ipod (the long-standing open
source iPod library), which writes iPod_Control, SysInfo and a valid empty
iTunesDB for the model number. Signed models (hash58) get a made-up FireWire GUID.

Usage:
  python tools/virtual_ipod.py create MODEL NAME [--hfs]   -> prints the mount path
  python tools/virtual_ipod.py remove NAME
Needs libgpod built (LIBGPOD env var -> path to libgpod.4.dylib).
"""

from __future__ import annotations

import ctypes
import os
import subprocess
import sys
from pathlib import Path

IMAGES = Path(os.environ.get("VIRTUAL_IPOD_DIR", "/tmp/virtual-ipods"))
FAKE_GUID = "0x000A2700DEADBEEF"


class GError(ctypes.Structure):
    _fields_ = [("domain", ctypes.c_uint32), ("code", ctypes.c_int), ("message", ctypes.c_char_p)]


def _libgpod() -> ctypes.CDLL:
    path = os.environ.get("LIBGPOD")
    if not path:
        raise SystemExit("Set LIBGPOD to the built libgpod.4.dylib")
    lib = ctypes.CDLL(path)
    lib.itdb_init_ipod.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p,
                                   ctypes.POINTER(ctypes.POINTER(GError))]
    lib.itdb_init_ipod.restype = ctypes.c_int
    return lib


def _itunes_layout(path: Path) -> None:
    """Keep only the sections iTunes wrote for pre-2007 iPods (tracks, playlists,
    podcasts). libgpod adds newer index sections those iPods never had."""
    import struct
    d = path.read_bytes()
    header = struct.unpack_from("<I", d, 4)[0]
    out, i, kept = bytearray(d[:header]), header, 0
    while i < len(d) and d[i:i + 4] == b"mhsd":
        total = struct.unpack_from("<I", d, i + 8)[0]
        if struct.unpack_from("<I", d, i + 12)[0] in (1, 2, 3):
            out += d[i:i + total]
            kept += 1
        i += total
    struct.pack_into("<I", out, 8, len(out))
    struct.pack_into("<I", out, 0x14, kept)
    path.write_bytes(bytes(out))


def create(model: str, name: str, hfs: bool = False, size_mb: int = 300, itunes_layout: bool = False,
           sparse: bool = False) -> Path:
    """sparse: a full-size (e.g. 160 GB) image that only uses the space written to it."""
    IMAGES.mkdir(parents=True, exist_ok=True)
    image = IMAGES / f"{name}.sparseimage" if sparse else IMAGES / f"{name}.dmg"
    remove(name)
    fs = "HFS+" if hfs else "MS-DOS FAT32"
    subprocess.run(["hdiutil", "create", "-size", f"{size_mb}m", "-fs", fs, "-volname", name,
                    "-layout", "MBRSPUD" if not hfs else "GPTSPUD",
                    *(["-type", "SPARSE"] if sparse else []), "-o", str(image).removesuffix(".sparseimage")],
                   check=True, capture_output=True)
    out = subprocess.run(["hdiutil", "attach", "-nobrowse", str(image)], check=True,
                         capture_output=True, text=True).stdout
    mount = Path(next(line.split("\t")[-1].strip() for line in out.splitlines() if "/Volumes/" in line))

    # SysInfo first so libgpod knows the model and (for signed models) the GUID.
    device = mount / "iPod_Control" / "Device"
    device.mkdir(parents=True, exist_ok=True)
    (device / "SysInfo").write_text(f"ModelNumStr: {model}\nFirewireGuid: {FAKE_GUID}\n")

    error = ctypes.POINTER(GError)()
    ok = _libgpod().itdb_init_ipod(str(mount).encode(), model.encode(), name.encode(), ctypes.byref(error))
    if not ok:
        message = error.contents.message.decode() if error else "unknown error"
        raise SystemExit(f"itdb_init_ipod failed for {model}: {message}")
    if itunes_layout:
        _itunes_layout(mount / "iPod_Control" / "iTunes" / "iTunesDB")
    # libgpod rewrites SysInfo; keep the GUID line for signed models.
    sysinfo = device / "SysInfo"
    text = sysinfo.read_text() if sysinfo.exists() else f"ModelNumStr: {model}\n"
    if "FirewireGuid" not in text:
        sysinfo.write_text(text.rstrip("\n") + f"\nFirewireGuid: {FAKE_GUID}\n")
    return mount


def remove(name: str) -> None:
    mount = Path("/Volumes") / name
    if mount.exists():
        subprocess.run(["hdiutil", "detach", "-force", str(mount)], capture_output=True)
    (IMAGES / f"{name}.dmg").unlink(missing_ok=True)
    (IMAGES / f"{name}.sparseimage").unlink(missing_ok=True)


if __name__ == "__main__":
    if sys.argv[1] == "create":
        size = next((int(a.split("=")[1]) for a in sys.argv if a.startswith("--size-mb=")), 300)
        print(create(sys.argv[2], sys.argv[3], hfs="--hfs" in sys.argv, itunes_layout="--itunes" in sys.argv,
                     size_mb=size, sparse="--sparse" in sys.argv))
    elif sys.argv[1] == "remove":
        remove(sys.argv[2])
