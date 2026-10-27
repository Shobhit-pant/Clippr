"""Render every theme and exercise the main UI without touching live data."""
from __future__ import annotations

import os
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt6.QtWidgets import QApplication  # noqa: E402
from PIL import Image, ImageDraw  # noqa: E402

from clippr.config import Settings  # noqa: E402
from clippr.main_window import MainWindow  # noqa: E402
from clippr.store import HistoryStore  # noqa: E402

OUT = Path(tempfile.gettempdir()) / "opencode" / "clippr-py-shots"
OUT.mkdir(parents=True, exist_ok=True)
DATA = Path(tempfile.gettempdir()) / "opencode" / "clippr-py-data"
if DATA.exists():
    import shutil

    shutil.rmtree(DATA)
DATA.mkdir(parents=True, exist_ok=True)


def make_image(path: Path) -> None:
    img = Image.new("RGB", (720, 420), "#f4efe4")
    d = ImageDraw.Draw(img)
    d.rectangle((36, 36, 684, 384), outline="#c8432f", width=4)
    d.text((70, 90), "Clippr image clip", fill="#1a1815")
    d.text((70, 150), "OCR should read this line.", fill="#1a1815")
    d.text((70, 210), "Total: 4,820.00", fill="#1a1815")
    img.save(path)


app = QApplication(sys.argv)
settings = Settings()
settings_path = DATA / "settings.json"
store = HistoryStore(DATA, 300)
make_image(DATA / "sample.png")
store.add_text("Quarterly report draft\nRevenue is up 18% this quarter.\n\nNext steps: share with the team on Friday.", tab="General")
store.add_image((DATA / "sample.png").read_bytes(), 720, 420, tab="General")
store.add_text("Can you make it more sleek and lucid? The scrolling should glide, not jump.", tab="General")
store.add_text("/compact", tab="General")
store.add_text("Clippr is still running in the tray — click to reopen.", tab="General")
store.add_tab("Project notes")
store.active_tab = "Project notes"
store.add_text("Follow up with the shipping team about the Tariff PDF.", tab="Project notes")
store.add_text("Remember to check the OCR text before pasting.", tab="Project notes")
store.active_tab = "All items"
store.save()

win = MainWindow(store, settings, settings_path, DATA, settings.theme)
win.resize(1040, 704)
win.show()
app.processEvents()
time.sleep(0.15)
app.processEvents()

for key in ("swiss", "brass", "brutal", "calm", "forest", "rose", "ember", "mono"):
    win.apply_theme(key, save=False)
    app.processEvents()
    time.sleep(0.05)
    app.processEvents()
    path = OUT / f"theme-{key}.png"
    win.grab().save(str(path))
    print("saved", path, path.stat().st_size)

# selection state / action enabling
win.list.setCurrentIndex(win.model.index(0, 0))
app.processEvents()
win.grab().save(str(OUT / "selected.png"))
print("selected actions:", win.btn_copy.isEnabled(), win.btn_ocr.isEnabled())

win.close()
win.save_now()
print("data files:", [p.name for p in DATA.iterdir()])
