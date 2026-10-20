"""Bulk operations end to end: add, edit, per-song edits with cover art, playlists,
remove, and the save progress events the app shows as a percentage.

Writes to the iPod, so it only runs against the iPod named on the command line
(use a virtual iPod from tools/virtual_ipod.py, never one you care about):

  python tools/engine_bulk_test.py IPOD_NAME MUSIC_DIR [MUSIC_DIR ...]
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from engine_client import Client  # noqa: E402

failures: list[str] = []


def check(ok: bool, what: str) -> None:
    print(("  ok    " if ok else "  FAIL  ") + what, flush=True)
    if not ok:
        failures.append(what)


def call(client: Client, method: str, params: dict | None = None) -> dict:
    started = time.time()
    reply = client.call(method, params or {}, timeout=600)
    if "error" in reply:
        raise SystemExit(f"{method} failed: {reply['error']}")
    print(f"  {method} ({time.time() - started:.1f}s)", flush=True)
    return reply["result"]


def progress_events(client: Client, since: int) -> list[dict]:
    return [e["params"] for e in client.events[since:] if e["method"] == "write.progress"]


def check_progress(client: Client, since: int, what: str) -> None:
    events = progress_events(client, since)
    percents = [e["percent"] for e in events]
    check(bool(percents) and percents == sorted(percents) and percents[-1] >= 90,
          f"{what}: progress only moves forward and nearly finishes ({percents[:3]}…{percents[-3:]})")


def main(name: str, music: list[str]) -> int:
    client = Client()
    try:
        client.wait_event("engine.ready", timeout=30)
        status = client.wait_event("device.changed", lambda p: p.get("connected"), timeout=60)
        if status.get("name") != name:
            raise SystemExit(f"Refusing to write: the open iPod is {status.get('name')!r}, not {name!r}.")

        tracks = call(client, "library.snapshot")["tracks"]
        if tracks:
            mark = len(client.events)
            call(client, "tracks.remove", {"ids": [t["id"] for t in tracks]})
            check_progress(client, mark, f"remove all {len(tracks)} songs")
        check(not call(client, "library.snapshot")["tracks"], "library is empty")

        mark = len(client.events)
        added = call(client, "send.add", {"paths": music, "newPlaylist": "Bulk Test"})
        check(added["added"] > 50 and added["failed"] == 0, f"add {added['added']} songs into a new playlist")
        check_progress(client, mark, "add")
        again = call(client, "send.add", {"paths": music})
        check(again["added"] == 0 and again["skipped"] == added["added"], "adding again skips every song")

        snap = call(client, "library.snapshot")
        ids = [t["id"] for t in snap["tracks"]]
        playlist = next(p for p in snap["playlists"] if p["name"] == "Bulk Test")
        check(len(playlist["trackIds"]) == len(ids), "new playlist holds every added song")

        half = ids[: len(ids) // 2]
        mark = len(client.events)
        call(client, "tracks.edit", {"ids": half, "fields": {"genre": "Bulk Genre", "year": 1999, "rating": 80}})
        check_progress(client, mark, f"edit {len(half)} songs at once")
        by_id = {t["id"]: t for t in call(client, "library.snapshot")["tracks"]}
        check(all(by_id[i]["genre"] == "Bulk Genre" and by_id[i]["year"] == 1999 and by_id[i]["rating"] == 80
                  for i in half), "every edited song changed")

        art = next(Path(m) for m in music if Path(m).is_dir())
        cover = next(art.glob("*.jpg"), None)
        items = [{"id": i, "fields": {"title": f"Renamed {n}"}} | ({"artworkPath": str(cover)} if cover else {})
                 for n, i in enumerate(ids)]
        mark = len(client.events)
        result = call(client, "tracks.editMany", {"items": items})
        check(result["edited"] == len(ids), f"per-song edits with cover art on {len(ids)} songs")
        check_progress(client, mark, "per-song edits")
        by_id = {t["id"]: t for t in call(client, "library.snapshot")["tracks"]}
        check(all(by_id[i]["title"] == f"Renamed {n}" for n, i in enumerate(ids)), "every title changed")
        if cover:
            check(all(by_id[i]["artworkId"] > 0 for i in ids), "every song has cover art")

        call(client, "playlist.create", {"name": "Second", "trackIds": half})
        snap = call(client, "library.snapshot")
        second = next(p for p in snap["playlists"] if p["name"] == "Second")
        rest = [i for i in ids if i not in set(half)]
        call(client, "playlist.addTracks", {"id": second["id"], "trackIds": rest + half})
        second = next(p for p in call(client, "library.snapshot")["playlists"] if p["name"] == "Second")
        check(second["trackIds"] == half + rest, "adding to a playlist appends and skips duplicates")
        call(client, "playlist.setTracks", {"id": second["id"], "trackIds": rest})
        second = next(p for p in call(client, "library.snapshot")["playlists"] if p["name"] == "Second")
        check(second["trackIds"] == rest, "removing songs from a playlist keeps them on the iPod")
        call(client, "playlist.delete", {"id": second["id"]})

        remove = ids[::3]
        mark = len(client.events)
        call(client, "tracks.remove", {"ids": remove})
        check_progress(client, mark, f"remove {len(remove)} songs")
        snap = call(client, "library.snapshot")
        left = {t["id"] for t in snap["tracks"]}
        check(not left & set(remove) and len(left) == len(ids) - len(remove), "removed songs are gone, others stay")
        bulk = next(p for p in snap["playlists"] if p["name"] == "Bulk Test")
        check(not set(bulk["trackIds"]) & set(remove), "removed songs are gone from playlists too")
        check(all(p["name"] != "Second" for p in snap["playlists"]), "deleted playlist is gone")
    finally:
        client.close()
    print("\nAll bulk checks passed." if not failures else f"\n{len(failures)} check(s) failed.")
    return 1 if failures else 0


if __name__ == "__main__":
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    sys.exit(main(sys.argv[1], sys.argv[2:]))
