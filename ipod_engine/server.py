"""Line-delimited JSON-RPC 2.0 over stdin/stdout.

Requests: {"jsonrpc":"2.0","id":N,"method":"...","params":{...}}
Replies:  {"jsonrpc":"2.0","id":N,"result":...} or {"id":N,"error":{"code":-32000,"message":"..."}}
Events:   {"jsonrpc":"2.0","method":"event.name","params":{...}} (no id)
"""

from __future__ import annotations

import json
import logging
import os
import signal
import sys
import threading

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PySide6.QtCore import QObject, Qt, Signal, Slot  # noqa: E402
from PySide6.QtWidgets import QApplication  # noqa: E402

logger = logging.getLogger("ipod_engine.server")


class _Protocol:
    """Own the real stdout; everything else printing to fd 1 is sent to stderr."""

    def __init__(self) -> None:
        self.out = os.fdopen(os.dup(1), "w", buffering=1, encoding="utf-8")
        os.dup2(2, 1)
        sys.stdout = sys.stderr
        self.lock = threading.Lock()

    def send(self, message: dict) -> None:
        line = json.dumps({"jsonrpc": "2.0", **message}, ensure_ascii=False, separators=(",", ":"))
        with self.lock:
            self.out.write(line + "\n")
            self.out.flush()


class _Reader(QObject):
    request = Signal(object)
    closed = Signal()

    def run(self) -> None:
        for line in sys.stdin:
            line = line.strip()
            if line:
                self.request.emit(line)
        self.closed.emit()


class Server(QObject):
    def __init__(self, protocol: _Protocol) -> None:
        super().__init__()
        self.protocol = protocol
        self.engine = None

    def push(self, method: str, params: dict) -> None:
        self.protocol.send({"method": method, "params": params})

    @Slot(object)
    def on_request(self, line: str) -> None:
        try:
            message = json.loads(line)
            request_id, method = message.get("id"), message["method"]
            params = message.get("params") or {}
        except (ValueError, KeyError, AttributeError) as error:
            self.protocol.send({"id": None, "error": {"code": -32700, "message": f"Bad request: {error}"}})
            return
        answered = False

        def reply(result=None, *, error: str | None = None) -> None:
            nonlocal answered
            if answered or request_id is None:
                return
            answered = True
            if error is not None:
                self.protocol.send({"id": request_id, "error": {"code": -32000, "message": error}})
            else:
                self.protocol.send({"id": request_id, "result": result})

        if method == "engine.ping":
            reply({"pong": True})
            return
        try:
            self.engine.handle(method, params, reply)
        except Exception as error:  # a bug must not kill the engine
            logger.exception("Handler %s crashed", method)
            reply(error=f"Internal error: {error}")


def main() -> int:
    protocol = _Protocol()
    logging.basicConfig(
        stream=sys.stderr, level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    app = QApplication(sys.argv[:1])
    app.setApplicationName("iPod Drop Engine")
    signal.signal(signal.SIGTERM, lambda *_: app.quit())

    from iOpenPod.app.context import AppContext

    from ipod_engine.core import Engine

    context = AppContext.create(app)
    server = Server(protocol)
    server.engine = Engine(context, server.push)

    reader = _Reader()
    reader.request.connect(server.on_request, Qt.ConnectionType.QueuedConnection)
    reader.closed.connect(app.quit, Qt.ConnectionType.QueuedConnection)  # app closed our stdin
    threading.Thread(target=reader.run, name="stdin", daemon=True).start()

    server.push("engine.ready", {"version": 1})
    code = app.exec()
    server.engine.shutdown()
    context.shutdown()
    return code
