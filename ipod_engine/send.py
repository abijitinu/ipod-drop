"""Inspect dropped files (converting when needed) into iOpenPod draft songs, off the main thread."""

from __future__ import annotations

import logging
import os
import threading
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath

from PySide6.QtCore import QObject, QRunnable, Signal

from iOpenPod.app.media.importing import ImportedSong, MusicImporter, relocate_song
from iOpenPod.app.media.inspection import MediaInspectionError
from iOpenPod.app.media.music_paths import MusicPathAllocator
from storage import HostPath

from ipod_engine.convert import ConversionError, convert

logger = logging.getLogger("ipod_engine.send")

# Formats the iPod can't play: convert straight away instead of letting a full
# inspection fail first.
CONVERT_FIRST = {".flac", ".ogg", ".oga", ".opus", ".wma", ".ape", ".wv", ".mka", ".webm", ".dsf", ".dff", ".tta"}
# Files prepared at once (inspection copies and hashes each file; ffmpeg converts).
WORKERS = max(2, min(4, (os.cpu_count() or 4) // 2))


def quick_key(path: Path) -> tuple[str, str, str] | None:
    """The song_key from a cheap tag read, or None when the tags can't be read.

    Matches what the full inspection would produce (iOpenPod reads the same tags
    with mutagen and falls back to the file name for the title), so songs already
    on the iPod are skipped without copying and hashing the whole file.
    """
    try:
        import mutagen

        tags = mutagen.File(path, easy=True)
    except Exception:  # unreadable here; the full inspection decides
        return None
    if tags is None:
        return None

    def first(name: str) -> str:
        values = tags.get(name) or [""]
        return str(values[0])

    return song_key(first("title") or path.stem, first("artist"), first("album"))


def song_key(title: str, artist: str, album: str) -> tuple[str, str, str]:
    """Identity used to spot songs already on the iPod."""
    return (title.casefold().strip(), artist.casefold().strip(), album.casefold().strip())


@dataclass
class ImportOutcome:
    songs: list[ImportedSong] = field(default_factory=list)
    order: list[int | str] = field(default_factory=list)  # existing track id or new location
    failures: int = 0
    skipped: int = 0


class _ImportSignals(QObject):
    item = Signal(str, str, str)  # file name, state (converting/ready/converted/existing/skipped/failed), detail
    progress = Signal(int, int)
    done = Signal(object)


class ImportJob(QRunnable):
    def __init__(self, files, profile, occupied, existing: dict, work_dir: Path) -> None:
        super().__init__()
        self.files, self.profile, self.work_dir = files, profile, work_dir
        self.occupied, self.existing = occupied, existing
        self.signals = _ImportSignals()

    def run(self) -> None:
        outcome = ImportOutcome()
        allocator = MusicPathAllocator(
            self.profile.capabilities.database.music_directory_count, self.occupied
        )
        total = len(self.files)
        finished = 0
        lock = threading.Lock()
        local = threading.local()  # one importer per worker thread

        def prepare(path: Path):
            """Inspect (and convert if needed) one file; runs on a worker thread."""
            nonlocal finished
            try:
                key = quick_key(path)
                if key is not None and key in self.existing:
                    return path, "existing", key, None
                importer = getattr(local, "importer", None) or MusicImporter()
                local.importer = importer
                return path, "song", self._inspect(importer, path), None
            except Exception as error:  # reported per file below; the batch goes on
                return path, "failed", None, error
            finally:
                with lock:
                    finished += 1
                    self.signals.progress.emit(finished, total)

        self.signals.progress.emit(0, total)
        seen: set[tuple[str, str, str]] = set()
        with ThreadPoolExecutor(max_workers=WORKERS, thread_name_prefix="prepare") as pool:
            # Results come back in drop order, so playlists keep the order dropped.
            for path, kind, value, error in pool.map(prepare, self.files):
                if kind == "failed":
                    if not isinstance(error, (MediaInspectionError, ConversionError, ValueError, OSError)):
                        logger.error("Import failed for %s", path, exc_info=error)
                    outcome.failures += 1
                    self.signals.item.emit(path.name, "failed", str(error))
                    continue
                if kind == "existing":
                    outcome.skipped += 1
                    outcome.order.append(self.existing[value])
                    self.signals.item.emit(path.name, "existing", "Already on iPod")
                    continue
                song, converted = value
                track = song.track
                label = f"{track.artist} – {track.title}" if track.artist else track.title
                key = song_key(track.title, track.artist, track.album)
                if key in self.existing:
                    outcome.skipped += 1
                    outcome.order.append(self.existing[key])
                    self.signals.item.emit(path.name, "existing", label)
                    continue
                if key in seen:
                    outcome.skipped += 1
                    self.signals.item.emit(path.name, "skipped", "Duplicate in this drop")
                    continue
                seen.add(key)
                extension = PurePosixPath(song.source.media.file.relative_path).suffix[1:]
                song = relocate_song(song, allocator.allocate(extension))
                outcome.songs.append(song)
                outcome.order.append(song.track.metadata.location.casefold())
                self.signals.item.emit(path.name, "converted" if converted else "ready", label)
        self.signals.progress.emit(total, total)
        self.signals.done.emit(outcome)

    def _inspect(self, importer: MusicImporter, path: Path) -> tuple[ImportedSong, bool]:
        noop = lambda: None  # noqa: E731
        if path.suffix.lower() not in CONVERT_FIRST:
            try:
                return importer.inspect(HostPath(path.resolve()), self.profile, checkpoint=noop), False
            except MediaInspectionError as error:
                if error.code != "media.incompatible":
                    raise
        self.signals.item.emit(path.name, "converting", "")
        converted = convert(path, self.work_dir)
        song = importer.inspect(HostPath(converted), self.profile, checkpoint=noop)
        return song, True
