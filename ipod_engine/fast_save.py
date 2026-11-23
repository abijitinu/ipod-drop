"""One check per file in iOpenPod saves.

iOpenPod's storage layer reads every new song back from the iPod and SHA-256 hashes
it five times during one save (after staging, before publishing, while moving,
after moving, and when verifying recovery copies). On a hard-drive iPod over USB
those repeat reads are most of the wait.

This keeps the first, real read-back of each file (which catches a bad copy) and
answers the repeats from that result for as long as the file is provably the same:
same device, inode, size and modification time. The cache is cleared at the start
of every save, so it never carries over between saves.

On FAT iPods only song files are covered (iPod_Control/Music and the staged song
copies): they are written once under new names and never rewritten in place.
Database and artwork files are rewritten under the same names, and FAT reuses file
ids and keeps 2-second times, so a replacement can look identical; they always get
a full read there.

On HFS+ and APFS iPods every file is covered. iOpenPod never writes a device file in
place: each new version is written to a temporary file and renamed over the old one,
so it gets a new file id, and these file systems don't hand an id out again soon.
This matters most for cover art: one changed cover rewrites the artwork files for
every song (hundreds of MB on a big library), which were otherwise read back up to
six times per save.
"""

from __future__ import annotations

import os
import re
import subprocess
import threading
import time
from collections import OrderedDict

from storage import session as _session
from storage._filesystem import fingerprint_from_stat

_LIMIT = 50_000
_SONG_FILE = re.compile(r"/iPod_Control/Music/|/\.iopenpod-recovery/[^/]+/staged-\d+\.bin$", re.IGNORECASE)
_lock = threading.Lock()
_hashes: OrderedDict[tuple[int, int, int, int], str] = OrderedDict()
stats = {"read": 0, "reused": 0}  # for tests and logs
# Full reads during this save: path -> [reads, bytes, seconds], for the save log.
reads: dict[str, list] = {}


def _key(st) -> tuple[int, int, int, int]:
    return (int(st.st_dev), int(st.st_ino), int(st.st_size), int(st.st_mtime_ns))


def _remember(fingerprint) -> None:
    key = (fingerprint.device, fingerprint.inode, fingerprint.size, fingerprint.modified_ns)
    with _lock:
        _hashes[key] = fingerprint.sha256
        _hashes.move_to_end(key)
        while len(_hashes) > _LIMIT:
            _hashes.popitem(last=False)


# Devices (st_dev) whose file system gives every replaced file a new id.
_stable_ids: set[int] = set()


def _find_stable_volumes() -> set[int]:
    """st_dev of mounted HFS+ and APFS volumes."""
    found: set[int] = set()
    try:
        out = subprocess.run(["/sbin/mount"], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return found
    for line in out.splitlines():
        match = re.match(r".+? on (.+) \((\w+)[,)]", line)
        if match and match.group(2) in ("hfs", "apfs"):
            try:
                found.add(os.stat(match.group(1)).st_dev)
            except OSError:
                pass
    return found


def reset() -> None:
    """Forget every remembered hash (called at the start of each save)."""
    stable = _find_stable_volumes()
    with _lock:
        _hashes.clear()
        stats.update(read=0, reused=0)
        reads.clear()
        _stable_ids.clear()
        _stable_ids.update(stable)


def install() -> None:
    original = _session.read_and_fingerprint
    if getattr(original, "_ipod_drop_cached", False):
        return

    def read_and_fingerprint(path, *, collect_data, max_bytes, assert_active):
        try:
            st = os.stat(path, follow_symlinks=False)
        except OSError:
            st = None
        song = _SONG_FILE.search(str(path)) is not None or (st is not None and st.st_dev in _stable_ids)
        if song and not collect_data:
            if st is not None:
                with _lock:
                    sha = _hashes.get(_key(st))
                if sha is not None:
                    assert_active()
                    stats["reused"] += 1
                    return b"", fingerprint_from_stat(st, sha)
        started = time.monotonic()
        data, fingerprint = original(path, collect_data=collect_data, max_bytes=max_bytes,
                                     assert_active=assert_active)
        stats["read"] += 1
        with _lock:
            entry = reads.setdefault(str(path), [0, 0, 0.0])
            entry[0] += 1
            entry[1] += int(fingerprint.size)
            entry[2] += time.monotonic() - started
        if song:
            _remember(fingerprint)
        return data, fingerprint

    read_and_fingerprint._ipod_drop_cached = True  # type: ignore[attr-defined]
    _session.read_and_fingerprint = read_and_fingerprint


def summary(top: int = 6) -> str:
    """Where this save's reading time went: total, then the slowest files."""
    with _lock:
        items = sorted(reads.items(), key=lambda kv: kv[1][2], reverse=True)
    total_s = sum(v[2] for _, v in items)
    total_mb = sum(v[1] for _, v in items) / 1e6
    parts = [f"{os.path.basename(k)} x{v[0]} {v[1] / 1e6:.1f} MB {v[2]:.1f}s" for k, v in items[:top]]
    return f"reads took {total_s:.1f}s for {total_mb:.0f} MB; slowest: " + "; ".join(parts)
