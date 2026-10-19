"""Print every write issue iOpenPod reports for adding one song to a named volume.

Prepares the write but never saves it. Usage: python tools/debug_write_issues.py VOLUME FILE
"""

import os
import sys
from pathlib import Path

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from PySide6.QtCore import QTimer  # noqa: E402
from PySide6.QtWidgets import QApplication  # noqa: E402

from iOpenPod.app.context import AppContext  # noqa: E402
from iOpenPod.app.library_write_controller import PreparationState  # noqa: E402
from iOpenPod.app.media.importing import MusicImporter, relocate_song  # noqa: E402
from iOpenPod.app.media.music_paths import MusicPathAllocator  # noqa: E402
from storage import HostPath  # noqa: E402

volume, song_file = sys.argv[1], sys.argv[2]
app = QApplication([])
ctx = AppContext.create(app)
dc, ws, writer = ctx.device_controller, ctx.library_workspace, ctx.library_write_controller
state = {"stage": "select"}


def discovery(d):
    QTimer.singleShot(0, lambda: try_select(d))  # discovery reports itself as busy


def try_select(d):
    if state["stage"] != "select" or dc.busy:
        return
    target = next((c for c in d.candidates if c.display_name == volume), None)
    if target and (dc.active_ipod is None or dc.active_ipod.candidate.id != target.id):
        state["stage"] = "selecting"
        dc.select_device(target.id.value)


def active(a):
    print("active:", a and a.candidate.display_name, flush=True)
    if a is None or a.candidate.display_name != volume or state["stage"] not in ("select", "selecting"):
        return
    state["stage"] = "prepare"
    QTimer.singleShot(500, prepare)


def prepare():
    a = dc.active_ipod
    song = MusicImporter().inspect(HostPath(Path(song_file).resolve()), a.profile, checkpoint=lambda: None)
    alloc = MusicPathAllocator(a.profile.capabilities.database.music_directory_count,
                               tuple(t.metadata.location for t in a.library.tracks))
    song = relocate_song(song, alloc.allocate(Path(song_file).suffix[1:]))
    ws.add_songs((song,), ws.edit_revision)
    writer.prepare()


def changed():
    print("writer:", writer.state.value, flush=True) if state["stage"] == "prepare" else None
    if state["stage"] != "prepare" or writer.state in (PreparationState.PREPARING, PreparationState.IDLE):
        return
    review = writer.review
    print("STATE", writer.state.value)
    for i in (review.result.issues if review else ()):
        print(f"- [{i.severity.value}] {i.code} phase={i.phase} subject={i.subject} field={i.field!r}\n"
              f"    {i.message}\n    detail={i.detail!r} chunk={i.chunk_path} offset={i.offset}")
    writer.discard_changes()
    state["stage"] = "done"
    app.quit()


dc.discoveryChanged.connect(discovery)
dc.activeIPodChanged.connect(active)
writer.changed.connect(changed)
dc.start_auto_refresh()
QTimer.singleShot(90000, app.quit)
app.exec()
ctx.shutdown()
