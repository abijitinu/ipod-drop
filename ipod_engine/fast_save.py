"""One check per file in iOpenPod saves.

iOpenPod's storage layer reads every new song back from the iPod and SHA-256 hashes
it five times during one save (after staging, before publishing, while moving,
after moving, and when verifying recovery copies). On a hard-drive iPod over USB
those repeat reads are most of the wait.

This keeps the first, real read-back of each file (which catches a bad copy) and
answers the repeats from that result for as long as the file is provably the same:
same device, inode, size and modification time. The cache is cleared at the start
of every save, so it never carries over between saves.

Only song files are covered (iPod_Control/Music and the staged song copies): they
are written once under new names and never rewritten in place. Database and
artwork files are rewritten under the same names, and on FAT iPods (2-second file
times) a replacement can look identical by size and time, so they always get a
full read.
"""

from __future__ import annotations

import os
import re
import threading
from collections import OrderedDict

from storage import session as _session
from storage._filesystem import fingerprint_from_stat

_LIMIT = 50_000
_SONG_FILE = re.compile(r"/iPod_Control/Music/|/\.iopenpod-recovery/[^/]+/staged-\d+\.bin$", re.IGNORECASE)
_lock = threading.Lock()
_hashes: OrderedDict[tuple[int, int, int, int], str] = OrderedDict()
stats = {"read": 0, "reused": 0}  # for tests and logs


def _key(st) -> tuple[int, int, int, int]:
    return (int(st.st_dev), int(st.st_ino), int(st.st_size), int(st.st_mtime_ns))


def _remember(fingerprint) -> None:
    key = (fingerprint.device, fingerprint.inode, fingerprint.size, fingerprint.modified_ns)
    with _lock:
        _hashes[key] = fingerprint.sha256
        _hashes.move_to_end(key)
        while len(_hashes) > _LIMIT:
            _hashes.popitem(last=False)


def reset() -> None:
    """Forget every remembered hash (called at the start of each save)."""
    with _lock:
        _hashes.clear()
        stats.update(read=0, reused=0)


def install() -> None:
    original = _session.read_and_fingerprint
    if getattr(original, "_ipod_drop_cached", False):
        return

    def read_and_fingerprint(path, *, collect_data, max_bytes, assert_active):
        song = _SONG_FILE.search(str(path)) is not None
        if song and not collect_data:
            try:
                st = os.stat(path, follow_symlinks=False)
            except OSError:
                st = None
            if st is not None:
                with _lock:
                    sha = _hashes.get(_key(st))
                if sha is not None:
                    assert_active()
                    stats["reused"] += 1
                    return b"", fingerprint_from_stat(st, sha)
        data, fingerprint = original(path, collect_data=collect_data, max_bytes=max_bytes,
                                     assert_active=assert_active)
        stats["read"] += 1
        if song:
            _remember(fingerprint)
        return data, fingerprint

    read_and_fingerprint._ipod_drop_cached = True  # type: ignore[attr-defined]
    _session.read_and_fingerprint = read_and_fingerprint
