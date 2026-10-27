"""Clipboard integration test. Saves and restores the real clipboard."""
from __future__ import annotations

import os
import shutil
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from PyQt6.QtCore import QMimeData  # noqa: E402
from PyQt6.QtGui import QColor, QGuiApplication, QImage  # noqa: E402
from PyQt6.QtWidgets import QApplication  # noqa: E402

from clippr.clipboard import ClipboardWatcher  # noqa: E402
from clippr.config import Settings  # noqa: E402
from clippr.store import HistoryStore  # noqa: E402


def pump(app: QApplication, ms: int = 700) -> None:
    end = time.monotonic() + ms / 1000.0
    while time.monotonic() < end:
        app.processEvents()
        time.sleep(0.015)


def main() -> int:
    app = QApplication(sys.argv)
    cb = QGuiApplication.clipboard()
    original = cb.mimeData()
    saved = QMimeData()
    if original is not None:
        for fmt in original.formats():
            saved.setData(fmt, original.data(fmt))
    data = Path(tempfile.gettempdir()) / "opencode" / "clippr-py-clip-test"
    shutil.rmtree(data, ignore_errors=True)
    data.mkdir(parents=True)

    settings = Settings(strip_images=True)
    store = HistoryStore(data, 50)
    watcher = ClipboardWatcher(store, lambda: settings)
    errors: list[str] = []
    watcher.item_added.connect(lambda item: errors.append(item.kind))
    watcher.start()
    try:
        # 1. plain text
        cb.setText("Clippr clipboard test 12345")
        pump(app, 500)
        text = store.items[0].text if store.items else ""
        assert "Clippr clipboard test 12345" in text, "plain text capture failed"
        print("PASS plain text capture")

        # 2. Excel-style image + text: should become text only
        md = QMimeData()
        img = QImage(160, 80, QImage.Format.Format_RGB32)
        img.fill(QColor("#f4efe4"))
        md.setText("Excel cell text 42")
        md.setImageData(img)
        cb.setMimeData(md)
        pump(app, 700)
        assert store.items and store.items[0].kind == "text", "strip did not store text"
        assert store.items[0].text == "Excel cell text 42", "strip lost text"
        after = cb.mimeData()
        assert after is None or not after.hasImage(), "clipboard still has an image after strip"
        print("PASS strip image+text -> text only")

        # 3. paused capture does nothing
        settings.capture_paused = True
        before = len(store.items)
        cb.setText("Paused capture test")
        pump(app, 450)
        assert len(store.items) == before, "capture ran while paused"
        settings.capture_paused = False
        print("PASS pause")

        # 4. copying a history item must not re-add it
        before = len(store.items)
        watcher.copy_item(store.items[0])
        pump(app, 600)
        assert len(store.items) == before, "self-copy was captured again"
        print("PASS self-copy ignored")

        # 5. image-only capture
        cb.setImage(img)
        pump(app, 700)
        assert store.items and store.items[0].kind == "image", "image capture failed"
        print("PASS image capture")

        print("signal kinds:", errors)
        return 0
    finally:
        watcher.stop()
        if original is not None and original.formats():
            cb.setMimeData(saved)
        else:
            cb.clear()
        print("clipboard restored")


if __name__ == "__main__":
    raise SystemExit(main())
