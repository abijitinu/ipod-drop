"""Safety net: copies of removed songs on the Mac, and library backups before saves.

- Before songs are removed from the iPod, their files are copied to
  ~/Music/iPod Drop/Recently Removed/<date time>/, kept for 30 days, so a removal
  (including 1-star "Marked for Removal" songs) can be undone by adding them back.
- Before every save, the iPod's library database files are copied to
  ~/Library/Application Support/iPodDrop/Library Backups/<iPod>/<date time>/
  (the newest 20 per iPod are kept), for recovery and error reports.
"""

from __future__ import annotations

import logging
import os
import re
import shutil
import time
from dataclasses import dataclass
from pathlib import Path

from PySide6.QtCore import QObject, QRunnable, Signal

logger = logging.getLogger("ipod_engine.safety")

RECENTLY_REMOVED = Path.home() / "Music/iPod Drop/Recently Removed"
LIBRARY_BACKUPS = Path.home() / "Library/Application Support/iPodDrop/Library Backups"
KEEP_REMOVED_DAYS = 30
KEEP_BACKUPS = 20
# Small database files that describe the library (the audio itself isn't copied).
LIBRARY_FILES = ("iTunesDB", "iTunesCDB", "Play Counts", "iTunesPrefs", "iTunesPrefs.plist")
SPARE_BYTES = 1 << 30  # leave at least 1 GB free on the Mac


def ipod_file(mount: str, location: str) -> Path:
    """An iPod location (":iPod_Control:Music:F01:ABCD.mp3") as a path on the mounted volume."""
    return Path(mount) / location.replace(":", "/").lstrip("/")


def _safe(text: str) -> str:
    return re.sub(r'[/:\\\x00-\x1f]', "-", text).strip(" .")[:120] or "Untitled"


@dataclass(frozen=True)
class RemovedSong:
    source: Path
    name: str  # "Artist - Title.mp3"


def removed_song(mount: str, location: str, title: str, artist: str) -> RemovedSong:
    source = ipod_file(mount, location)
    stem = _safe(f"{artist} - {title}" if artist else title or source.stem)
    return RemovedSong(source, stem + source.suffix.lower())


def prune_recently_removed(now: float | None = None) -> None:
    """Delete kept copies older than 30 days."""
    cutoff = (now or time.time()) - KEEP_REMOVED_DAYS * 86400
    if not RECENTLY_REMOVED.is_dir():
        return
    for folder in RECENTLY_REMOVED.iterdir():
        try:
            if folder.is_dir() and folder.stat().st_mtime < cutoff:
                shutil.rmtree(folder)
        except OSError as error:
            logger.warning("Couldn't clear old removed songs %s: %s", folder, error)


def backup_library(mount: str | None, ipod_name: str) -> Path | None:
    """Copy the iPod's library database files before a save; keeps the newest 20."""
    if not mount:
        return None
    source = Path(mount) / "iPod_Control/iTunes"
    files = [source / name for name in LIBRARY_FILES if (source / name).is_file()]
    if not files:
        return None
    device_dir = LIBRARY_BACKUPS / _safe(ipod_name)
    target = device_dir / time.strftime("%Y-%m-%d %H.%M.%S")
    try:
        target.mkdir(parents=True, exist_ok=True)
        for file in files:
            shutil.copy2(file, target / file.name)
        backups = sorted((d for d in device_dir.iterdir() if d.is_dir()), key=lambda d: d.name)
        for old in backups[:-KEEP_BACKUPS]:
            shutil.rmtree(old, ignore_errors=True)
        return target
    except OSError as error:  # a backup must never block the save itself
        logger.warning("Library backup failed: %s", error)
        return None


class _KeepSignals(QObject):
    progress = Signal(int, int, str)  # done, total, current song
    done = Signal(object, int, int)   # folder or None, kept, not kept


class KeepCopiesJob(QRunnable):
    """Copy songs about to be removed from the iPod into Recently Removed."""

    def __init__(self, songs: list[RemovedSong]) -> None:
        super().__init__()
        self.songs = songs
        self.signals = _KeepSignals()

    def run(self) -> None:
        prune_recently_removed()
        needed = sum(s.source.stat().st_size for s in self.songs if s.source.is_file())
        RECENTLY_REMOVED.mkdir(parents=True, exist_ok=True)
        if shutil.disk_usage(RECENTLY_REMOVED).free < needed + SPARE_BYTES:
            logger.warning("Not enough space on the Mac to keep %d removed songs", len(self.songs))
            self.signals.done.emit(None, 0, len(self.songs))
            return
        folder = RECENTLY_REMOVED / time.strftime("%Y-%m-%d %H.%M.%S")
        folder.mkdir(parents=True, exist_ok=True)
        kept = missing = 0
        used: set[str] = set()
        for index, song in enumerate(self.songs):
            self.signals.progress.emit(index, len(self.songs), song.name.rsplit(".", 1)[0])
            name, n = song.name, 2
            while name.casefold() in used:  # two songs with the same name
                stem, dot, ext = song.name.rpartition(".")
                name, n = f"{stem} {n}{dot}{ext}", n + 1
            used.add(name.casefold())
            try:
                shutil.copy2(song.source, folder / name)
                os.chmod(folder / name, 0o644)  # iPod files carry odd permissions
                kept += 1
            except OSError as error:
                logger.warning("Couldn't keep a copy of %s: %s", song.source, error)
                missing += 1
        self.signals.progress.emit(len(self.songs), len(self.songs), "")
        self.signals.done.emit(folder if kept else None, kept, missing)
