"""Application controller, tray integration and single-instance handling."""
from __future__ import annotations

import sys

from PyQt6.QtCore import QTimer
from PyQt6.QtGui import QAction, QFont, QIcon
from PyQt6.QtNetwork import QLocalServer, QLocalSocket
from PyQt6.QtWidgets import QApplication, QMenu, QMessageBox, QSystemTrayIcon

from .config import APP_NAME, VERSION, Settings, app_asset, app_data_dir, platform_name, system_font_family
from .main_window import MainWindow
from .store import HistoryStore
from .themes import theme
from .widgets import Toast

SERVER_NAME = "ClipprPy.SingleInstance"


class ClipprApp:
    def __init__(self, argv: list[str]):
        self.qapp = QApplication(argv)
        self.qapp.setApplicationName(APP_NAME)
        self.qapp.setOrganizationName("Clippr")
        self.qapp.setApplicationDisplayName(APP_NAME)
        self.qapp.setQuitOnLastWindowClosed(False)
        _f = QFont(system_font_family())
        _f.setPointSizeF(9.5)
        self.qapp.setFont(_f)
        icon_path = app_asset("clippr.png")
        self.icon = QIcon(str(icon_path)) if icon_path.exists() else QIcon()
        self.qapp.setWindowIcon(self.icon)
        self.window: MainWindow | None = None
        self.tray: QSystemTrayIcon | None = None
        self.toast: Toast | None = None
        self._tray_pause: QAction | None = None
        self._server: QLocalServer | None = None

        if self._send_to_existing():
            self.qapp.quit()
            return

        self.data_dir = app_data_dir()
        self.settings_path = self.data_dir / "settings.json"
        self.settings = Settings.load(self.settings_path)
        self.store = HistoryStore(self.data_dir, self.settings.history_limit)
        self.window = MainWindow(self.store, self.settings, self.settings_path, self.data_dir, self.settings.theme)
        self.window.hidden_to_tray.connect(self._on_hidden_to_tray)
        self.window.capture_paused_changed.connect(self._sync_tray_pause)
        self._start_server()
        self._build_tray()
        if self.tray is None:
            self.window._allow_close = True
            self.qapp.setQuitOnLastWindowClosed(True)
        self.qapp.aboutToQuit.connect(self._about_to_quit)
        if "--hidden" not in argv or self.tray is None:
            QTimer.singleShot(0, self.window.show)

    def _send_to_existing(self) -> bool:
        sock = QLocalSocket()
        sock.connectToServer(SERVER_NAME)
        if not sock.waitForConnected(250):
            return False
        sock.write(b"show")
        sock.waitForBytesWritten(500)
        sock.disconnectFromServer()
        return True

    def _start_server(self) -> None:
        self._server = QLocalServer(self.qapp)
        if not self._server.listen(SERVER_NAME):
            QLocalServer.removeServer(SERVER_NAME)
            self._server.listen(SERVER_NAME)
        self._server.newConnection.connect(self._new_connection)

    def _new_connection(self) -> None:
        if self._server is None:
            return
        while self._server.hasPendingConnections():
            sock = self._server.nextPendingConnection()
            if sock is None:
                continue
            try:
                sock.readAll()
                sock.disconnectFromServer()
            except Exception:
                pass
            if self.window is not None:
                self.window.show_normal()

    def _build_tray(self) -> None:
        if not QSystemTrayIcon.isSystemTrayAvailable():
            return
        tray = QSystemTrayIcon(self.icon, self.qapp)
        tray.setToolTip(f"Clippr {VERSION} — clipboard manager")
        menu = QMenu()
        open_action = QAction("Open Clippr", menu)
        open_action.triggered.connect(self._show)
        capture_action = QAction("New Snip…", menu)
        capture_action.triggered.connect(self._capture)
        self._tray_pause = QAction("Pause capture", menu)
        self._tray_pause.setCheckable(True)
        self._tray_pause.setChecked(bool(self.settings.capture_paused))
        self._tray_pause.toggled.connect(self._tray_pause_toggled)
        settings_action = QAction("Settings…", menu)
        settings_action.triggered.connect(self._settings)
        about_action = QAction("About Clippr", menu)
        about_action.triggered.connect(self._about)
        quit_action = QAction("Quit", menu)
        quit_action.triggered.connect(self.quit)
        menu.addAction(open_action)
        menu.addAction(capture_action)
        menu.addAction(self._tray_pause)
        menu.addAction(settings_action)
        menu.addSeparator()
        menu.addAction(about_action)
        menu.addAction(quit_action)
        tray.setContextMenu(menu)
        self._sync_tray_pause(bool(self.settings.capture_paused))
        tray.activated.connect(self._tray_activated)
        tray.show()
        self.tray = tray
        self._tray_menu = menu

    def _tray_activated(self, reason: QSystemTrayIcon.ActivationReason) -> None:
        if reason == QSystemTrayIcon.ActivationReason.DoubleClick:
            self._show()
        elif reason == QSystemTrayIcon.ActivationReason.Trigger and sys.platform != "darwin":
            self._show()

    def _show(self) -> None:
        if self.window is not None:
            self.window.show_normal()

    def _capture(self) -> None:
        if self.window is None:
            return
        self.window.show_normal()
        QTimer.singleShot(180, self.window.capture_region)

    def _settings(self) -> None:
        if self.window is None:
            return
        self.window.show_normal()
        QTimer.singleShot(120, self.window.open_settings)

    def _tray_pause_toggled(self, checked: bool) -> None:
        if self.window is None:
            return
        self.window.settings.capture_paused = bool(checked)
        self.window.update_capture_button()
        self.window.save_now()
        if self._tray_pause is not None:
            self._sync_tray_pause(checked)

    def _sync_tray_pause(self, checked: bool) -> None:
        if self._tray_pause is None:
            return
        self._tray_pause.blockSignals(True)
        self._tray_pause.setChecked(bool(checked))
        self._tray_pause.setText("Resume capture" if checked else "Pause capture")
        self._tray_pause.blockSignals(False)

    def _on_hidden_to_tray(self) -> None:
        if self.window is None:
            return
        t = self.window.theme
        self.toast = Toast(
            t,
            self.window._icon_pixmap,
            "Clippr",
            "Still running in the tray. Click to reopen.",
            None,
            on_click=self._show,
        )
        self.toast.show_toast(3200)

    def _about(self) -> None:
        QMessageBox.about(
            self.qapp.activeWindow() or self.window,
            "About Clippr",
            f"Clippr {VERSION}\n\n"
            f"A friendly neighborhood clipboard manager.\n"
            f"Python + PyQt6 · {platform_name()}\n\n"
            f"Data: {self.data_dir}\n"
            "OCR: built-in / OCR.space / Azure / Google / PaddleOCR",
        )

    def quit(self) -> None:
        if self.window is not None:
            self.window.save_now()
            self.window._allow_close = True
            self.window.hide()
        if self.tray is not None:
            self.tray.hide()
        if self._server is not None:
            self._server.close()
        self.qapp.quit()

    def _about_to_quit(self) -> None:
        if self.window is not None:
            self.window.save_now()
        if self.tray is not None:
            self.tray.hide()

    def run(self) -> int:
        if self.window is None:
            return 0
        return self.qapp.exec()


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv if argv is None else argv)
    app = ClipprApp(argv)
    return app.run()
