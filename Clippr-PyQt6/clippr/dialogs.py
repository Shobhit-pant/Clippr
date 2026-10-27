"""Preview, settings and small prompt dialogs."""
from __future__ import annotations

from pathlib import Path

from PyQt6.QtCore import Qt, pyqtSignal
from PyQt6.QtGui import QPixmap
from PyQt6.QtWidgets import (
    QCheckBox,
    QDialog,
    QFrame,
    QGridLayout,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QMessageBox,
    QPushButton,
    QScrollArea,
    QSpinBox,
    QTextEdit,
    QVBoxLayout,
)

from . import autostart
from .clipboard import ClipboardWatcher
from .config import Settings, open_path
from .ocr import OcrWorker
from .store import HistoryItem, HistoryStore
from .themes import THEMES, Theme, theme
from .widgets import ThemeCard


class TextPromptDialog(QDialog):
    def __init__(self, title: str, label: str, initial: str = "", parent=None):
        super().__init__(parent)
        self.setWindowTitle(title)
        self.setModal(True)
        self.setMinimumWidth(380)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(22, 20, 22, 18)
        layout.setSpacing(12)
        lbl = QLabel(label)
        layout.addWidget(lbl)
        self.edit = QLineEdit(initial)
        self.edit.selectAll()
        layout.addWidget(self.edit)
        row = QHBoxLayout()
        row.addStretch(1)
        cancel = QPushButton("Cancel")
        ok = QPushButton("OK")
        ok.setProperty("role", "primary")
        cancel.clicked.connect(self.reject)
        ok.clicked.connect(self._accept)
        row.addWidget(cancel)
        row.addWidget(ok)
        layout.addLayout(row)
        self.edit.returnPressed.connect(self._accept)

    def _accept(self) -> None:
        if self.edit.text().strip():
            self.accept()

    def value(self) -> str:
        return self.edit.text().strip()

    @classmethod
    def get_text(cls, parent, title: str, label: str, initial: str = "") -> str | None:
        d = cls(title, label, initial, parent)
        if d.exec() == QDialog.DialogCode.Accepted:
            return d.value()
        return None


class PreviewDialog(QDialog):
    item_updated = pyqtSignal(str)

    def __init__(self, store: HistoryStore, item: HistoryItem, watcher: ClipboardWatcher, t: Theme, parent=None):
        super().__init__(parent)
        self.store = store
        self.watcher = watcher
        self.theme = t
        self.item = store.get(item.id) or item
        self._worker: OcrWorker | None = None
        self.setWindowTitle("Clippr Preview")
        self.setModal(True)
        self.resize(760, 590)
        self._build()

    def _build(self) -> None:
        t = self.theme
        self.item = self.store.get(self.item.id) or self.item
        root = QVBoxLayout(self)
        root.setContentsMargins(22, 18, 22, 18)
        root.setSpacing(12)

        top = QHBoxLayout()
        kind = QLabel("IMAGE" if self.item.kind == "image" else "TEXT")
        kind.setObjectName("SectionLabel")
        top.addWidget(kind)
        meta = QLabel(f"{self.item.short_time()}  ·  {self.item.tab}")
        meta.setObjectName("Hint")
        top.addWidget(meta)
        top.addStretch(1)
        root.addLayout(top)

        if self.item.kind == "image":
            path = self.store.image_path(self.item)
            scroll = QScrollArea()
            scroll.setWidgetResizable(True)
            scroll.setFrameShape(QFrame.Shape.NoFrame)
            self.image_label = QLabel()
            self.image_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
            self.image_label.setStyleSheet("background: transparent;")
            if path is not None:
                pix = QPixmap(str(path))
                if not pix.isNull():
                    self.image_label.setPixmap(pix.scaled(700, 360, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation))
            scroll.setWidget(self.image_label)
            scroll.setMinimumHeight(220)
            root.addWidget(scroll, 2)
            self.ocr_box = QTextEdit()
            self.ocr_box.setReadOnly(True)
            self.ocr_box.setPlaceholderText("OCR text will appear here.")
            self.ocr_box.setPlainText(self.item.ocr_text)
            self.ocr_box.setVisible(bool(self.item.ocr_text))
            root.addWidget(self.ocr_box, 1)
        else:
            self.text_box = QTextEdit()
            self.text_box.setReadOnly(True)
            self.text_box.setPlainText(self.item.text)
            root.addWidget(self.text_box, 1)

        self.status = QLabel("")
        self.status.setObjectName("Hint")
        root.addWidget(self.status)

        row = QHBoxLayout()
        row.addStretch(1)
        self.btn_copy = QPushButton("COPY")
        self.btn_copy.setProperty("role", "primary")
        self.btn_copy.clicked.connect(self._copy)
        self.btn_ocr = QPushButton("OCR + COPY")
        self.btn_ocr.clicked.connect(self._ocr)
        self.btn_ocr.setEnabled(self.item.kind == "image")
        close = QPushButton("CLOSE")
        close.clicked.connect(self.accept)
        row.addWidget(self.btn_copy)
        row.addWidget(self.btn_ocr)
        row.addWidget(close)
        root.addLayout(row)
        self._apply_theme()

    def _apply_theme(self) -> None:
        from .themes import build_qss

        self.setStyleSheet(build_qss(self.theme))
        self.setStyleSheet(self.styleSheet())  # keep local stylesheet explicit

    def _copy(self) -> None:
        if self.watcher.copy_item(self.item):
            self.status.setText("Copied to clipboard.")
        else:
            self.status.setText("Could not copy this item.")

    def _ocr(self) -> None:
        path = self.store.image_path(self.item)
        if path is None:
            self.status.setText("Image file is missing.")
            return
        self.btn_ocr.setEnabled(False)
        self.btn_copy.setEnabled(False)
        self.status.setText("Reading text…")
        self._worker = OcrWorker(path)
        self._worker.recognized.connect(self._ocr_done)
        self._worker.failed.connect(self._ocr_failed)
        self._worker.start()

    def _ocr_done(self, text: str) -> None:
        self.btn_ocr.setEnabled(True)
        self.btn_copy.setEnabled(True)
        if not text:
            self.status.setText("No text found in this image.")
            return
        self.store.update_ocr(self.item.id, text)
        self.item.ocr_text = text
        self.watcher.copy_text(text)
        self.ocr_box.setPlainText(text)
        self.ocr_box.setVisible(True)
        self.status.setText(f"OCR text copied ({len(text)} characters).")
        self.item_updated.emit(self.item.id)

    def _ocr_failed(self, message: str) -> None:
        self.btn_ocr.setEnabled(True)
        self.btn_copy.setEnabled(True)
        self.status.setText(message)
        QMessageBox.warning(self, "OCR unavailable", message)


