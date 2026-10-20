"""The engine: iOpenPod's controllers wrapped as request handlers and events.

Every handler runs on the Qt main thread and answers through `reply(result)` or
`reply(error=...)`, now or later (writes reply once the iPod save finishes).
Track and playlist ids are sent as strings because iPod ids are 64-bit.
Ids are only valid within one library generation; clients refetch on `library.changed`.
"""

from __future__ import annotations

import logging
import re
import subprocess
import tempfile
from collections.abc import Callable
from pathlib import Path
from typing import Any

from PySide6.QtCore import QObject, QRunnable, Qt, QThreadPool, QTimer, Signal, Slot
from PySide6.QtGui import QImage

from iOpenPod.app.context import AppContext
from iOpenPod.app.device_controller import DeviceOperation
from iOpenPod.app.core.settings.definitions import DRAFT_ALL_CHANGES
from iOpenPod.app.artwork_import import import_artwork
from iOpenPod.app.library_workspace import TrackArtworkEdit, TrackUpdate
from iOpenPod.app.sync_controller import SyncController
from iOpenPod.app.library_write import WriteProgress
from iOpenPod.app.library_write_controller import LibraryWriteController, PreparationState
from iOpenPod.app.models.artwork import ArtworkRequest
from iPodDB.library.editing import TrackFieldEdit
from iPodDB.library.playlists import PlaylistKind
from storage import HostPath

from ipod_engine.convert import expand
from ipod_engine.send import ImportJob, ImportOutcome, song_key
from ipod_engine.usb import image_for_profile, image_for_usb, usb_ipods

logger = logging.getLogger("ipod_engine")

Reply = Callable[..., None]
ARTWORK_CACHE = Path.home() / "Library/Caches/iPodDrop/artwork"

EDITABLE_FIELDS = {
    "title": str, "artist": str, "album": str, "albumArtist": str, "genre": str,
    "composer": str, "comment": str, "year": int, "trackNumber": int, "totalTracks": int,
    "discNumber": int, "totalDiscs": int, "rating": int, "compilation": bool,
}
FIELD_PATHS = {
    "albumArtist": "album_artist", "composer": "metadata.composer",
    "comment": "metadata.comment", "trackNumber": "track_number",
    "totalTracks": "metadata.total_tracks", "discNumber": "metadata.disc_number",
    "totalDiscs": "metadata.total_discs", "compilation": "metadata.compilation",
}


class EngineError(Exception):
    pass


# Why a mounted iPod can't be opened (iOpenPod DeviceReadiness values).
READINESS_TEXT = {
    "unknown": "This iPod model wasn't recognised.",
    "ambiguous": "This iPod's model couldn't be pinned down. Open it once in iOpenPod to identify it.",
    "conflicting": "This iPod reports conflicting model details.",
    "recovery_mode": "This iPod is in recovery mode. Restore it with Finder first.",
    "database_missing": "This iPod has no music library yet. Restore or set it up with Finder first.",
    "database_unsupported": "This iPod's music library format isn't supported.",
    "inspection_failed": "This iPod couldn't be read.",
    "sync_recovery_required": "An earlier change to this iPod didn't finish.",
}


def _other_writer_running() -> bool:
    out = subprocess.run(["pgrep", "-f", "bin/iopenpod"], capture_output=True, text=True).stdout
    return bool(out.strip())


def _track_json(t) -> dict[str, Any]:
    # Older iPod records leave fields unset; always send concrete values so clients
    # can decode strictly.
    m = t.metadata

    def n(value) -> int:
        return int(value or 0)

    def s(value) -> str:
        return str(value or "")

    return {
        "id": str(t.track_id), "title": s(t.title), "artist": s(t.artist), "album": s(t.album),
        "albumArtist": s(t.album_artist), "genre": s(t.genre), "year": n(t.year),
        "trackNumber": n(t.track_number), "totalTracks": n(m.total_tracks),
        "discNumber": n(m.disc_number), "totalDiscs": n(m.total_discs),
        "composer": s(m.composer), "comment": s(m.comment), "compilation": bool(m.compilation),
        "lengthMs": n(t.length_ms), "sizeBytes": n(t.size_bytes), "bitrateKbps": n(t.bitrate_kbps),
        "sampleRateHz": n(m.sample_rate_hz), "fileFormat": s(m.file_format),
        "playCount": n(t.play_count), "rating": n(t.rating), "artworkId": n(t.artwork_id),
        "dateAdded": n(m.date_added), "lastPlayed": n(m.last_played),
        "isAudio": any(getattr(mt, "name", "") == "AUDIO" for mt in t.media_types),
        "location": s(m.location),
    }


