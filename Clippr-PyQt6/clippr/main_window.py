"""Main Clippr window."""
from __future__ import annotations

import time
from pathlib import Path

from PyQt6.QtCore import QByteArray, QModelIndex, QPoint, Qt, QTimer, pyqtSignal
from PyQt6.QtGui import QAction, QCloseEvent, QFont, QIcon, QKeySequence, QPixmap, QShortcut
from PyQt6.QtWidgets import (
    QApplication,
    QCheckBox,
    QFrame,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QMainWindow,
    QMenu,
    QMessageBox,
    QPushButton,
    QSizePolicy,
    QVBoxLayout,
    QWidget,
)

from .capture import capture_screen_region
from .clipboard import ClipboardWatcher, image_to_png
from .config import Settings, app_asset, app_data_dir, open_path, system_font_family
from .dialogs import PreviewDialog, SettingsDialog, TextPromptDialog
from .ocr import OcrWorker
from .store import GENERAL_TAB, VIEW_ALL, VIEW_IMAGES, VIEW_NAMES, VIEW_TEXT, HistoryItem, HistoryStore
from .themes import build_qss, theme
from .widgets import HistoryDelegate, HistoryListModel, SmoothListView, TabList


class MainWindow(QMainWindow):
    hidden_to_tray = pyqtSignal()
    notify = pyqtSignal(str, str)
    capture_paused_changed = pyqtSignal(bool)

    def __init__(self, store: HistoryStore, settings: Settings, settings_path: Path, data_dir: Path, theme_key: str):
        super().__init__()
        self.store = store
        self.settings = settings
        self.settings_path = settings_path
        self.data_dir = data_dir
        self.theme_key = theme_key
        self.theme = theme(theme_key)
        self._allow_close = False
        self._worker: OcrWorker | None = None
        self._auto_workers: set[OcrWorker] = set()
        self._save_timer = QTimer(self)
        self._save_timer.setSingleShot(True)
        self._save_timer.setInterval(280)
        self._save_timer.timeout.connect(self.save_now)
        self._search_timer = QTimer(self)
        self._search_timer.setSingleShot(True)
        self._search_timer.setInterval(130)
        self._search_timer.timeout.connect(self.refresh_history)
        self._select_after_refresh: str | None = None
        self._status_timer = QTimer(self)
        self._status_timer.setSingleShot(True)
        self._status_timer.timeout.connect(self._default_status)

        self.watcher = ClipboardWatcher(self.store, lambda: self.settings, self)
        self._build()
        self._restore_geometry()
        self.apply_theme(theme_key, save=False)
        self.watcher.item_added.connect(self._on_item_added)
        self.watcher.message.connect(self._status)
        self.watcher.start()
        self.refresh_tabs()
        self.refresh_history()
        self._relative_timer = QTimer(self)
        self._relative_timer.setInterval(60000)
        self._relative_timer.timeout.connect(lambda: self.list.viewport().update())
        self._relative_timer.start()

    # ------------------------------------------------------------------ UI
    def _build(self) -> None:
        self.setWindowTitle("Clippr")
        icon_path = app_asset("clippr.png")
        if icon_path.exists():
            self.setWindowIcon(QIcon(str(icon_path)))
            self._icon_pixmap = QPixmap(str(icon_path)).scaled(
                48, 48, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation
            )
        else:
            self._icon_pixmap = None
        self.resize(1040, 704)
        self.setMinimumSize(860, 560)

        central = QWidget()
        central.setObjectName("Root")
        self.setCentralWidget(central)
        root = QVBoxLayout(central)
        root.setContentsMargins(22, 14, 22, 12)
        root.setSpacing(10)

        # header
        header = QFrame()
        header.setObjectName("Header")
        h = QHBoxLayout(header)
        h.setContentsMargins(0, 0, 0, 0)
        h.setSpacing(12)
        self.logo = QLabel()
        self.logo.setFixedSize(48, 48)
        self.logo.setScaledContents(True)
        if icon_path.exists():
            self.logo.setPixmap(QPixmap(str(icon_path)))
        h.addWidget(self.logo)
        titles = QVBoxLayout()
        titles.setSpacing(0)
        title = QLabel("Clippr")
        title.setObjectName("AppTitle")
        subtitle = QLabel("· FRIENDLY NEIGHBORHOOD CLIPBOARD MANAGER")
        subtitle.setObjectName("AppSubtitle")
        titles.addWidget(title)
        titles.addWidget(subtitle)
        h.addLayout(titles)
        h.addSpacing(6)
        self.btn_top_capture = QPushButton("NEW SNIP")
        self.btn_top_capture.setObjectName("TopCapture")
        self.btn_top_capture.setMinimumWidth(104)
        self.btn_top_capture.setToolTip("Create a new snip (Ctrl+Shift+S)")
        self.btn_top_capture.clicked.connect(self.capture_region)
        h.addWidget(self.btn_top_capture)
        h.addStretch(1)
        self.btn_settings = QPushButton("SETTINGS")
        self.btn_settings.setProperty("role", "ghost")
        self.btn_settings.clicked.connect(self.open_settings)
        h.addWidget(self.btn_settings)
        self.btn_capture = QPushButton("● CAPTURING")
        self.btn_capture.setProperty("role", "capture")
        self.btn_capture.setMinimumWidth(140)
        self.btn_capture.clicked.connect(self.toggle_capture)
        h.addWidget(self.btn_capture)
        root.addWidget(header)

        line = QFrame()
        line.setObjectName("Line")
        root.addWidget(line)

        content = QHBoxLayout()
        content.setSpacing(14)
        content.setContentsMargins(0, 0, 0, 0)
        root.addLayout(content, 1)

        # sidebar
        sidebar = QFrame()
        sidebar.setObjectName("Sidebar")
        sidebar.setFixedWidth(222)
        side = QVBoxLayout(sidebar)
        side.setContentsMargins(14, 12, 12, 12)
        side.setSpacing(8)
        tabs_label = QLabel("VIEWS & TABS")
        tabs_label.setObjectName("SectionLabel")
        side.addWidget(tabs_label)
        self.tabs = TabList()
        self.tabs.set_theme(self.theme)
        self.tabs.currentRowChanged.connect(self._tab_row_changed)
        self.tabs.customContextMenuRequested.connect(self._tabs_context_menu)
        self.tabs.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        side.addWidget(self.tabs, 1)
        for text, slot, role in (
            ("＋  NEW TAB", self.new_tab, "soft"),
            ("RENAME TAB", self.rename_tab, "soft"),
            ("DELETE TAB", self.delete_tab, "soft"),
        ):
            btn = QPushButton(text)
            btn.setProperty("role", role)
            btn.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
            btn.clicked.connect(slot)
            side.addWidget(btn)
            if text.startswith("＋"):
                self.btn_new_tab = btn
            elif text.startswith("RENAME"):
                self.btn_rename_tab = btn
            else:
                self.btn_delete_tab = btn
        content.addWidget(sidebar)

        # main column
        main = QWidget()
        mv = QVBoxLayout(main)
        mv.setContentsMargins(0, 0, 0, 0)
        mv.setSpacing(8)
        self.search = QLineEdit()
        self.search.setPlaceholderText("Search clipboard history…")
        self.search.setClearButtonEnabled(True)
        self.search.textChanged.connect(self._search_changed)
        self.search.setMinimumHeight(38)
        mv.addWidget(self.search)

        self.model = HistoryListModel(self)
        self.list = SmoothListView()
        self.list.setModel(self.model)
        self.delegate = HistoryDelegate(self.store, self.theme, self)
        self.delegate.set_theme(self.theme)
        self.list.setItemDelegate(self.delegate)
        self.list.selectionModel().currentChanged.connect(self._selection_changed)
        self.list.doubleClicked.connect(lambda _idx: self.preview_selected())
        self.list.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self.list.customContextMenuRequested.connect(self._list_context_menu)
        self.list.set_empty_message("Nothing here yet", "Copy text or an image to get started", self.theme.muted)
        mv.addWidget(self.list, 1)

        # action bar
        actionbar = QFrame()
        actionbar.setObjectName("ActionBar")
        a = QHBoxLayout(actionbar)
        a.setContentsMargins(0, 0, 0, 0)
        a.setSpacing(7)
        self.btn_copy = self._action_button("COPY", self.copy_selected, "primary")
        self.btn_preview = self._action_button("PREVIEW", self.preview_selected)
        self.btn_ocr = self._action_button("OCR", self.ocr_selected)
        self.btn_delete = self._action_button("DELETE", self.delete_selected, "danger")
        self.btn_clear = self._action_button("CLEAR", self.clear_view, "danger")
        for b in (self.btn_copy, self.btn_preview, self.btn_ocr, self.btn_delete, self.btn_clear):
            a.addWidget(b)
        a.addStretch(1)
        self.chk_strip = QCheckBox("Strip images (text only)")
        self.chk_strip.setChecked(self.settings.strip_images)
        self.chk_strip.toggled.connect(self._strip_toggled)
        a.addWidget(self.chk_strip)
        mv.addWidget(actionbar)

        footer = QFrame()
        footer_line = QVBoxLayout(footer)
        footer_line.setContentsMargins(0, 0, 0, 0)
        footer_line.setSpacing(3)
        line2 = QFrame()
        line2.setObjectName("Line")
        footer_line.addWidget(line2)
        self.status = QLabel("")
        self.status.setObjectName("Status")
        self.status.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Preferred)
        self.status.setMinimumWidth(0)
        footer_line.addWidget(self.status)
        mv.addWidget(footer)
        content.addWidget(main, 1)

        find_sc = QShortcut(QKeySequence.StandardKey.Find, self)
        find_sc.activated.connect(self.search.setFocus)
        capture_sc = QShortcut(QKeySequence("Ctrl+Shift+S"), self)
        capture_sc.activated.connect(self.capture_region)
        delete_sc = QShortcut(QKeySequence(Qt.Key.Key_Delete), self.list)
        delete_sc.setContext(Qt.ShortcutContext.WidgetWithChildrenShortcut)
        delete_sc.activated.connect(self.delete_selected)
        self._shortcuts = (find_sc, capture_sc, delete_sc)
        self.list.setToolTip("Double-click to preview. Right-click for actions.")

    def _action_button(self, text: str, slot, role: str | None = None) -> QPushButton:
        b = QPushButton(text)
        if role:
            b.setProperty("role", role)
        b.setMinimumWidth(62)
        b.clicked.connect(slot)
        return b

    # -------------------------------------------------------------- theming
    def apply_theme(self, key: str, save: bool = True) -> None:
        t = theme(key)
        self.theme_key = key
        self.theme = t
        self.settings.theme = key
        mono = t.mono
        family = "Consolas" if mono and QApplication.platformName() != "cocoa" else ("SF Mono" if mono else system_font_family())
        app = QApplication.instance()
        f = QFont(family)
        f.setPointSizeF(9.5)
        if mono:
            f.setStyleHint(QFont.StyleHint.Monospace)
        app.setFont(f)
        app.setStyleSheet(build_qss(t))
        self.delegate.set_theme(t)
        self.tabs.set_theme(t)
        self.list.set_theme_muted(t.muted)
        if self.model.rowCount() == 0:
            self.list.set_empty_message("Nothing here yet", "Copy text or an image to get started", t.muted)
        self.list.viewport().update()
        self.tabs.viewport().update()
        self.update_capture_button()
        self._default_status()
        if save:
            self._schedule_save()

    # ------------------------------------------------------------- data/ui
    def _counts(self) -> dict[str, int]:
        counts = {name: self.store.tab_count(name) for name in VIEW_NAMES}
        for tab in self.store.tabs:
            counts[tab] = self.store.tab_count(tab)
        return counts

    def refresh_tabs(self) -> None:
        self.tabs.populate(self.store.tabs, VIEW_NAMES, self._counts(), self.store.active_tab)
        is_tab = self.store.active_tab in self.store.tabs
        self.btn_rename_tab.setEnabled(is_tab and self.store.active_tab != GENERAL_TAB)
        self.btn_delete_tab.setEnabled(is_tab and self.store.active_tab != GENERAL_TAB)

    def refresh_history(self, keep_selection: bool = True) -> None:
        current = self.current_item()
        keep_id = current.id if (keep_selection and current) else None
        if self._select_after_refresh:
            keep_id = self._select_after_refresh
            self._select_after_refresh = None
        items = self.store.filtered(self.store.active_tab, self.search.text())
        self.model.set_items(items)
        if keep_id:
            row = self.model.row_of(keep_id)
            if row >= 0:
                self.list.setCurrentIndex(self.model.index(row, 0))
        if not self.list.currentIndex().isValid() and items:
            self.list.setCurrentIndex(self.model.index(0, 0))
        self.list.refresh_empty()
        if not items:
            if self.search.text().strip():
                self.list.set_empty_message("No matches", "Try a different search, or clear the search box.", self.theme.muted)
            elif self.store.active_tab in self.store.tabs:
                self.list.set_empty_message("This tab is empty", "New clips can land here while this tab is active.", self.theme.muted)
            else:
                self.list.set_empty_message("Nothing here yet", "Copy text or an image to get started", self.theme.muted)
        self.update_actions()
        self._default_status()

    def update_actions(self) -> None:
        item = self.current_item()
        has = item is not None
        self.btn_copy.setEnabled(has)
        self.btn_preview.setEnabled(has)
        self.btn_ocr.setEnabled(has and item.kind == "image")
        self.btn_delete.setEnabled(has)
        self.btn_clear.setEnabled(self.model.rowCount() > 0)

    def current_item(self) -> HistoryItem | None:
        idx = self.list.currentIndex()
        return self.model.item_at(idx) if idx.isValid() else None

    def _selection_changed(self, current: QModelIndex, previous: QModelIndex) -> None:
        self.update_actions()

    def _search_changed(self, _text: str) -> None:
        self._search_timer.start()

    def _tab_row_changed(self, row: int) -> None:
        if row < 0:
            return
        item = self.tabs.item(row)
        if item is None:
            return
        name = item.data(Qt.ItemDataRole.UserRole + 3)
        if name:
            self.store.active_tab = name
            self._schedule_save()
            self.refresh_tabs()
            self.refresh_history(keep_selection=False)

    # -------------------------------------------------------------- actions
    def _on_item_added(self, item: HistoryItem) -> None:
        self._schedule_save()
        self._select_after_refresh = item.id
        self.refresh_tabs()
        self.refresh_history(keep_selection=False)
        if item.kind == "image" and self.settings.ocr_auto_name_images:
            self._auto_name_image(item)
        self._status("Clipboard captured. New clips go to '" + self.store.target_tab() + "'.")

    def _default_status(self) -> None:
        if not hasattr(self, "status"):
            return
        view = self.store.active_tab
        total = self.model.rowCount()
        target = self.store.target_tab()
        self.status.setText(
            f"{total} item(s) in '{view}' view    |    New clips go to '{target}'    |    Saved locally"
        )
        self.status.setToolTip(f"Data folder: {self.data_dir}")

    def _status(self, text: str, timeout: int = 5000) -> None:
        if not hasattr(self, "status"):
            return
        if hasattr(self, "_status_timer"):
            self._status_timer.stop()
        self.status.setText(text)
        if timeout:
            self._status_timer.start(timeout)

    def copy_selected(self) -> None:
        item = self.current_item()
        if item is None:
            return
        if self.watcher.copy_item(item):
            self._status(f"Copied {'image' if item.kind == 'image' else 'text'} to clipboard.")
        else:
            self._status("Could not copy this item.")

    def preview_selected(self) -> None:
        item = self.current_item()
        if item is None:
            return
        dlg = PreviewDialog(self.store, item, self.watcher, self.theme, self.settings, self)
        dlg.item_updated.connect(self._preview_updated)
        dlg.exec()
        self.refresh_history()

    def _preview_updated(self, item_id: str) -> None:
        self._schedule_save()
        self.refresh_history()

    def capture_region(self) -> None:
        try:
            image = capture_screen_region(self.theme, self)
        except Exception as exc:
            QMessageBox.warning(self, "New Snip", f"Could not create a snip:\n{exc}")
            return
        if image is None or image.isNull():
            return
        png = image_to_png(image)
        if not png:
            QMessageBox.warning(self, "New Snip", "The snip could not be encoded.")
            return
        item = self.store.add_image(png, image.width(), image.height())
        if item is None:
            item = self.store.items[0] if self.store.items else None
        if item is not None:
            self.watcher.copy_item(item)
            if self.settings.ocr_auto_name_images:
                self._auto_name_image(item)
        self.refresh_tabs()
        self.refresh_history()
        self._status("Snip captured and copied.")
        self._schedule_save()

    def ocr_selected(self) -> None:
        item = self.current_item()
        if item is None or item.kind != "image":
            return
        path = self.store.image_path(item)
        if path is None:
            self._status("Image file is missing.")
            return
        self.btn_ocr.setEnabled(False)
        self._status("Reading text from image...", 0)
        self._ocr_notice = ""
        self._worker = OcrWorker(path, self.settings)
        self._worker.notice.connect(self._ocr_notice_received)
        self._worker.recognized.connect(lambda text, item_id=item.id: self._ocr_done(item_id, text))
        self._worker.failed.connect(self._ocr_failed)
        self._worker.start()

    def _ocr_notice_received(self, notice: str) -> None:
        self._ocr_notice = notice

    def _ocr_done(self, item_id: str, text: str) -> None:
        self.update_actions()
        if not text:
            self._status("No text found in that image.")
            return
        self.store.update_ocr(item_id, text)
        self.watcher.copy_text(text)
        self._schedule_save()
        self.refresh_history()
        prefix = (getattr(self, "_ocr_notice", "") + " ") if getattr(self, "_ocr_notice", "") else ""
        self._status(prefix + f"OCR text copied ({len(text)} characters).", 9000)

    def _ocr_failed(self, message: str) -> None:
        self.update_actions()
        self._status("OCR failed.")
        QMessageBox.warning(self, "OCR unavailable", message)
    def _auto_name_image(self, item: HistoryItem) -> None:
        path = self.store.image_path(item)
        if path is None:
            return
        worker = OcrWorker(path, self.settings)
        self._auto_workers.add(worker)
        worker.recognized.connect(lambda text, item_id=item.id: self._auto_name_done(item_id, text))
        worker.failed.connect(lambda _msg: None)
        worker.finished.connect(lambda w=worker: self._auto_workers.discard(w))
        worker.start()

    def _auto_name_done(self, item_id: str, text: str) -> None:
        text = (text or "").strip()
        if not text:
            return
        item = self.store.get(item_id)
        if item is None:
            return
        if not item.ocr_text:
            item.ocr_text = text
        if not item.text.strip():
            first = text.splitlines()[0] if text.splitlines() else text
            item.text = " ".join(first.split())[:90]
            self._schedule_save()
            self.refresh_history()
            self._status("Image auto-named from OCR.")
        else:
            self._schedule_save()


    def delete_selected(self) -> None:
        item = self.current_item()
        if item is None:
            return
        if self.store.delete(item.id):
            self._schedule_save()
            self.refresh_tabs()
            self.refresh_history()
            self._status("Item deleted.")

    def clear_view(self) -> None:
        view = self.store.active_tab
        count = self.model.rowCount()
        if count == 0:
            return
        answer = QMessageBox.question(
            self, "Clear view", f"Delete {count} item(s) from '{view}'?\nThis cannot be undone.",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            QMessageBox.StandardButton.No,
        )
        if answer != QMessageBox.StandardButton.Yes:
            return
        n = self.store.clear_view(view)
        self._schedule_save()
        self.refresh_tabs()
        self.refresh_history()
        self._status(f"Deleted {n} item(s) from '{view}'.")

    def new_tab(self) -> None:
        name = TextPromptDialog.get_text(self, "New tab", "Tab name", "")
        if not name:
            return
        if not self.store.add_tab(name):
            QMessageBox.information(self, "New tab", "That name is already used, or it is a built-in view.")
            return
        self.store.active_tab = name
        self._schedule_save()
        self.refresh_tabs()
        self.refresh_history(keep_selection=False)

    def rename_tab(self) -> None:
        name = self.store.active_tab
        if name not in self.store.tabs or name == GENERAL_TAB:
            return
        new = TextPromptDialog.get_text(self, "Rename tab", "New tab name", name)
        if not new:
            return
        if not self.store.rename_tab(name, new):
            QMessageBox.information(self, "Rename tab", "That name is already used, or it is invalid.")
            return
        self._schedule_save()
        self.refresh_tabs()
        self.refresh_history()

    def delete_tab(self) -> None:
        name = self.store.active_tab
        if name not in self.store.tabs or name == GENERAL_TAB:
            return
        answer = QMessageBox.question(
            self, "Delete tab", f"Delete '{name}' and all of its items?",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            QMessageBox.StandardButton.No,
        )
        if answer != QMessageBox.StandardButton.Yes:
            return
        self.store.delete_tab(name)
        self._schedule_save()
        self.refresh_tabs()
        self.refresh_history(keep_selection=False)
        self._status("Tab deleted.")

    def toggle_capture(self) -> None:
        self.settings.capture_paused = not self.settings.capture_paused
        self.update_capture_button()
        self._schedule_save()
        self.capture_paused_changed.emit(bool(self.settings.capture_paused))
        self._status("Capture paused." if self.settings.capture_paused else "Capture resumed.")

    def update_capture_button(self) -> None:
        paused = bool(self.settings.capture_paused)
        self.btn_capture.setText("○ PAUSED" if paused else "● CAPTURING")
        self.btn_capture.setProperty("paused", "true" if paused else "false")
        self.btn_capture.style().unpolish(self.btn_capture)
        self.btn_capture.style().polish(self.btn_capture)

    def _strip_toggled(self, value: bool) -> None:
        self.settings.strip_images = bool(value)
        self._schedule_save()
        self._status("Images will be stripped from the clipboard." if value else "Image clips will be kept intact.")

    def open_settings(self) -> None:
        dlg = SettingsDialog(self.settings, self.store, self.data_dir, self.theme_key, self)
        dlg.theme_changed.connect(lambda key: self.apply_theme(key, save=True))
        dlg.exec()
        self.store.history_limit = max(20, int(self.settings.history_limit))
        self.store.prune()
        self.chk_strip.setChecked(self.settings.strip_images)
        self.update_capture_button()
        self._schedule_save()
        self.refresh_tabs()
        self.refresh_history()

    # ------------------------------------------------------------- context
    def _list_context_menu(self, pos: QPoint) -> None:
        idx = self.list.indexAt(pos)
        if not idx.isValid():
            return
        self.list.setCurrentIndex(idx)
        item = self.current_item()
        if item is None:
            return
        menu = QMenu(self)
        copy = QAction("Copy", self)
        copy.triggered.connect(self.copy_selected)
        preview = QAction("Preview", self)
        preview.triggered.connect(self.preview_selected)
        ocr = QAction("OCR + copy", self)
        ocr.setEnabled(item.kind == "image")
        ocr.triggered.connect(self.ocr_selected)
        delete = QAction("Delete", self)
        delete.triggered.connect(self.delete_selected)
        menu.addAction(copy)
        menu.addAction(preview)
        menu.addAction(ocr)
        menu.addSeparator()
        menu.addAction(delete)
        menu.exec(self.list.viewport().mapToGlobal(pos))

    def _tabs_context_menu(self, pos: QPoint) -> None:
        item = self.tabs.itemAt(pos)
        if item is None:
            return
        name = item.data(Qt.ItemDataRole.UserRole + 3)
        kind = item.data(Qt.ItemDataRole.UserRole + 2)
        self.tabs.setCurrentItem(item)
        menu = QMenu(self)
        if kind == "tab" and name != GENERAL_TAB:
            rename = QAction("Rename tab", self)
            rename.triggered.connect(self.rename_tab)
            delete = QAction("Delete tab", self)
            delete.triggered.connect(self.delete_tab)
            menu.addAction(rename)
            menu.addAction(delete)
        new = QAction("New tab", self)
        new.triggered.connect(self.new_tab)
        menu.addAction(new)
        if menu.actions():
            menu.exec(self.tabs.viewport().mapToGlobal(pos))

    # ---------------------------------------------------------- persistence
    def save_now(self) -> None:
        try:
            self.store.history_limit = max(20, int(self.settings.history_limit))
            self.store.save()
            self.settings.save(self.settings_path)
        except Exception as exc:
            self._status(f"Could not save: {exc}", 8000)

    def _schedule_save(self) -> None:
        self._save_timer.start()
        self.settings.window_geometry = bytes(self.saveGeometry().toBase64()).decode("ascii")

    def _restore_geometry(self) -> None:
        raw = self.settings.window_geometry
        if raw:
            try:
                self.restoreGeometry(QByteArray.fromBase64(raw.encode("ascii")))
            except Exception:
                pass

    def show_normal(self) -> None:
        self.show()
        if self.isMinimized():
            self.showNormal()
        self.raise_()
        self.activateWindow()

    def closeEvent(self, event: QCloseEvent) -> None:  # noqa: N802
        self.settings.window_geometry = bytes(self.saveGeometry().toBase64()).decode("ascii")
        self.save_now()
        if self._allow_close:
            event.accept()
            return
        event.ignore()
        self.hide()
        self.hidden_to_tray.emit()
