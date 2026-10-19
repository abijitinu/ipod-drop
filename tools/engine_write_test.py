"""End-to-end write test of ipod_engine against the connected iPod.

Touches only test data: songs titled "iPod Drop … Test" and playlists named
"iPod Drop Test" / "Engine Test". Back up iPod_Control/iTunes before running.
Usage: python tools/engine_write_test.py PATH_TO_TEST_FLAC
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from engine_client import Client  # noqa: E402

TEST_TITLE = "iPod Drop Engine Test"


def main(test_file: str) -> int:
    c = Client()
    failures = 0

    def snap():
        return c.call("library.snapshot")["result"]

    def check(label: str, ok: bool, detail="") -> None:
        nonlocal failures
        failures += not ok
        print(f"{'PASS' if ok else 'FAIL'} {label} {detail}", flush=True)

    def call(method, params):
        reply = c.call(method, params)
        if "error" in reply:
            check(method, False, reply["error"]["message"])
            return None
        return reply["result"]

    try:
        c.wait_event("device.changed", lambda p: p.get("connected"), 60)
        s = snap()
        start = len(s["tracks"])
        drop_test = next(p for p in s["playlists"] if p["name"] == "iPod Drop Test")

        r = call("send.add", {"paths": [test_file], "playlistId": drop_test["id"]})
        check("send.add new song into playlist", r and r["added"] == 1 and r["saved"], r)
        r = call("send.add", {"paths": [test_file], "playlistId": drop_test["id"]})
        check("send.add same song again is skipped", r and r["added"] == 0 and r["skipped"] == 1, r)

        s = snap()
        song = next(t for t in s["tracks"] if t["title"] == TEST_TITLE)
        tests = [t["id"] for t in s["tracks"] if t["title"].startswith("iPod Drop Test")][:2]
        check("track count +1", len(s["tracks"]) == start + 1, f"{start} -> {len(s['tracks'])}")
        in_pl = next(p for p in s["playlists"] if p["name"] == "iPod Drop Test")
        check("song is in iPod Drop Test playlist", song["id"] in in_pl["trackIds"])

        call("playlist.create", {"name": "Engine Test", "trackIds": tests})
        s = snap()
        created = next((p for p in s["playlists"] if p["name"] == "Engine Test"), None)
        check("playlist.create", created is not None and len(created["trackIds"]) == 2)

        call("playlist.rename", {"id": created["id"], "name": "Engine Test Renamed"})
        s = snap()
        renamed = next((p for p in s["playlists"] if p["name"] == "Engine Test Renamed"), None)
        check("playlist.rename", renamed is not None)

        song = next(t for t in snap()["tracks"] if t["title"] == TEST_TITLE)
        call("tracks.edit", {"ids": [song["id"]], "fields": {"title": TEST_TITLE + " Edited", "year": 2026}})
        edited = next((t for t in snap()["tracks"] if t["title"] == TEST_TITLE + " Edited"), None)
        check("tracks.edit title+year", edited is not None and edited["year"] == 2026)

        call("playlist.delete", {"id": renamed["id"]})
        check("playlist.delete", not any(p["name"].startswith("Engine Test") for p in snap()["playlists"]))

        call("tracks.remove", {"ids": [edited["id"]]})
        s = snap()
        check("tracks.remove", not any(t["title"].startswith(TEST_TITLE) for t in s["tracks"])
              and len(s["tracks"]) == start, f"now {len(s['tracks'])}")
    finally:
        c.close()
    print("FAILURES", failures)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
