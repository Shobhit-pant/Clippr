"""Render preview and settings dialogs with sample data."""
from __future__ import annotations

import os
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from PyQt6.QtWidgets import QApplication  # noqa: E402
from PIL import Image, ImageDraw, ImageFont  # noqa: E402

from clippr.clipboard import ClipboardWatcher  # noqa: E402
from clippr.config import Settings  # noqa: E402
from clippr.dialogs import PreviewDialog, SettingsDialog  # noqa: E402
from clippr.main_window import MainWindow  # noqa: E402
from clippr.store import HistoryStore  # noqa: E402

OUT = Path(tempfile.gettempdir()) / "opencode" / "clippr-py-shots"
OUT.mkdir(parents=True, exist_ok=True)
DATA = Path(tempfile.gettempdir()) / "opencode" / "clippr-py-dialog-test"
shutil.rmtree(DATA, ignore_errors=True)
DATA.mkdir(parents=True)

img = Image.new("RGB", (900, 460), "#f7f3ea")
d = ImageDraw.Draw(img)
font = ImageFont.truetype("arial.ttf", 38)
d.text((50, 80), "Clippr OCR preview", fill="#1a1815", font=font)
d.text((50, 150), "Invoice total: 4,820.00", fill="#1a1815", font=font)
d.text((50, 220), "Shipment: Mumbai -> Chennai", fill="#1a1815", font=font)
p = DATA / "invoice.png"
img.save(p)

app = QApplication(sys.argv)
settings = Settings()
settings_path = DATA / "settings.json"
store = HistoryStore(DATA, 100)
image_item = store.add_image(p.read_bytes(), 900, 460)
store.add_text("A text item for preview testing.\nSecond line with useful details.", tab="General")
store.save()

win = MainWindow(store, settings, settings_path, DATA, "swiss")
win.resize(1040, 704)
win.show()
app.processEvents()

# history with image item
win.list.setCurrentIndex(win.model.index(win.model.row_of(image_item.id), 0))
app.processEvents()
win.grab().save(str(OUT / "history-image-selected.png"))

dlg = PreviewDialog(store, image_item, win.watcher, win.theme, win.settings, win)
dlg.show()
app.processEvents()
dlg.grab().save(str(OUT / "preview.png"))
print("preview saved", (OUT / "preview.png").stat().st_size)
dlg.close()

settings_dlg = SettingsDialog(win.settings, store, DATA, "swiss", win)
settings_dlg.show()
app.processEvents()
settings_dlg.grab().save(str(OUT / "settings-swiss.png"))
settings_dlg._select_theme("brass")
app.processEvents()
settings_dlg.grab().save(str(OUT / "settings-brass.png"))
print("settings saved")
settings_dlg.close()
win.close()
win.save_now()
