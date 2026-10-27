"""Test OCR from the preview dialog and restore the clipboard afterwards."""
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
from PyQt6.QtGui import QGuiApplication  # noqa: E402
from PyQt6.QtWidgets import QApplication  # noqa: E402

from clippr.clipboard import ClipboardWatcher  # noqa: E402
from clippr.config import Settings  # noqa: E402
from clippr.dialogs import PreviewDialog  # noqa: E402
from clippr.ocr import make_test_image  # noqa: E402
from clippr.store import HistoryStore  # noqa: E402
from clippr.themes import theme  # noqa: E402


def pump(app, seconds: float) -> None:
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        app.processEvents()
        time.sleep(0.02)


def main() -> int:
    app = QApplication(sys.argv)
    cb = QGuiApplication.clipboard()
    original = cb.mimeData()
    saved = QMimeData()
    if original is not None:
        for fmt in original.formats():
            saved.setData(fmt, original.data(fmt))
    data = Path(tempfile.gettempdir()) / "opencode" / "clippr-py-ocr-test"
    shutil.rmtree(data, ignore_errors=True)
    data.mkdir(parents=True)
    img_path = make_test_image("Hello Clippr 12345")
    store = HistoryStore(data, 20)
    item = store.add_image(img_path.read_bytes(), 900, 220)
    settings = Settings()
    watcher = ClipboardWatcher(store, lambda: settings)
    try:
        dlg = PreviewDialog(store, item, watcher, theme("swiss"), settings)
        dlg.show()
        app.processEvents()
        dlg._ocr()
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            app.processEvents()
            if "OCR text copied" in dlg.status.text() or "failed" in dlg.status.text().lower():
                break
            time.sleep(0.05)
        print("status:", dlg.status.text())
        assert "OCR text copied" in dlg.status.text(), "OCR did not complete"
        assert "Hello Clippr 12345" in cb.text(), "OCR text was not copied"
        assert store.items[0].ocr_text, "OCR text not saved on item"
        print("PASS preview OCR + copy")
        dlg.close()
        return 0
    finally:
        if original is not None and original.formats():
            cb.setMimeData(saved)
        else:
            cb.clear()
        img_path.unlink(missing_ok=True)
        print("clipboard restored")


if __name__ == "__main__":
    raise SystemExit(main())