class SettingsDialog(QDialog):
    theme_changed = pyqtSignal(str)

    def __init__(self, settings: Settings, store: HistoryStore, data_dir: Path, current_theme: str, parent=None):
        super().__init__(parent)
        self.settings = settings
        self.store = store
        self.data_dir = data_dir
        self.current_theme = current_theme
        self.setWindowTitle("Clippr Settings")
        self.setModal(True)
        self.setMinimumSize(640, 560)
        self._cards: dict[str, ThemeCard] = {}
        self._build()

    def _build(self) -> None:
        root = QVBoxLayout(self)
        root.setContentsMargins(24, 20, 24, 18)
        root.setSpacing(14)

        head = QHBoxLayout()
        title = QLabel("Settings")
        title.setObjectName("AppTitle")
        title.setStyleSheet("font-size: 18pt;")
        head.addWidget(title)
        head.addStretch(1)
        root.addLayout(head)

        lbl = QLabel("THEME")
        lbl.setObjectName("SectionLabel")
        root.addWidget(lbl)
        grid = QGridLayout()
        grid.setHorizontalSpacing(10)
        grid.setVerticalSpacing(10)
        keys = ["swiss", "brass", "brutal", "calm"]
        for n, key in enumerate(keys):
            card = ThemeCard(theme(key), key == self.current_theme)
            card.clicked.connect(self._theme_clicked)
            self._cards[key] = card
            grid.addWidget(card, n // 2, n % 2)
        root.addLayout(grid)

        strip = QCheckBox("Strip images from clipboard (keep text only)")
        strip.setChecked(self.settings.strip_images)
        strip.toggled.connect(self._strip_toggled)
        root.addWidget(strip)
        self.strip = strip

        row = QHBoxLayout()
        row.addWidget(QLabel("History limit"))
        self.limit = QSpinBox()
        self.limit.setRange(20, 5000)
        self.limit.setSingleStep(50)
        self.limit.setValue(max(20, int(self.settings.history_limit)))
        self.limit.valueChanged.connect(self._limit_changed)
        row.addWidget(self.limit)
        row.addStretch(1)
        root.addLayout(row)

        login = QCheckBox("Start Clippr when I log in")
        login.setChecked(autostart.is_enabled())
        login.toggled.connect(self._login_toggled)
        root.addWidget(login)
        self.login = login

        line = QFrame()
        line.setObjectName("Line")
        root.addWidget(line)

        folder = QHBoxLayout()
        path_label = QLabel(f"Data folder: {self.data_dir}")
        path_label.setObjectName("Hint")
        path_label.setWordWrap(True)
        folder.addWidget(path_label, 1)
        open_btn = QPushButton("OPEN FOLDER")
        open_btn.setProperty("role", "ghost")
        open_btn.clicked.connect(lambda: open_path(self.data_dir))
        folder.addWidget(open_btn)
        root.addLayout(folder)

        root.addStretch(1)
        bottom = QHBoxLayout()
        hint = QLabel("Changes apply immediately.")
        hint.setObjectName("Hint")
        bottom.addWidget(hint)
        bottom.addStretch(1)
        done = QPushButton("DONE")
        done.setProperty("role", "primary")
        done.clicked.connect(self.accept)
        bottom.addWidget(done)
        root.addLayout(bottom)

    def _theme_clicked(self, key: str) -> None:
        self.current_theme = key
        for k, card in self._cards.items():
            card.set_selected(k == key)
        self.settings.theme = key
        self.theme_changed.emit(key)
        self.update()

    def _strip_toggled(self, value: bool) -> None:
        self.settings.strip_images = bool(value)

    def _limit_changed(self, value: int) -> None:
        self.settings.history_limit = int(value)
        self.store.history_limit = int(value)

    def _login_toggled(self, value: bool) -> None:
        try:
            if value:
                autostart.enable()
            else:
                autostart.disable()
            self.settings.start_at_login = bool(value)
        except Exception as exc:
            self.login.blockSignals(True)
            self.login.setChecked(not value)
            self.login.blockSignals(False)
            QMessageBox.warning(self, "Start at login", f"Could not update login item:\n{exc}")
