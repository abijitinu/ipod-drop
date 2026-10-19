"""Tiny JSON-RPC client for exercising ipod_engine from the terminal.

Usage: python tools/engine_client.py METHOD [JSON_PARAMS] [METHOD [JSON_PARAMS] ...]
Waits for the iPod, runs each call in order, prints events and results.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class Client:
    def __init__(self) -> None:
        # ENGINE_BUNDLE=path/to/iPod Drop.app tests the engine bundled inside a built app.
        bundle = os.environ.get("ENGINE_BUNDLE")
        engine = Path(bundle).resolve() / "Contents/Resources/engine" if bundle else None
        python = engine / "python/bin/python3" if engine else ROOT / ".venv/bin/python"
        cwd = engine / "app" if engine else ROOT
        self.proc = subprocess.Popen(
            [str(python), "-m", "ipod_engine"], cwd=cwd,
            env={**os.environ, "PYTHONPATH": str(cwd), "QT_QPA_PLATFORM": "offscreen"},
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=open(os.environ["ENGINE_LOG"], "w") if os.environ.get("ENGINE_LOG") else subprocess.DEVNULL,
            text=True, bufsize=1,
        )
        self.next_id = 0
        self.replies: dict[int, dict] = {}
        self.events: list[dict] = []
        self.cv = threading.Condition()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self) -> None:
        for line in self.proc.stdout:
            message = json.loads(line)
            with self.cv:
                if "id" in message and message["id"] is not None:
                    self.replies[message["id"]] = message
                else:
                    self.events.append(message)
                    if message["method"] not in ("send.progress",):
                        print("  event", message["method"], json.dumps(message["params"])[:160], flush=True)
                self.cv.notify_all()

    def wait_event(self, method: str, predicate=lambda p: True, timeout=60) -> dict:
        deadline = time.time() + timeout
        with self.cv:
            while True:
                for e in self.events:
                    if e["method"] == method and predicate(e["params"]):
                        return e["params"]
                if not self.cv.wait(max(0, deadline - time.time())):
                    raise TimeoutError(method)

    def call(self, method: str, params: dict | None = None, timeout=300) -> dict:
        self.next_id += 1
        rid = self.next_id
        self.proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params or {}}) + "\n")
        self.proc.stdin.flush()
        deadline = time.time() + timeout
        with self.cv:
            while rid not in self.replies:
                if not self.cv.wait(max(0, deadline - time.time())):
                    raise TimeoutError(method)
            return self.replies.pop(rid)

    def close(self) -> None:
        self.proc.stdin.close()
        self.proc.wait(30)


def main(argv: list[str]) -> int:
    client = Client()
    try:
        client.wait_event("engine.ready", timeout=30)
        client.wait_event("device.changed", lambda p: p.get("connected"), timeout=60)
        args = list(argv)
        while args:
            method = args.pop(0)
            params = json.loads(args.pop(0)) if args and args[0].startswith("{") else {}
            started = time.time()
            reply = client.call(method, params)
            body = reply.get("result", reply.get("error"))
            text = json.dumps(body)
            print(f"{method} ({time.time() - started:.2f}s):", text if len(text) < 600 else text[:600] + "…", flush=True)
    finally:
        client.close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
