"""Find iPods attached over USB, including ones macOS hasn't mounted as a disk.

iOpenPod only sees mounted volumes. This lets the app explain an iPod that is
plugged in but unusable (charging only, not in disk mode, or a model that never
mounts, like iPod touch).
"""

from __future__ import annotations

import plistlib
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

APPLE_VENDOR = 0x05AC

# USB product ids of iPods, from Apple's published device descriptors.
MODELS: dict[int, tuple[str, str]] = {
    0x1201: ("iPod (3rd generation)", "disk"),
    0x1203: ("iPod (4th generation)", "disk"),
    0x1204: ("iPod photo", "disk"),
    0x1205: ("iPod mini", "disk"),
    0x1209: ("iPod (5th generation)", "disk"),
    0x120A: ("iPod nano (1st generation)", "disk"),
    0x1260: ("iPod nano (2nd generation)", "disk"),
    0x1261: ("iPod classic", "disk"),
    0x1262: ("iPod nano (3rd generation)", "disk"),
    0x1263: ("iPod nano (4th generation)", "disk"),
    0x1265: ("iPod nano (5th generation)", "disk"),
    0x1266: ("iPod nano (6th generation)", "disk"),
    0x1267: ("iPod nano (7th generation)", "disk"),
    0x1300: ("iPod shuffle (1st generation)", "shuffle"),
    0x1301: ("iPod shuffle (2nd generation)", "shuffle"),
    0x1302: ("iPod shuffle (3rd generation)", "shuffle"),
    0x1303: ("iPod shuffle (4th generation)", "shuffle"),
    0x1291: ("iPod touch (1st generation)", "touch"),
    0x1293: ("iPod touch (2nd generation)", "touch"),
    0x1299: ("iPod touch (3rd generation)", "touch"),
    0x129E: ("iPod touch (4th generation)", "touch"),
    0x12AA: ("iPod touch (5th generation)", "touch"),
    0x12AB: ("iPod touch (6th generation)", "touch"),
}

DISK_MODE_HINT = {
    "iPod nano (6th generation)": "Hold Sleep/Wake and Volume Down until the Apple logo appears, then hold Volume Up and Volume Down until the Disk Mode screen appears.",
    "iPod nano (7th generation)": "Hold Sleep/Wake and Home until the Apple logo appears, then hold Home and Volume Down until the Disk Mode screen appears.",
}
CLICK_WHEEL_HINT = ("Toggle the Hold switch on and off, then hold Menu and Select (centre) until the "
                    "Apple logo appears; immediately hold Select and Play until the Disk Mode screen appears.")


@dataclass(frozen=True, slots=True)
class USBiPod:
    name: str
    serial: str
    kind: str  # disk | shuffle | touch | unknown
    product_id: int = 0

    def hint(self) -> str:
        if self.kind == "touch":
            return "iPod touch syncs over Apple's own protocol and can't be managed as a disk."
        if self.kind == "shuffle":
            return "iPod shuffle isn't supported yet."
        detail = DISK_MODE_HINT.get(self.name, CLICK_WHEEL_HINT)
        return ("It's connected over USB but isn't available as a disk, so it's only charging. "
                "Try a port directly on the Mac (not a hub or adapter) and another cable, "
                f"or put it into Disk Mode: {detail}")


def _walk(node: dict, found: list[dict]) -> None:
    if node.get("idVendor") == APPLE_VENDOR and (
        node.get("idProduct") in MODELS or "iPod" in str(node.get("USB Product Name", ""))
    ):
        found.append(node)
    for child in node.get("IORegistryEntryChildren", []) or []:
        _walk(child, found)


_cache: tuple[float, list[USBiPod]] = (0.0, [])


def usb_ipods(max_age: float = 3.0) -> list[USBiPod]:
    """iPods on the USB bus right now (cached briefly; ioreg takes ~50 ms)."""
    global _cache
    if time.monotonic() - _cache[0] < max_age:
        return _cache[1]
    try:
        raw = subprocess.run(["ioreg", "-p", "IOUSB", "-l", "-w0", "-a"],
                             capture_output=True, timeout=5).stdout
        tree = plistlib.loads(raw) if raw else {}
    except (subprocess.SubprocessError, plistlib.InvalidFileException, ValueError):
        tree = {}
    nodes: list[dict] = []
    if tree:
        _walk(tree, nodes)
    result = []
    for node in nodes:
        product = node.get("idProduct", 0)
        name, kind = MODELS.get(product, (str(node.get("USB Product Name") or "iPod"), "unknown"))
        result.append(USBiPod(name, str(node.get("USB Serial Number") or ""), kind, int(product or 0)))
    _cache = (time.monotonic(), result)
    return result


def _images_dir() -> Path | None:
    try:
        import iOpenPod
    except ImportError:
        return None
    # A namespace package: no __file__, but __path__ lists its directory.
    return Path(next(iter(iOpenPod.__path__))) / "assets/ipod_images"


def image_for_profile(profile) -> str | None:
    """Product photo for an identified iPod (exact model and colour)."""
    folder = _images_dir()
    if profile is None or folder is None:
        return None
    path = folder / profile.product_image
    return str(path) if path.exists() else None


def image_for_usb(product_id: int) -> str | None:
    """A representative photo for an iPod known only by its USB product id."""
    from device_registry import DEFAULT_CATALOG

    for definition in DEFAULT_CATALOG.usb_products:
        if definition.identifier.vendor_id == APPLE_VENDOR and definition.identifier.product_id == product_id:
            for identity in definition.candidate_identities:
                for profile in DEFAULT_CATALOG.profiles:
                    if (profile.family, profile.generation) == (identity.family, identity.generation):
                        return image_for_profile(profile)
    return None
