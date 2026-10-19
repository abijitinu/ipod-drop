"""Inspect dropped files (converting when needed) into iOpenPod draft songs, off the main thread."""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath

from PySide6.QtCore import QObject, QRunnable, Signal

from iOpenPod.app.media.importing import ImportedSong, MusicImporter, relocate_song
from iOpenPod.app.media.inspection import MediaInspectionError
from iOpenPod.app.media.music_paths import MusicPathAllocator
from storage import HostPath

from ipod_engine.convert import ConversionError, convert

logger = logging.getLogger("ipod_engine.send")


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
        importer, outcome = MusicImporter(), ImportOutcome()
        allocator = MusicPathAllocator(
            self.profile.capabilities.database.music_directory_count, self.occupied
        )
        seen: set[tuple[str, str, str]] = set()
        for index, path in enumerate(self.files, 1):
            self.signals.progress.emit(index - 1, len(self.files))
            try:
                song, converted = self._inspect(importer, path)
            except (MediaInspectionError, ConversionError, ValueError, OSError) as error:
                outcome.failures += 1
                self.signals.item.emit(path.name, "failed", str(error))
                continue
            except Exception as error:  # keep the batch going; details go to the log
                logger.exception("Import failed for %s", path)
                outcome.failures += 1
                self.signals.item.emit(path.name, "failed", str(error))
                continue
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
        self.signals.progress.emit(len(self.files), len(self.files))
        self.signals.done.emit(outcome)

    def _inspect(self, importer: MusicImporter, path: Path) -> tuple[ImportedSong, bool]:
        noop = lambda: None  # noqa: E731
        try:
            return importer.inspect(HostPath(path.resolve()), self.profile, checkpoint=noop), False
        except MediaInspectionError as error:
            if error.code != "media.incompatible":
                raise
        self.signals.item.emit(path.name, "converting", "")
        converted = convert(path, self.work_dir)
        song = importer.inspect(HostPath(converted), self.profile, checkpoint=noop)
        return song, True