def _explain(issues) -> str:
    """Plain-language reasons for write refusals people can actually hit."""
    codes = {getattr(i, "code", "") for i in issues if getattr(getattr(i, "severity", None), "value", "") == "error"}
    if "binary.short_header" in codes:
        return ("This iPod's library was last written by another app (such as gtkpod, Rhythmbox or "
                "Strawberry) in an older format that iPod Drop can't extend without losing data. "
                "Restoring the iPod with Finder clears it and makes it usable here; back up its music first.")
    return ""


def _count(value) -> int | None:
    # iOpenPod sometimes reports counts pre-formatted ("1,234").
    try:
        return int(str(value).replace(",", "")) if value is not None else None
    except ValueError:
        return None


def _forward_write_progress(controller: LibraryWriteController, callback: Callable[[WriteProgress], None]) -> None:
    """Pass iOpenPod's structured save progress on to `callback`.

    The controller only re-emits the message text (progressChanged), not the stage
    counts, so wrap its progress slot. It stays a method of the controller, so the
    queued connection from the worker keeps a living receiver.
    """
    original = LibraryWriteController._progress

    def progress(self, token: int, value: object) -> None:
        original(self, token, value)
        if self is controller and token == self._token and isinstance(value, WriteProgress):
            callback(value)

    LibraryWriteController._progress = progress


# Where each iOpenPod save stage sits in one overall 0-100 bar, and what to call it.
# Stages report their own done/total; the bar moves through the stage's range.
SAVE_STAGES: tuple[tuple[str, float, float, str], ...] = (
    ("source.", 0, 4, "Checking the library"),
    ("draft.", 0, 4, "Checking the library"),
    ("resources.", 4, 6, "Checking the library"),
    ("database.", 6, 25, "Updating the iPod's library"),
    ("save.source_check", 25, 26, "Updating the iPod's library"),
    ("save.storage_transaction", 26, 27, "Copying to the iPod"),
    ("save.storage.staging", 27, 60, "Copying to the iPod"),
    ("save.storage.prepared", 60, 62, "Checking copied files"),
    ("save.storage.verifying_staged", 62, 70, "Checking copied files"),
    ("save.storage.publishing", 70, 85, "Saving"),
    ("save.storage.verifying_recovery", 85, 90, "Verifying"),
    ("save.storage.committed", 90, 92, "Verifying"),
    ("save.cleanup", 92, 94, "Finishing up"),
    ("save.media_deletion", 94, 100, "Removing song files"),
)


class SaveProgress:
    """Turns iOpenPod's per-stage progress into one percentage that only moves forward."""

    def __init__(self) -> None:
        self.reset()

    def reset(self) -> None:
        self.stage_start = 0.0
        self.percent = 0
        self.label = ""

    def update(self, progress: WriteProgress) -> dict | None:
        """The overall percentage and stage name, or None for stages outside the bar."""
        stage = next((s for s in SAVE_STAGES if progress.phase.startswith(s[0])), None)
        if stage is None:  # rechecks and flushes interleave; keep the current place
            return None
        _, start, end, label = stage
        done, total = _count(progress.completed), _count(progress.total)
        fraction = min(1.0, done / total) if done is not None and total else 0.0
        self.percent = max(self.percent, int(start + (end - start) * fraction))
        if start >= self.stage_start:  # late echoes of earlier stages don't rename the step
            self.stage_start, self.label = start, label
        return {"percent": self.percent, "label": self.label}


def _media_key(path: str) -> str:
    """iPod locations come as ":iPod_Control:Music:F01:ABCD.mp3" or as paths; compare them as one."""
    return path.replace(":", "/").strip("/").casefold()


class _ArtworkSignals(QObject):
    done = Signal(int, object, object)  # token, path or None, error text or None


class _ArtworkJob(QRunnable):
    def __init__(self, token: int, coordinator, artwork_id: int, size: int, target: Path) -> None:
        super().__init__()
        self.token = token
        self.coordinator, self.artwork_id, self.size, self.target = coordinator, artwork_id, size, target
        self.signals = _ArtworkSignals()

    def run(self) -> None:
        try:
            image = self.coordinator.load_artwork(ArtworkRequest(self.artwork_id, self.size))
            if image is None:
                self.signals.done.emit(self.token, None, None)
                return
            qimage = QImage(image.rgb888, image.width, image.height, image.width * 3,
                            QImage.Format.Format_RGB888)
            self.target.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.target.with_suffix(".tmp.png")
            if not qimage.save(str(tmp), "PNG"):
                raise OSError("could not encode artwork")
            tmp.replace(self.target)
            self.signals.done.emit(self.token, str(self.target), None)
        except Exception as error:  # artwork is cosmetic; report and move on
            logger.exception("Artwork %s failed", self.artwork_id)
            self.signals.done.emit(self.token, None, str(error))


