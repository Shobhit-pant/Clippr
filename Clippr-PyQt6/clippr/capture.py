"""Full-screen region capture overlay (cross-platform, primary display)."""
from __future__ import annotations

from PyQt6.QtCore import QEventLoop, QPoint, QRect, Qt, pyqtSignal
from PyQt6.QtGui import QColor, QFont, QGuiApplication, QImage, QKeyEvent, QPainter, QPen
from PyQt6.QtWidgets import QApplication, QWidget

from .themes import Theme


class RegionCapture(QWidget):
    captured = pyqtSignal(QImage)
    cancelled = pyqtSignal()

    def __init__(self, theme: Theme, parent=None):
        super().__init__(parent)
        self.theme = theme
        self._start: QPoint | None = None
        self._current: QPoint | None = None
        self._image: QImage | None = None
        self._loop: QEventLoop | None = None
        self.setWindowFlags(
            Qt.WindowType.FramelessWindowHint
            | Qt.WindowType.WindowStaysOnTopHint
            | Qt.WindowType.Tool
        )
        self.setCursor(Qt.CursorShape.CrossCursor)
        self.setMouseTracking(True)
        self.setFocusPolicy(Qt.FocusPolicy.StrongFocus)
        screen = QGuiApplication.primaryScreen()
        if screen is None:
            raise RuntimeError("No display available for screen capture.")
        self._screen = screen
        self._screen_geo = screen.geometry()
        self._shot = screen.grabWindow(0)
        self._dpr = max(1.0, float(self._shot.devicePixelRatio() or screen.devicePixelRatio() or 1.0))
        self.setGeometry(self._screen_geo)
        self.move(self._screen_geo.topLeft())

    def start(self) -> QImage | None:
        self._loop = QEventLoop()
        self.show()
        self.raise_()
        self.activateWindow()
        self.setFocus()
        self.grabKeyboard()
        self._loop.exec()
        return self._image

    def _selection(self) -> QRect:
        if self._start is None or self._current is None:
            return QRect()
        return QRect(self._start, self._current).normalized().intersected(self.rect())

    def _physical(self, rect: QRect) -> QRect:
        d = self._dpr
        return QRect(
            int(round(rect.x() * d)),
            int(round(rect.y() * d)),
            max(1, int(round(rect.width() * d))),
            max(1, int(round(rect.height() * d))),
        )

    def _crop(self, sel: QRect) -> QImage:
        phys = self._physical(sel)
        img = self._shot.toImage().copy(phys)
        img.setDevicePixelRatio(1.0)
        return img

    def paintEvent(self, event) -> None:  # noqa: N802
        p = QPainter(self)
        p.drawPixmap(0, 0, self._shot)
        p.fillRect(self.rect(), QColor(0, 0, 0, 110))
        sel = self._selection()
        if sel.width() > 1 and sel.height() > 1:
            p.drawPixmap(sel, self._shot, self._physical(sel))
            t = self.theme
            p.setPen(QPen(QColor(t.accent), 2))
            p.drawRect(sel.adjusted(0, 0, -1, -1))
            label = f"{sel.width()} × {sel.height()}"
            f = QFont(QApplication.font())
            f.setPointSizeF(9)
            p.setFont(f)
            fm = p.fontMetrics()
            box = fm.boundingRect(label).adjusted(-8, -4, 8, 4)
            pos = sel.topLeft() + QPoint(10, -box.height() - 8)
            if pos.y() < 4:
                pos.setY(sel.topLeft().y() + 10)
            box.moveTopLeft(pos)
            p.fillRect(box, QColor(t.card))
            p.setPen(QPen(QColor(t.border), 1))
            p.drawRect(box)
            p.setPen(QColor(t.text))
            p.drawText(box, Qt.AlignmentFlag.AlignCenter, label)
        else:
            t = self.theme
            f = QFont(QApplication.font())
            f.setPointSizeF(12)
            f.setWeight(QFont.Weight.DemiBold)
            p.setFont(f)
            p.setPen(QColor("#FFFFFF"))
            p.drawText(self.rect().adjusted(0, -40, 0, -40), Qt.AlignmentFlag.AlignCenter, "Drag to create a snip   ·   Esc to cancel")

    def mousePressEvent(self, event) -> None:  # noqa: N802
        if event.button() == Qt.MouseButton.LeftButton:
            self._start = event.position().toPoint()
            self._current = self._start
            self.update()

    def mouseMoveEvent(self, event) -> None:  # noqa: N802
        if self._start is not None:
            self._current = event.position().toPoint()
            self.update()

    def mouseReleaseEvent(self, event) -> None:  # noqa: N802
        if event.button() != Qt.MouseButton.LeftButton or self._start is None:
            return
        sel = self._selection()
        if sel.width() >= 8 and sel.height() >= 8:
            self._image = self._crop(sel)
            self.captured.emit(self._image)
            self._finish()
        else:
            self._start = None
            self._current = None
            self.update()

    def keyPressEvent(self, event: QKeyEvent) -> None:  # noqa: N802
        if event.key() == Qt.Key.Key_Escape:
            self._image = None
            self.cancelled.emit()
            self._finish()
        elif event.key() in (Qt.Key.Key_Return, Qt.Key.Key_Enter):
            sel = self._selection()
            if sel.width() >= 8 and sel.height() >= 8:
                self._image = self._crop(sel)
                self.captured.emit(self._image)
                self._finish()
        else:
            super().keyPressEvent(event)

    def _finish(self) -> None:
        self.releaseKeyboard()
        self.close()
        if self._loop is not None and self._loop.isRunning():
            self._loop.quit()


def capture_screen_region(theme: Theme, parent=None) -> QImage | None:
    overlay = RegionCapture(theme, parent)
    return overlay.start()
