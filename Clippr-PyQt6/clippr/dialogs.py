"""Preview, settings and small prompt dialogs."""
from __future__ import annotations

from dataclasses import replace
from pathlib import Path

from PyQt6.QtCore import Qt, pyqtSignal
from PyQt6.QtGui import QPixmap
from PyQt6.QtWidgets import (
    QCheckBox,
    QComboBox,
    QDialog,
    QFormLayout,
    QFrame,
    QGroupBox,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QMessageBox,
    QPushButton,
    QScrollArea,
    QSpinBox,
    QTabWidget,
    QTextEdit,
    QVBoxLayout,
    QWidget,
)

from . import autostart
from .clipboard import ClipboardWatcher
from .config import Settings, open_path
from .ocr import ENGINES, ENGINE_LABELS, PROVIDERS, PROVIDER_LABELS, OcrWorker, make_test_image
from .store import HistoryItem, HistoryStore
from .themes import THEMES, Theme, theme


class TextPromptDialog(QDialog):
    def __init__(self, title: str, label: str, initial: str = "", parent=None):
        super().__init__(parent)
        self.setWindowTitle(title)
        self.setModal(True)
        self.setMinimumWidth(380)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(22, 20, 22, 18)
        layout.setSpacing(12)
        layout.addWidget(QLabel(label))
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

    def __init__(
        self,
        store: HistoryStore,
        item: HistoryItem,
        watcher: ClipboardWatcher,
        t: Theme,
        settings: Settings,
        parent=None,
    ):
        super().__init__(parent)
        self.store = store
        self.watcher = watcher
        self.theme = t
        self.settings = settings
        self.item = store.get(item.id) or item
        self._worker: OcrWorker | None = None
        self._notice = ""
        self.setWindowTitle("Clippr Preview")
        self.setModal(True)
        self.resize(760, 590)
        self._build()

    def _build(self) -> None:
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
                    self.image_label.setPixmap(
                        pix.scaled(700, 360, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation)
                    )
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
        self.status.setWordWrap(True)
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
        self._notice = ""
        self.status.setText("Reading text…")
        self._worker = OcrWorker(path, self.settings)
        self._worker.notice.connect(self._ocr_notice)
        self._worker.recognized.connect(self._ocr_done)
        self._worker.failed.connect(self._ocr_failed)
        self._worker.start()

    def _ocr_notice(self, notice: str) -> None:
        self._notice = notice

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
        prefix = (self._notice + " ") if self._notice else ""
        self.status.setText(prefix + f"OCR text copied ({len(text)} characters).")
        self.status.setToolTip(self._notice)
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
        self._secrets: list[QLineEdit] = []
        self._test_worker: OcrWorker | None = None
        self._test_path: Path | None = None
        self._test_notice = ""
        self.setWindowTitle("Clippr Settings")
        self.setModal(True)
        self.setMinimumSize(700, 580)
        self.resize(740, 620)
        self._build()

    # ------------------------------------------------------------------ UI
    def _build(self) -> None:
        root = QVBoxLayout(self)
        root.setContentsMargins(22, 18, 22, 16)
        root.setSpacing(10)

        head = QHBoxLayout()
        title = QLabel("Settings")
        title.setObjectName("AppTitle")
        title.setStyleSheet("font-size: 18pt;")
        head.addWidget(title)
        head.addStretch(1)
        head.addWidget(self._hint("OCR keys stay on this PC."))
        root.addLayout(head)

        self.tabs = QTabWidget()
        self.tabs.addTab(self._wrap_scroll(self._general_tab()), "GENERAL")
        self.tabs.addTab(self._wrap_scroll(self._ocr_tab()), "OCR")
        root.addWidget(self.tabs, 1)

        bottom = QHBoxLayout()
        bottom.addWidget(self._hint("Changes apply immediately; OCR keys are saved locally."))
        bottom.addStretch(1)
        done = QPushButton("DONE")
        done.setProperty("role", "primary")
        done.clicked.connect(self._done)
        bottom.addWidget(done)
        root.addLayout(bottom)

    def _hint(self, text: str) -> QLabel:
        lbl = QLabel(text)
        lbl.setObjectName("Hint")
        lbl.setWordWrap(True)
        return lbl

    def _wrap_scroll(self, inner: QWidget) -> QScrollArea:
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)
        scroll.setWidget(inner)
        return scroll

    def _general_tab(self) -> QWidget:
        inner = QWidget()
        root = QVBoxLayout(inner)
        root.setContentsMargins(14, 14, 14, 14)
        root.setSpacing(12)

        lbl = QLabel("THEME")
        lbl.setObjectName("SectionLabel")
        root.addWidget(lbl)
        theme_row = QHBoxLayout()
        self.theme_combo = QComboBox()
        for key, th in THEMES.items():
            self.theme_combo.addItem(th.name, key)
        idx = self.theme_combo.findData(self.current_theme)
        if idx < 0:
            idx = 0
        self.theme_combo.setCurrentIndex(idx)
        self.current_theme = self.theme_combo.currentData() or self.current_theme
        self.theme_combo.currentIndexChanged.connect(self._theme_selected)
        theme_row.addWidget(self.theme_combo, 1)
        root.addLayout(theme_row)
        self.theme_desc = self._hint(theme(self.current_theme).description)
        root.addWidget(self.theme_desc)

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
        return inner

    def _ocr_tab(self) -> QWidget:
        inner = QWidget()
        root = QVBoxLayout(inner)
        root.setContentsMargins(14, 12, 14, 14)
        root.setSpacing(8)

        intro = self._hint(
            "Bring your own OCR keys or point Clippr at a self-hosted OCR server. "
            "Keys are saved only in the local settings.json and are sent only to the provider you select."
        )
        root.addWidget(intro)

        form = QFormLayout()
        form.setFieldGrowthPolicy(QFormLayout.FieldGrowthPolicy.AllNonFixedFieldsGrow)
        form.setVerticalSpacing(8)
        self.provider = QComboBox()
        for key in PROVIDERS:
            label = PROVIDER_LABELS[key]
            if key == "auto":
                label = "Auto (cloud key if set, else built-in)"
            self.provider.addItem(label, key)
        self._select_data(self.provider, self.settings.ocr_provider)
        self.provider.currentIndexChanged.connect(self._refresh_provider_note)
        form.addRow("OCR provider", self.provider)

        self.engine = QComboBox()
        for key in ENGINES:
            self.engine.addItem(ENGINE_LABELS[key], key)
        self._select_data(self.engine, self.settings.ocr_builtin_engine)
        form.addRow("Built-in engine", self.engine)
        root.addLayout(form)

        self.provider_note = self._hint("")
        root.addWidget(self.provider_note)

        # OCR.space
        box = QGroupBox("OCR.space")
        f = QFormLayout(box)
        self.os_key = self._secret(self.settings.ocr_space_key)
        self.os_lang = QLineEdit(self.settings.ocr_space_language or "eng")
        f.addRow("API key", self.os_key)
        f.addRow("Language (eng, deu, hin…)", self.os_lang)
        root.addWidget(box)

        # Azure
        box = QGroupBox("Azure AI Vision")
        f = QFormLayout(box)
        self.az_endpoint = QLineEdit(self.settings.azure_endpoint)
        self.az_key = self._secret(self.settings.azure_key)
        f.addRow("Endpoint", self.az_endpoint)
        f.addRow("Subscription key", self.az_key)
        root.addWidget(box)

        # Google
        box = QGroupBox("Google Cloud Vision")
        f = QFormLayout(box)
        self.google_key = self._secret(self.settings.google_key)
        f.addRow("API key", self.google_key)
        root.addWidget(box)

        # Paddle / custom server
        box = QGroupBox("PaddleOCR / custom self-hosted server")
        f = QFormLayout(box)
        self.paddle_endpoint = QLineEdit(self.settings.paddle_endpoint)
        self.paddle_key = self._secret(self.settings.paddle_key)
        self.paddle_header = QLineEdit(self.settings.paddle_key_header or "Authorization")
        self.paddle_mode = QComboBox()
        for label, key in (
            ("PaddleHub JSON (images[])", "hub"),
            ("Multipart form (file)", "multipart"),
            ("Gravitee / image_url (input[])", "image_url"),
        ):
            self.paddle_mode.addItem(label, key)
        self._select_data(self.paddle_mode, self.settings.paddle_mode)
        self.paddle_token_url = QLineEdit(self.settings.paddle_token_url)
        self.paddle_client_id = QLineEdit(self.settings.paddle_client_id)
        self.paddle_client_secret = self._secret(self.settings.paddle_client_secret)
        self.paddle_scope = QLineEdit(self.settings.paddle_scope)
        f.addRow("Endpoint URL", self.paddle_endpoint)
        f.addRow("API key (optional)", self.paddle_key)
        f.addRow("Key header", self.paddle_header)
        f.addRow("Request mode", self.paddle_mode)
        f.addRow("OAuth2 token URL", self.paddle_token_url)
        f.addRow("Client ID", self.paddle_client_id)
        f.addRow("Client secret", self.paddle_client_secret)
        f.addRow("Scope (optional)", self.paddle_scope)
        root.addWidget(box)

        show = QCheckBox("Show keys")
        show.toggled.connect(self._toggle_secrets)
        root.addWidget(show)

        self.auto_name = QCheckBox("Auto-name new images with OCR (may use the selected provider)")
        self.auto_name.setChecked(bool(self.settings.ocr_auto_name_images))
        root.addWidget(self.auto_name)

        actions = QHBoxLayout()
        self.btn_test = QPushButton("AUTHENTICATE")
        self.btn_test.setProperty("role", "primary")
        self.btn_test.clicked.connect(self._test_provider)
        actions.addWidget(self.btn_test)
        self.test_status = self._hint("")
        actions.addWidget(self.test_status, 1)
        root.addLayout(actions)

        help_text = self._hint(
            "Where to get keys: OCR.space (ocr.space/ocrapi, free tier), Azure AI Vision "
            "(Computer Vision resource), Google Cloud Vision (enable API + key), or a "
            "PaddleOCR server. Paddle modes: PaddleHub JSON, multipart, or Gravitee image_url. "
            "The Authenticate button runs the selected provider on a small test image."
        )
        root.addWidget(help_text)
        root.addStretch(1)
        self._refresh_provider_note()
        return inner

    def _secret(self, value: str) -> QLineEdit:
        edit = QLineEdit(value)
        edit.setEchoMode(QLineEdit.EchoMode.Password)
        self._secrets.append(edit)
        return edit

    def _select_data(self, combo: QComboBox, value: str) -> None:
        idx = combo.findData(value)
        combo.setCurrentIndex(idx if idx >= 0 else 0)

    # --------------------------------------------------------------- actions
    def _theme_selected(self, _index: int) -> None:
        key = self.theme_combo.currentData()
        if not key:
            return
        self.current_theme = key
        self.settings.theme = key
        self.theme_desc.setText(theme(key).description)
        self.theme_changed.emit(key)
        self.update()

    def _select_theme(self, key: str) -> None:
        idx = self.theme_combo.findData(key)
        if idx >= 0:
            self.theme_combo.setCurrentIndex(idx)

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

    def _toggle_secrets(self, show: bool) -> None:
        mode = QLineEdit.EchoMode.Normal if show else QLineEdit.EchoMode.Password
        for edit in self._secrets:
            edit.setEchoMode(mode)

    def _refresh_provider_note(self) -> None:
        provider = self.provider.currentData()
        if provider == "builtin":
            note = (
                "Built-in OCR uses the engine above. Auto chooses Windows OCR on Windows and "
                "Apple Vision on macOS, with Tesseract as a fallback. Explicit Windows/macOS "
                "choices fail with a clear message on the other OS."
            )
        elif provider == "auto":
            note = (
                "Auto uses a configured cloud provider first (OCR.space, Azure, Google, then Paddle). "
                "If none is configured, it uses the built-in engine above. Cloud failures fall back "
                "to built-in OCR with a notice."
            )
        else:
            note = f"{PROVIDER_LABELS.get(provider, 'This provider')} is tried first; if it fails, built-in OCR is used as a fallback."
        self.provider_note.setText(note)

    def _ocr_values(self) -> Settings:
        provider = self.provider.currentData() or "auto"
        return replace(
            self.settings,
            ocr_provider=provider,
            ocr_builtin_engine=self.engine.currentData() or "auto",
            ocr_space_key=self.os_key.text().strip(),
            ocr_space_language=self.os_lang.text().strip() or "eng",
            azure_endpoint=self.az_endpoint.text().strip(),
            azure_key=self.az_key.text().strip(),
            google_key=self.google_key.text().strip(),
            paddle_endpoint=self.paddle_endpoint.text().strip(),
            paddle_key=self.paddle_key.text().strip(),
            paddle_key_header=self.paddle_header.text().strip() or "Authorization",
            paddle_mode=self.paddle_mode.currentData() or "hub",
            paddle_token_url=self.paddle_token_url.text().strip(),
            paddle_client_id=self.paddle_client_id.text().strip(),
            paddle_client_secret=self.paddle_client_secret.text().strip(),
            paddle_scope=self.paddle_scope.text().strip(),
            ocr_auto_name_images=bool(self.auto_name.isChecked()),
        )

    def _apply_ocr_values(self) -> None:
        values = self._ocr_values()
        for field in (
            "ocr_provider", "ocr_builtin_engine", "ocr_space_key", "ocr_space_language",
            "azure_endpoint", "azure_key", "google_key", "paddle_endpoint", "paddle_key",
            "paddle_key_header", "paddle_mode", "paddle_token_url", "paddle_client_id",
            "paddle_client_secret", "paddle_scope", "ocr_auto_name_images",
        ):
            setattr(self.settings, field, getattr(values, field))

    def _done(self) -> None:
        self._apply_ocr_values()
        self.accept()

    def closeEvent(self, event) -> None:  # noqa: N802
        self._apply_ocr_values()
        super().closeEvent(event)

    def _test_provider(self) -> None:
        if self._test_worker is not None and self._test_worker.isRunning():
            return
        self._test_notice = ""
        self.test_status.setText("Testing the selected provider…")
        self.btn_test.setEnabled(False)
        try:
            self._test_path = make_test_image("Clippr OCR key test 12345")
        except Exception as exc:
            self.btn_test.setEnabled(True)
            self.test_status.setText(f"Could not create test image: {exc}")
            return
        self._test_worker = OcrWorker(self._test_path, self._ocr_values())
        self._test_worker.notice.connect(self._test_notice_received)
        self._test_worker.recognized.connect(self._test_ok)
        self._test_worker.failed.connect(self._test_failed)
        self._test_worker.finished.connect(self._test_cleanup)
        self._test_worker.start()

    def _test_notice_received(self, notice: str) -> None:
        self._test_notice = notice

    def _test_ok(self, text: str) -> None:
        self.btn_test.setEnabled(True)
        flat = " ".join((text or "").split())
        if len(flat) > 90:
            flat = flat[:90] + "…"
        prefix = (self._test_notice + " ") if self._test_notice else "Authenticated. "
        self.test_status.setText(prefix + "Read: " + (flat or "(no text)"))

    def _test_failed(self, message: str) -> None:
        self.btn_test.setEnabled(True)
        self.test_status.setText("Authentication failed: " + message)

    def _test_cleanup(self) -> None:
        if self._test_path is not None:
            self._test_path.unlink(missing_ok=True)
            self._test_path = None
        if self._test_worker is not None:
            self._test_worker.deleteLater()
            self._test_worker = None
