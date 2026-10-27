"""Headless tests for search, tab filters, pause and delete."""
from __future__ import annotations

import os
import shutil
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt6.QtWidgets import QApplication  # noqa: E402

from clippr.config import Settings  # noqa: E402
from clippr.main_window import MainWindow  # noqa: E402
from clippr.store import HistoryStore  # noqa: E402


def pump(app, ms=250):
    end = time.monotonic() + ms / 1000
    while time.monotonic() < end:
        app.processEvents()
        time.sleep(0.01)


def main() -> int:
    app = QApplication(sys.argv)
    data = Path(tempfile.gettempdir()) / "opencode" / "clippr-py-ui-test"
    shutil.rmtree(data, ignore_errors=True)
    data.mkdir(parents=True)
    store = HistoryStore(data, 50)
    store.add_text("alpha needle")
    store.add_text("beta")
    store.add_image(_tiny_png(), 4, 4)
    settings = Settings()
    win = MainWindow(store, settings, data / "settings.json", data, "swiss")
    pump(app)
    assert win.model.rowCount() == 3, win.model.rowCount()

    win.search.setText("needle")
    pump(app, 350)
    assert win.model.rowCount() == 1 and win.current_item().text.startswith("alpha"), win.model.rowCount()
    win.search.clear()
    pump(app, 350)
    assert win.model.rowCount() == 3

    win.tabs.setCurrentRow(1)  # Text
    pump(app, 100)
    assert win.model.rowCount() == 2, win.model.rowCount()
    win.tabs.setCurrentRow(2)  # Images
    pump(app, 100)
    assert win.model.rowCount() == 1, win.model.rowCount()

    image_item = next(i for i in store.items if i.kind == "image")
    win._auto_name_done(image_item.id, "Invoice total 4820\nSecond line")
    assert image_item.text == "Invoice total 4820", image_item.text
    print("PASS auto-name first OCR line")

    win.toggle_capture()
    assert settings.capture_paused is True
    assert "PAUSED" in win.btn_capture.text()
    win.toggle_capture()
    assert settings.capture_paused is False

    win.tabs.setCurrentRow(1)
    pump(app, 100)
    win.list.setCurrentIndex(win.model.index(0, 0))
    before = win.model.rowCount()
    win.delete_selected()
    pump(app, 100)
    assert win.model.rowCount() == before - 1
    print("PASS UI logic: search, filters, pause, delete")
    win._allow_close = True
    win.close()
    return 0


def _tiny_png() -> bytes:
    import io

    from PIL import Image

    buf = io.BytesIO()
    Image.new("RGB", (4, 4), "white").save(buf, "PNG")
    return buf.getvalue()


if __name__ == "__main__":
    raise SystemExit(main())
