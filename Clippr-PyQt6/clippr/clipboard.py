"""Clipboard monitoring and safe copy helpers."""
from __future__ import annotations

import time
from typing import Callable

from PyQt6.QtCore import QBuffer, QByteArray, QIODevice, QObject, QTimer, pyqtSignal
from PyQt6.QtGui import QClipboard, QGuiApplication, QImage

from .store import HistoryItem, HistoryStore


class ClipboardWatcher(QObject):
    item_added = pyqtSignal(object)      # HistoryItem
    message = pyqtSignal(str)

    def __init__(self, store: HistoryStore, settings_getter: Callable, parent=None):
        super().__init__(parent)
        self.store = store
        self.settings_getter = settings_getter
        self.clipboard: QClipboard = QGuiApplication.clipboard()
        self._timer = QTimer(self)
        self._timer.setSingleShot(True)
        self._timer.setInterval(180)
        self._timer.timeout.connect(self.capture_now)
        self._ignore_until = 0.0
        self._started = False

    def start(self) -> None:
        if self._started:
            return
        self._started = True
        self.clipboard.dataChanged.connect(self._on_data_changed)

    def stop(self) -> None:
        if not self._started:
            return
        try:
            self.clipboard.dataChanged.disconnect(self._on_data_changed)
        except (TypeError, RuntimeError):
            pass
        self._started = False
        self._timer.stop()

    def _on_data_changed(self) -> None:
        self._timer.start()

    def ignore_next(self, seconds: float = 0.4) -> None:
        self._ignore_until = time.monotonic() + seconds

    def capture_now(self) -> HistoryItem | None:
        if time.monotonic() < self._ignore_until:
            return None
        settings = self.settings_getter()
        if getattr(settings, "capture_paused", False):
            return None
        try:
            md = self.clipboard.mimeData()
            if md is None:
                return None
            text = self.clipboard.text() if md.hasText() else ""
            has_image = md.hasImage()
            if has_image:
                img = self.clipboard.image()
                if img is not None and not img.isNull():
                    # Excel/Office puts a bitmap and text on the clipboard.
                    # Keep text only when the user wants plain-text pastes.
                    if text.strip() and getattr(settings, "strip_images", True):
                        self._set_text_safe(text)
                        item = self.store.add_text(text)
                        if item:
                            self.item_added.emit(item)
                            self.message.emit("Captured text (image stripped)")
                        return item
                    png = image_to_png(img)
                    if not png:
                        return None
                    item = self.store.add_image(png, img.width(), img.height())
                    if item:
                        if text.strip():
                            item.text = text.strip()
                        self.item_added.emit(item)
                        self.message.emit("Captured image")
                    return item
            if text.strip():
                item = self.store.add_text(text)
                if item:
                    self.item_added.emit(item)
                    self.message.emit("Captured text")
                return item
        except Exception as exc:  # clipboard can be locked by another process
            self.message.emit(f"Clipboard busy: {exc}")
        return None

    def _set_text_safe(self, text: str) -> None:
        self.ignore_next(0.4)
        self.clipboard.setText(text)

    def copy_item(self, item: HistoryItem) -> bool:
        """Put an item on the clipboard without adding it to history again."""
        self.ignore_next(0.4)
        try:
            if item.kind == "image":
                path = self.store.image_path(item)
                if path is None:
                    return False
                img = QImage(str(path))
                if img.isNull():
                    return False
                self.clipboard.setImage(img)
            else:
                self.clipboard.setText(item.text)
            return True
        except Exception:
            return False

    def copy_text(self, text: str) -> bool:
        if not text:
            return False
        self.ignore_next(0.4)
        self.clipboard.setText(text)
        return True


def image_to_png(image: QImage) -> bytes | None:
    ba = QByteArray()
    buf = QBuffer(ba)
    buf.open(QIODevice.OpenModeFlag.WriteOnly)
    ok = image.save(buf, "PNG")
    buf.close()
    if not ok:
        return None
    return bytes(ba)