class Engine(QObject):
    def __init__(self, context: AppContext, emit: Callable[[str, dict], None]) -> None:
        super().__init__()
        self.ctx, self.emit = context, emit
        self.devices = context.device_controller
        self.workspace = context.library_workspace
        self.writer = context.library_write_controller
        self.import_pool = QThreadPool(self)
        self.import_pool.setMaxThreadCount(1)
        self.art_pool = QThreadPool(self)
        self.art_pool.setMaxThreadCount(2)
        self.work_dir = tempfile.TemporaryDirectory(prefix="ipod-engine-")
        self.importing = False
        self._last_device: dict | None = None
        self._settled: list = []  # replies to send once the iPod finishes reloading
        self.write: tuple[Reply, dict] | None = None  # in-flight save and its result
        self.save_progress = SaveProgress()
        self.save_names: dict[str, str] = {}  # iPod file -> "Title — Artist", for the current save
        self._last_progress: dict | None = None
        self.eject_reply: Reply | None = None
        self.eject_attempts = 0
        # Worker signals must target slots on this QObject: queued signals bound to
        # lambdas are dropped when the auto-deleted worker goes away first.
        self.art_replies: dict[int, Reply] = {}
        self.art_token = 0
        self.current_send: tuple | None = None  # (revision, playlist_id, new_name, reply)
        self.send_queue: list[tuple[list[Path], str | None, str | None, Reply]] = []

        # Interrupted saves leave a recovery journal on the iPod, and iOpenPod won't
        # open the iPod until someone chooses to restore or keep. Its sync controller
        # owns that choice (the sync service itself is never used here).
        coordinator = context.device_coordinator
        self.recovery = SyncController(
            None, self.workspace, self.devices, context.settings, self,
            recovery=coordinator.recover_sync_journal,
            keep_contents=coordinator.keep_sync_contents,
            cleanup=coordinator.cleanup_sync_journal,
        )
        self.recovery.changed.connect(self._recovery_changed)
        self.recovery_reply: Reply | None = None

        self.devices.discoveryChanged.connect(self._discovery_changed)
        self.devices.activeIPodChanged.connect(self._active_changed)
        self.devices.busyChanged.connect(self._idle_changed)
        self.workspace.changed.connect(self._idle_changed)
        self.devices.operationFailed.connect(self._operation_failed)
        self.devices.ejectCompleted.connect(self._eject_completed)
        self.writer.changed.connect(self._writer_changed)
        _forward_write_progress(self.writer, self._write_progress)
        self.devices.restore_previous_device()
        self.devices.start_auto_refresh()
        # Plugging in an iPod that never mounts produces no discovery change; poll USB.
        self.usb_timer = QTimer(self)
        self.usb_timer.timeout.connect(self._emit_device)
        self.usb_timer.start(3000)

        self.handlers: dict[str, Callable[[dict, Reply], None]] = {
            "device.status": lambda p, r: r(self._device_json()),
            "device.eject": self.eject,
            "device.select": self.select,
            "device.recover": self.recover,
            "library.snapshot": lambda p, r: r(self.snapshot()),
            "library.artwork": self.artwork,
            "send.add": self.send_add,
            "playlist.create": self.playlist_create,
            "playlist.rename": self.playlist_rename,
            "playlist.delete": self.playlist_delete,
            "playlist.setTracks": self.playlist_set_tracks,
            "playlist.addTracks": self.playlist_add_tracks,
            "tracks.edit": self.tracks_edit,
            "tracks.remove": self.tracks_remove,
            "tracks.editMany": self.tracks_edit_many,
        }


    # ------------------------------------------------------------ dispatch

    def handle(self, method: str, params: dict, reply: Reply) -> None:
        handler = self.handlers.get(method)
        if handler is None:
            reply(error=f"Unknown method {method}")
            return
        try:
            handler(params or {}, reply)
        except (EngineError, ValueError, KeyError, TypeError) as error:
            if self.write is None and self.workspace.dirty and not self.workspace.locked:
                self.writer.discard_changes()  # never leave a half-applied edit behind
            reply(error=str(error) or type(error).__name__)

    # ------------------------------------------------------------ device

    def _device_json(self) -> dict[str, Any]:
        active = self.devices.active_ipod
        base = {
            "connected": active is not None,
            "searching": self.devices.searching,
            "busy": self.devices.busy or self.importing or self.write is not None,
            "otherWriter": _other_writer_running(),
            "recovery": self._recovery_json(),
        } | self._devices_json(active)
        if active is None:
            return base
        candidate = active.candidate
        return base | {
            "id": candidate.id.value,
            "name": candidate.display_name,
            "model": candidate.profile_name,
            "image": image_for_profile(candidate.profile),
            "mountPath": self._mount_path(),
            "songs": len(active.library.tracks),
            "totalBytes": candidate.total_bytes,
            "availableBytes": candidate.available_bytes,
            "generation": self.workspace.generation,
        }

    def _mount_path(self) -> str | None:
        """Where the open iPod is mounted, so the app can play its files directly."""
        try:
            active = self.ctx.device_coordinator._active  # no public accessor in iOpenPod
            return str(active.session.mounted_volume.mount_point.path) if active else None
        except AttributeError:
            return None

    def _devices_json(self, active) -> dict[str, Any]:
        """Every mounted iPod, plus iPods seen on USB that macOS hasn't mounted."""
        # iOpenPod lists every external volume it can't read (e.g. a Time Machine
        # disk) as a possible iPod. Hide those; a real iPod in that state still
        # shows up below through the USB scan.
        candidates = [c for c in self.devices.discovery.candidates
                      if not (c.profile is None and c.readiness.value == "inspection_failed")]
        devices = [{
            "id": c.id.value,
            "name": c.display_name,
            "model": c.profile_name,
            "image": image_for_profile(c.profile),
            "ready": c.selectable,
            "active": active is not None and active.candidate.id == c.id,
            "message": "" if c.selectable else READINESS_TEXT.get(c.readiness.value, c.readiness.value),
            "totalBytes": c.total_bytes,
            "availableBytes": c.available_bytes,
        } for c in candidates]
        # USB entries carry no volume, so pair them with mounted iPods by family.
        unmatched = list(usb_ipods())
        for c in candidates:
            family = c.profile.family.casefold() if c.profile else ""
            match = next((u for u in unmatched if family and family in u.name.casefold()), None)
            if match is None and unmatched:
                match = unmatched[0]
            if match is not None:
                unmatched.remove(match)
        unmounted = [{"name": u.name, "serial": u.serial, "kind": u.kind, "message": u.hint(),
                      "image": image_for_usb(u.product_id)}
                     for u in unmatched]
        return {"devices": devices, "unmounted": unmounted}

    def _emit_device(self) -> None:
        status = self._device_json()
        if status != self._last_device:  # discovery refreshes often; only send changes
            self._last_device = status
            self.emit("device.changed", status)

    @Slot()
    def _idle_changed(self, *_args) -> None:
        # Queued sends wait for the device and workspace to be free; retry on every change.
        self._emit_device()
        QTimer.singleShot(0, self._auto_select)
        QTimer.singleShot(0, self._release_settled)
        QTimer.singleShot(0, self._pump_send)

    def _release_settled(self) -> None:
        """Send replies that were waiting for the post-save reload to finish."""
        if not self._settled or self.devices.busy or self.workspace.locked:
            return
        waiting, self._settled = self._settled, []
        for send in waiting:
            send()

    @Slot(object)
    def _discovery_changed(self, discovery) -> None:
        # Discovery reports itself busy while this signal is delivered, so decide
        # once it has finished.
        QTimer.singleShot(0, self._auto_select)
        self._emit_device()

    def _auto_select(self) -> None:
        """With no iPod open, open the only usable one. With several, the app asks.

        iOpenPod also reopens the last-used iPod itself; this covers a first run and
        the case where the last-used iPod is gone.
        """
        if self.devices.active_ipod is not None or self.devices.busy or self.recovery.needs_recovery:
            return  # a pending recovery choice is the person's to make
        usable = [c for c in self.devices.discovery.candidates if c.selectable]
        if len(usable) == 1:
            self.devices.select_device(usable[0].id.value)

    # ------------------------------------------------------------ recovery

    def _recovery_json(self) -> dict[str, Any] | None:
        if not (self.recovery.needs_recovery or self.recovery.busy or self.recovery_reply):
            return None
        return {"busy": self.recovery.busy, "error": self.recovery.last_error or None}

    def recover(self, params: dict, reply: Reply) -> None:
        """Answer an interrupted save: "restore" puts back the library from before it,
        "keep" leaves the iPod as it is now (recovery copies stay on the iPod)."""
        choice = params.get("choice")
        if not self.recovery.needs_recovery:
            raise EngineError("This iPod has nothing to recover.")
        if self.recovery_reply is not None:
            raise EngineError("Recovery is already running.")
        started = self.recovery.recover() if choice == "restore" else (
            self.recovery.keep_current_contents() if choice == "keep" else None)
        if started is None:
            raise EngineError("Choose restore or keep.")
        if not started:
            raise EngineError(self.recovery.last_error or "Recovery can't start right now.")
        self.recovery_reply = reply
        self._emit_device()

    @Slot()
    def _recovery_changed(self) -> None:
        self._emit_device()
        if self.recovery.busy or self.recovery_reply is None:
            return
        reply, self.recovery_reply = self.recovery_reply, None
        result = self.recovery.result
        status = getattr(getattr(result, "status", None), "value", "")
        if self.recovery.needs_recovery:
            issues = getattr(result, "issues", ())
            message = "; ".join(i.message for i in issues[:2]) or "Recovery didn't finish."
            logger.warning("Recovery failed: %s", message)
            reply(error=message)
            return
        logger.info("Recovery finished: %s", status)
        if self.recovery.needs_cleanup:
            self.recovery.cleanup()  # remove the verified recovery copies to free space
        reply({"status": status})
        QTimer.singleShot(0, self._auto_select)  # reopen if the iPod needs a manual reload

    def select(self, params: dict, reply: Reply) -> None:
        candidate_id = str(params["id"])
        active = self.devices.active_ipod
        if active is not None and active.candidate.id.value == candidate_id:
            reply({"selected": candidate_id})
            return
        self._require_idle_device()
        candidate = next((c for c in self.devices.discovery.candidates if c.id.value == candidate_id), None)
        if candidate is None:
            raise EngineError("That iPod is no longer connected.")
        if not candidate.selectable:
            raise EngineError(READINESS_TEXT.get(candidate.readiness.value, "That iPod can't be opened."))
        self.devices.select_device(candidate_id)
        reply({"selected": candidate_id})

    @Slot(object)
    def _active_changed(self, _active) -> None:
        # Runs after iOpenPod's own handler reloaded the workspace from the new library.
        QTimer.singleShot(0, lambda: (self._emit_device(), self.emit(
            "library.changed", {"generation": self.workspace.generation})))
        QTimer.singleShot(0, self._pump_send)

    @Slot(object)
    def _operation_failed(self, failure) -> None:
        message = getattr(failure, "message", None) or str(failure)
        if getattr(failure, "operation", None) is DeviceOperation.EJECT:
            # macOS processes such as SystemUIServer or Spotlight often hold a
            # volume for a moment; an unforced unmount usually succeeds shortly after.
            if self.eject_reply and self.eject_attempts < EJECT_RETRIES and "could not unmount" in message:
                self.eject_attempts += 1
                logger.info("Eject refused (%s); retry %d", message.replace("\n", " "), self.eject_attempts)
                QTimer.singleShot(EJECT_RETRY_MS, self._retry_eject)
                return
            message = _eject_message(message)
        self.emit("device.error", {"message": message})
        if self.eject_reply:
            reply, self.eject_reply = self.eject_reply, None
            reply(error=message)

    def _retry_eject(self) -> None:
        if self.eject_reply is None:
            return
        if self.devices.busy:  # the failed attempt is still winding down
            QTimer.singleShot(500, self._retry_eject)
        elif not self.devices.eject_active_ipod():
            reply, self.eject_reply = self.eject_reply, None
            reply(error="The iPod can't be ejected right now. Try again from Finder's sidebar.")

    @Slot(object)
    def _eject_completed(self, completion) -> None:
        if self.eject_reply:
            reply, self.eject_reply = self.eject_reply, None
            reply({"ejected": True, "name": getattr(completion, "display_name", "")})
        self._emit_device()

    def eject(self, _params: dict, reply: Reply) -> None:
        self._require_idle()
        if not self.devices.eject_active_ipod():
            raise EngineError("The iPod can't be ejected right now.")
        self.eject_reply = reply
        self.eject_attempts = 0

    # ------------------------------------------------------------ library

    def _require_active(self):
        active = self.devices.active_ipod
        if active is None:
            raise EngineError("No iPod is connected.")
        return active

    def _require_idle_device(self) -> None:
        if self.importing or self.write is not None or self.devices.busy or self.send_queue:
            raise EngineError("Wait for the current transfer to finish before switching iPods.")

    def _require_idle(self) -> None:
        self._require_active()
        if self.importing or self.write is not None or self.devices.busy or self.workspace.locked:
            raise EngineError("The iPod is busy. Try again when the current transfer finishes.")
        if _other_writer_running():
            raise EngineError("Quit iOpenPod first; only one app should write to the iPod.")

    def snapshot(self) -> dict[str, Any]:
        self._require_active()
        ws = self.workspace
        playlists = []
        for p in ws.playlists:
            if p.kind is PlaylistKind.SMART and p.system_managed:
                continue
            playlists.append({
                "id": str(p.playlist_id), "name": p.name, "kind": p.kind.value,
                "parentId": str(p.parent_id) if p.parent_id is not None else None,
                "system": bool(p.system_managed),
                "trackIds": [str(i) for i in (p.track_ids if p.kind is not PlaylistKind.FOLDER else ())],
            })
        return {
            "generation": ws.generation,
            "device": self._device_json(),
            "tracks": [_track_json(t) for t in ws.tracks],
            "playlists": playlists,
        }

    def artwork(self, params: dict, reply: Reply) -> None:
        active = self._require_active()
        artwork_id, size = int(params["artworkId"]), int(params.get("size", 256))
        if artwork_id <= 0:
            reply({"path": None})
            return
        fingerprint = active.artwork_database_fingerprint
        tag = fingerprint.sha256[:16] if fingerprint else "none"
        target = ARTWORK_CACHE / tag / f"{artwork_id}-{size}.png"
        if target.exists():
            reply({"path": str(target)})
            return
        self.art_token += 1
        self.art_replies[self.art_token] = reply
        job = _ArtworkJob(self.art_token, self.ctx.device_coordinator, artwork_id, size, target)
        job.signals.done.connect(self._artwork_done, Qt.ConnectionType.QueuedConnection)
        self.art_pool.start(job)

    @Slot(int, object, object)
    def _artwork_done(self, token: int, path, error) -> None:
        reply = self.art_replies.pop(token, None)
        if reply is not None:
            reply(error=error) if error else reply({"path": path})

    def _track_ids(self, raw: list) -> tuple[int, ...]:
        ids = tuple(int(i) for i in raw)
        missing = [i for i in ids if self.workspace.track(i) is None]
        if missing:
            raise EngineError("Some songs are no longer on the iPod. Refresh and try again.")
        return ids

    def _playlist(self, raw) -> Any:
        playlist = self.workspace.playlist(int(raw))
        if playlist is None:
            raise EngineError("That playlist is no longer on the iPod.")
        if playlist.system_managed:
            raise EngineError("The iPod's main library playlist can't be changed.")
        return playlist

    # ------------------------------------------------------------ edits

    def playlist_create(self, params: dict, reply: Reply) -> None:
        self._require_idle()
        name = str(params["name"]).strip()
        if not name:
            raise EngineError("Give the playlist a name.")
        ids = self._track_ids(params.get("trackIds", []))
        self.workspace.create(PlaylistKind.PLAYLIST, name, track_ids=ids)
        self._commit(reply, {"name": name})

    def playlist_rename(self, params: dict, reply: Reply) -> None:
        self._require_idle()
        playlist = self._playlist(params["id"])
        self.workspace.rename(playlist.playlist_id, str(params["name"]).strip())
        self._commit(reply, {})

    def playlist_delete(self, params: dict, reply: Reply) -> None:
        self._require_idle()
        playlist = self._playlist(params["id"])
        self.workspace.remove_playlist(playlist.playlist_id, self.workspace.edit_revision)
        self._commit(reply, {})

    def playlist_set_tracks(self, params: dict, reply: Reply) -> None:
        self._require_idle()
        playlist = self._playlist(params["id"])
        self.workspace.set_tracks(playlist.playlist_id, self._track_ids(params["trackIds"]))
        self._commit(reply, {})

    def playlist_add_tracks(self, params: dict, reply: Reply) -> None:
        self._require_idle()
        playlist = self._playlist(params["id"])
        current = tuple(playlist.track_ids)
        new = tuple(dict.fromkeys(i for i in self._track_ids(params["trackIds"]) if i not in current))
        if new:
            self.workspace.set_tracks(playlist.playlist_id, current + new)
        self._commit(reply, {"added": len(new)})

    def tracks_edit(self, params: dict, reply: Reply) -> None:
        self._require_idle()
        ids = self._track_ids(params["ids"])
        edits = []
        for name, value in (params.get("fields") or {}).items():
            kind = EDITABLE_FIELDS.get(name)
            if kind is None:
                raise EngineError(f"{name} can't be edited.")
            edits.append(TrackFieldEdit(FIELD_PATHS.get(name, name), kind(value)))
        if not edits:
            reply({})
            return
        self.workspace.apply_track_edits(
            tuple(TrackUpdate(i, tuple(edits)) for i in ids), self.workspace.edit_revision
        )
        self._commit(reply, {"edited": len(ids)})

    def _field_edits(self, fields: dict) -> tuple:
        edits = []
        for name, value in (fields or {}).items():
            kind = EDITABLE_FIELDS.get(name)
            if kind is None:
                raise EngineError(f"{name} can't be edited.")
            edits.append(TrackFieldEdit(FIELD_PATHS.get(name, name), kind(value)))
        return tuple(edits)

    def tracks_edit_many(self, params: dict, reply: Reply) -> None:
        """Different fields (and optional cover art) per song, saved in one write.

        items: [{"id": "...", "fields": {...}, "artworkPath": "/path/cover.jpg"?}]
        """
        self._require_idle()
        items = params.get("items") or []
        ids = self._track_ids([item["id"] for item in items])
        changed = 0
        for track_id, item in zip(ids, items):
            edits = self._field_edits(item.get("fields"))
            artwork = None
            if item.get("artworkPath"):
                try:
                    pixels = import_artwork(HostPath(Path(item["artworkPath"]).resolve()), checkpoint=lambda: None)
                except Exception as error:  # a bad image shouldn't sink the whole batch
                    logger.warning("Artwork for %s skipped: %s", track_id, error)
                else:
                    artwork = TrackArtworkEdit(pixels)
            if not edits and artwork is None:
                continue
            self.workspace.apply_track_edits(
                (TrackUpdate(track_id, edits),), self.workspace.edit_revision, artwork=artwork)
            changed += 1
        self._commit(reply, {"edited": changed})

    def tracks_remove(self, params: dict, reply: Reply) -> None:
        self._require_idle()
        ids = self._track_ids(params["ids"])
        self.workspace.remove_tracks(ids, self.workspace.edit_revision)
        self._commit(reply, {"removed": len(ids)})

    # ------------------------------------------------------------ send

    def send_add(self, params: dict, reply: Reply) -> None:
        self._require_active()
        if _other_writer_running():
            raise EngineError("Quit iOpenPod first; only one app should write to the iPod.")
        files = expand([Path(p) for p in params.get("paths", [])])
        if not files:
            raise EngineError("No audio files found in what you dropped.")
        playlist_id = params.get("playlistId")
        new_name = (params.get("newPlaylist") or "").strip() or None
        if playlist_id is not None:
            self._playlist(playlist_id)
        self.send_queue.append((files, playlist_id, new_name, reply))
        self.emit("send.queued", {"files": len(files)})
        self._pump_send()

    def _pump_send(self) -> None:
        active = self.devices.active_ipod
        if (not self.send_queue or self.importing or self.write is not None or active is None
                or self.devices.busy or self.workspace.locked):
            return
        files, playlist_id, new_name, reply = self.send_queue.pop(0)
        self.importing = True
        revision = self.workspace.edit_revision
        tracks = (*active.library.tracks, *self.workspace.tracks)
        job = ImportJob(
            files, active.profile,
            tuple(t.metadata.location for t in tracks),
            {song_key(t.title, t.artist, t.album): t.track_id for t in self.workspace.tracks},
            Path(self.work_dir.name),
        )
        self.current_send = (revision, playlist_id, new_name, reply)
        job.signals.item.connect(self._send_item, Qt.ConnectionType.QueuedConnection)
        job.signals.progress.connect(self._send_progress, Qt.ConnectionType.QueuedConnection)
        job.signals.done.connect(self._send_done, Qt.ConnectionType.QueuedConnection)
        self._emit_device()
        self.import_pool.start(job)

    @Slot(str, str, str)
    def _send_item(self, name: str, state: str, detail: str) -> None:
        self.emit("send.item", {"file": name, "state": state, "detail": detail})

    @Slot(int, int)
    def _send_progress(self, done: int, total: int) -> None:
        self.emit("send.progress", {"done": done, "total": total})

    @Slot(object)
    def _send_done(self, outcome: ImportOutcome) -> None:
        if self.current_send is None:
            return
        context, self.current_send = self.current_send, None
        self._imported(outcome, *context)

    def _imported(self, outcome: ImportOutcome, revision, playlist_id, new_name, reply: Reply) -> None:
        self.importing = False
        summary = {"added": len(outcome.songs), "skipped": outcome.skipped,
                   "failed": outcome.failures, "playlist": None}
        try:
            if outcome.songs:
                self.workspace.add_songs(tuple(outcome.songs), revision)
            by_location = {t.metadata.location.casefold(): t.track_id for t in self.workspace.tracks}
            ordered = [ref if isinstance(ref, int) else by_location[ref] for ref in outcome.order]
            if ordered and new_name:
                self.workspace.create(PlaylistKind.PLAYLIST, new_name, track_ids=tuple(dict.fromkeys(ordered)))
                summary["playlist"] = new_name
            elif ordered and playlist_id is not None:
                playlist = self._playlist(playlist_id)
                current = tuple(playlist.track_ids)
                new = tuple(dict.fromkeys(i for i in ordered if i not in current))
                if new:
                    self.workspace.set_tracks(playlist.playlist_id, current + new)
                summary["playlist"] = playlist.name
        except (ValueError, KeyError, EngineError) as error:
            if self.workspace.dirty and not self.workspace.locked:
                self.writer.discard_changes()
            reply(error=f"Could not add songs: {error}")
            self._emit_device()
            QTimer.singleShot(0, self._pump_send)
            return
        self._commit(reply, summary)

    # ------------------------------------------------------------ save

    def _commit(self, reply: Reply, result: dict) -> None:
        """Write the current draft to the iPod; reply once it is saved."""
        if not self.workspace.dirty:
            reply(result | {"saved": False})
            QTimer.singleShot(0, self._pump_send)
            return
        self.write = (reply, result)
        self.save_progress.reset()
        self._last_progress = None
        # Songs on the iPod and in this draft (removed ones are only in the former).
        active = self.devices.active_ipod
        tracks = (*(active.library.tracks if active else ()), *self.workspace.tracks)
        self.save_names = {_media_key(t.metadata.location): " — ".join(x for x in (t.title, t.artist) if x)
                           for t in tracks if t.metadata.location}
        self.emit("write.state", {"state": "saving"})
        self._emit_device()
        if self.ctx.settings.get(DRAFT_ALL_CHANGES):
            self.writer.prepare()  # iOpenPod's auto-save is off; drive it ourselves

    @Slot()
    def _writer_changed(self) -> None:
        if self.write is None:
            QTimer.singleShot(0, self._pump_send)
            return
        state = self.writer.state
        if state is PreparationState.READY and self.ctx.settings.get(DRAFT_ALL_CHANGES):
            self.writer.save()
        elif state is PreparationState.SAVED:
            # The iPod reloads its library right after a save. Reply once that's
            # done so the next request doesn't find the iPod busy.
            reply, result = self.write
            self.write = None
            self.emit("write.state", {"state": "saved"})
            self._settled.append(lambda: reply(result | {"saved": True}))
            QTimer.singleShot(0, self._release_settled)
        elif state in (PreparationState.SAVE_FAILED, PreparationState.FAILED, PreparationState.BLOCKED):
            reply, _ = self.write
            self.write = None
            issues = ()
            if self.writer.save_result is not None:
                issues = self.writer.save_result.issues
            elif self.writer.review is not None:
                issues = self.writer.review.result.issues
            for issue in issues:
                logger.warning("Write issue %s [%s]: %s %s", getattr(issue, "code", "?"),
                               getattr(getattr(issue, "severity", None), "value", "?"),
                               issue.message, getattr(issue, "detail", "") or "")
            # Warnings (such as the iPod's timezone note) never stop a save; name the errors.
            errors = [i for i in issues if getattr(getattr(i, "severity", None), "value", "") != "warning"]
            detail = _explain(issues) or "; ".join(i.message for i in errors[:3]) or state.value
            self.writer.discard_changes()
            self.emit("write.state", {"state": "failed", "message": detail})
            reply(error=f"Write failed: {detail}")
        else:
            return
        self._emit_device()
        QTimer.singleShot(0, self._pump_send)

    def _write_progress(self, progress: WriteProgress) -> None:
        """Forward save progress: overall percent, stage, the song being worked on and
        how many files of the stage are done, so people can see it moving."""
        if self.write is None:
            return
        update = self.save_progress.update(progress)
        if update is None:
            return
        item = ""
        if progress.current_item:
            key = _media_key(progress.current_item)
            item = self.save_names.get(key) or (Path(key).name if "/music/" in f"/{key}" else "")
        done, total = _count(progress.completed), _count(progress.total)
        counted = progress.unit == "files" or progress.phase.startswith(
            ("save.storage.staging", "save.storage.publishing", "save.media_deletion"))
        update |= {"item": item or None,
                   "done": done if counted and total else None,
                   "total": total if counted and total else None}
        if update != self._last_progress:  # iOpenPod repeats some stages many times
            self._last_progress = update
            self.emit("write.progress", update)

    def shutdown(self) -> None:
        self.import_pool.waitForDone()
        self.art_pool.waitForDone()
        self.work_dir.cleanup()
