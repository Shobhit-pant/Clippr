"""Custom-painted widgets for Clippr."""
from __future__ import annotations

from pathlib import Path

from PyQt6.QtCore import (
    QEasingCurve,
    QModelIndex,
    QPoint,
    QPropertyAnimation,
    QRect,
    QRectF,
    QSize,
    Qt,
    QTimer,
    pyqtSignal,
)
from PyQt6.QtGui import (
    QColor,
    QFont,
    QFontMetrics,
    QPainter,
    QPainterPath,
    QPen,
    QPixmap,
    QBrush,
)
from PyQt6.QtWidgets import (
    QAbstractItemView,
    QApplication,
    QLabel,
    QListWidget,
    QListWidgetItem,
    QListView,
    QStyle,
    QStyledItemDelegate,
    QStyleOptionViewItem,
    QWidget,
)

from .store import HistoryItem, HistoryStore
from .themes import Theme

ITEM_ROLE = Qt.ItemDataRole.UserRole + 1
TAB_ROLE = Qt.ItemDataRole.UserRole + 2
NAME_ROLE = Qt.ItemDataRole.UserRole + 3
COUNT_ROLE = Qt.ItemDataRole.UserRole + 4


def rounded_path(rect: QRectF, radius: float) -> QPainterPath:
    path = QPainterPath()
    path.addRoundedRect(rect, radius, radius)
    return path


# Use a proper Qt model, but keep a compact Python-side API.
from PyQt6.QtCore import QAbstractListModel  # noqa: E402


class HistoryListModel(QAbstractListModel):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.items: list[HistoryItem] = []

    def rowCount(self, parent: QModelIndex = QModelIndex()) -> int:  # noqa: N802
        if parent.isValid():
            return 0
        return len(self.items)

    def data(self, index: QModelIndex, role: int = Qt.ItemDataRole.DisplayRole):
        if not index.isValid() or index.row() >= len(self.items):
            return None
        item = self.items[index.row()]
        if role == Qt.ItemDataRole.DisplayRole:
            return item.text or ("Image" if item.kind == "image" else "")
        if role == ITEM_ROLE:
            return item
        if role == Qt.ItemDataRole.ToolTipRole:
            return (item.text[:500] if item.text else "Image") + (f"\n{item.short_time()}")
        return None

    def item_at(self, index: QModelIndex) -> HistoryItem | None:
        if index.isValid() and 0 <= index.row() < len(self.items):
            return self.items[index.row()]
        return None

    def set_items(self, items: list[HistoryItem]) -> None:
        self.beginResetModel()
        self.items = list(items)
        self.endResetModel()

    def row_of(self, item_id: str) -> int:
        return next((n for n, it in enumerate(self.items) if it.id == item_id), -1)


class HistoryDelegate(QStyledItemDelegate):
    def __init__(self, store: HistoryStore, theme: Theme, parent=None):
        super().__init__(parent)
        self.store = store
        self.theme = theme
        self._thumbs: dict[str, QPixmap] = {}
        self._title_font = QFont()
        self._title_font.setPointSizeF(10.5)
        self._title_font.setWeight(QFont.Weight.DemiBold)
        self._meta_font = QFont()
        self._meta_font.setPointSizeF(8.2)
        self._tag_font = QFont()
        self._tag_font.setPointSizeF(7.1)
        self._tag_font.setWeight(QFont.Weight.Bold)

    def set_theme(self, theme: Theme) -> None:
        self.theme = theme
        self._title_font.setFamily(theme.font or QApplication.font().family())
        self._title_font.setWeight(QFont.Weight.Bold if theme.mono else QFont.Weight.DemiBold)
        self._meta_font.setFamily(theme.font or QApplication.font().family())
        self._tag_font.setFamily(theme.font or QApplication.font().family())

    def invalidate_thumbs(self) -> None:
        self._thumbs.clear()

    def _thumb(self, item: HistoryItem) -> QPixmap | None:
        path = self.store.image_path(item)
        if path is None:
            return None
        key = str(path)
        if key in self._thumbs:
            return self._thumbs[key]
        pix = QPixmap(key)
        if not pix.isNull():
            pix = pix.scaled(52, 52, Qt.AspectRatioMode.KeepAspectRatioByExpanding, Qt.TransformationMode.SmoothTransformation)
            self._thumbs[key] = pix
        return pix

    def sizeHint(self, option: QStyleOptionViewItem, index: QModelIndex) -> QSize:  # noqa: N802
        return QSize(0, 82)

    def paint(self, painter: QPainter, option: QStyleOptionViewItem, index: QModelIndex) -> None:  # noqa: N802
        item: HistoryItem | None = index.data(ITEM_ROLE)
        if item is None:
            return
        t = self.theme
        painter.save()
        painter.setRenderHint(QPainter.RenderHint.Antialiasing, True)
        selected = bool(option.state & QStyle.StateFlag.State_Selected)
        hover = bool(option.state & QStyle.StateFlag.State_MouseOver)
        rect = QRectF(option.rect.adjusted(4, 3, -10, -5))
        if rect.width() < 20 or rect.height() < 20:
            painter.restore()
            return

        fill = t.selection if selected else (t.card_alt if hover else t.card)
        border = t.accent if selected else (t.muted if hover else t.border)
        shadow = t.hard_shadow
        if shadow:
            offset = 3
            sp = rounded_path(rect.translated(offset, offset), t.card_radius)
            painter.fillPath(sp, QColor(t.accent if selected else t.border))
        path = rounded_path(rect, t.card_radius)
        painter.fillPath(path, QColor(fill))
        painter.setPen(QPen(QColor(border), t.border_width + (1 if selected else 0)))
        painter.drawPath(path)

        # accent spine for selected cards
        if selected:
            spine = QRectF(rect.left() + 3, rect.top() + 12, 3, rect.height() - 24)
            painter.fillPath(rounded_path(spine, 1.5), QColor(t.accent))

        x = rect.left() + 16
        text_left = x
        if item.kind == "image":
            thumb = self._thumb(item)
            box = QRectF(x, rect.top() + 13, 50, 50)
            if thumb is not None:
                painter.save()
                painter.setClipPath(rounded_path(box, max(2, t.card_radius - 2)))
                painter.drawPixmap(box.toRect(), thumb)
                painter.restore()
            painter.setPen(QPen(QColor(t.border), 1))
            painter.drawPath(rounded_path(box, max(2, t.card_radius - 2)))
            text_left = x + 62

        title = (item.text or ("Image" if item.kind == "image" else "")).replace("\r", " ").replace("\n", " ").replace("\t", " ")
        title = " ".join(title.split())
        if not title:
            title = "Image"
        title_font = QFont(self._title_font)
        title_font.setFamily(t.font or QApplication.font().family())
        title_font.setWeight(QFont.Weight.Bold if t.mono else QFont.Weight.DemiBold)
        painter.setFont(title_font)
        painter.setPen(QColor(t.text))
        title_right = rect.right() - 22
        fm = QFontMetrics(title_font)
        elided = fm.elidedText(title, Qt.TextElideMode.ElideRight, int(title_right - text_left))
        painter.drawText(QRectF(text_left, rect.top() + 13, title_right - text_left, 24), Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter, elided)

        meta = item.short_time()
        if item.kind == "image":
            meta += f"   ·   {item.width} x {item.height} px"
        elif item.ocr_text:
            meta += "   ·   OCR"
        meta_font = QFont(self._meta_font)
        meta_font.setFamily(t.font or QApplication.font().family())
        painter.setFont(meta_font)
        painter.setPen(QColor(t.muted))
        painter.drawText(QRectF(text_left, rect.top() + 42, rect.width() - (text_left - rect.left()) - 18, 18), Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter, meta)

        # type tag
        tag = "IMG" if item.kind == "image" else ("OCR" if item.ocr_text else "TXT")
        tag_font = QFont(self._tag_font)
        tag_font.setFamily(t.font or QApplication.font().family())
        painter.setFont(tag_font)
        tw = QFontMetrics(tag_font).horizontalAdvance(tag) + 16
        tag_rect = QRectF(rect.right() - tw - 12, rect.bottom() - 25, tw, 17)
        painter.fillPath(rounded_path(tag_rect, 3), QColor(t.tag_bg))
        painter.setPen(QColor(t.tag_text))
        painter.drawText(tag_rect, Qt.AlignmentFlag.AlignCenter, tag)
        painter.restore()


class SmoothListView(QListView):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setObjectName("History")
        self.setVerticalScrollMode(QAbstractItemView.ScrollMode.ScrollPerPixel)
        self.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.setSelectionMode(QAbstractItemView.SelectionMode.SingleSelection)
        self.setMouseTracking(True)
        self.setUniformItemSizes(True)
        self.setFrameShape(QListView.Shape.NoFrame)
        self.setSpacing(0)
        self.setWordWrap(False)
        self._anim = QPropertyAnimation(self.verticalScrollBar(), b"value", self)
        self._anim.setDuration(180)
        self._anim.setEasingCurve(QEasingCurve.Type.OutCubic)
        self.empty = QLabel(self.viewport())
        self.empty.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.empty.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents, True)
        self.empty.hide()
        self._empty_html = ""
        self._theme_muted = "#827A6C"

    def setModel(self, model):  # noqa: N802
        old = self.model()
        if old is not None:
            for sig in (old.modelReset, old.rowsInserted, old.rowsRemoved):
                try:
                    sig.disconnect(self._sync_empty)
                except (TypeError, RuntimeError):
                    pass
        super().setModel(model)
        if model is not None:
            model.modelReset.connect(self._sync_empty)
            model.rowsInserted.connect(self._sync_empty)
            model.rowsRemoved.connect(self._sync_empty)
        self._sync_empty()

    def refresh_empty(self) -> None:
        self._sync_empty()

    def set_empty_message(self, title: str, hint: str, muted: str) -> None:
        self._theme_muted = muted
        self._empty_html = (
            f'<div style="color:{muted}; font-size:15px; font-weight:600;">{title}</div>'
            f'<div style="color:{muted}; font-size:11px; margin-top:7px;">{hint}</div>'
        )
        self.empty.setText(self._empty_html)
        self._sync_empty()

    def set_theme_muted(self, muted: str) -> None:
        self._theme_muted = muted
        if self.empty.isVisible():
            self.set_empty_message("Nothing here yet", "Copy text or an image to get started", muted)

    def _sync_empty(self) -> None:
        if not hasattr(self, "empty"):
            return
        model = self.model()
        show = model is None or model.rowCount() == 0
        if show:
            self.empty.setGeometry(self.viewport().rect())
            self.empty.raise_()
            self.empty.show()
        else:
            self.empty.hide()

    def resizeEvent(self, event) -> None:  # noqa: N802
        super().resizeEvent(event)
        if self.empty.isVisible():
            self.empty.setGeometry(self.viewport().rect())

    def wheelEvent(self, event) -> None:  # noqa: N802
        bar = self.verticalScrollBar()
        pixel = event.pixelDelta().y()
        if pixel:
            delta = pixel
        else:
            steps = event.angleDelta().y() / 120.0
            if not steps:
                super().wheelEvent(event)
                return
            delta = int(steps * 110)
        target = max(bar.minimum(), min(bar.maximum(), bar.value() - delta))
        self._anim.stop()
        self._anim.setStartValue(bar.value())
        self._anim.setEndValue(target)
        self._anim.start()
        event.accept()


class TabDelegate(QStyledItemDelegate):
    def __init__(self, theme: Theme, parent=None):
        super().__init__(parent)
        self.theme = theme

    def set_theme(self, theme: Theme) -> None:
        self.theme = theme

    def sizeHint(self, option: QStyleOptionViewItem, index: QModelIndex) -> QSize:  # noqa: N802
        return QSize(0, 40)

    def paint(self, painter: QPainter, option: QStyleOptionViewItem, index: QModelIndex) -> None:  # noqa: N802
        t = self.theme
        data = index.data(TAB_ROLE) or "view"
        name = index.data(NAME_ROLE) or index.data(Qt.ItemDataRole.DisplayRole) or ""
        count = index.data(COUNT_ROLE)
        selected = bool(option.state & QStyle.StateFlag.State_Selected)
        hover = bool(option.state & QStyle.StateFlag.State_MouseOver)
        painter.save()
        painter.setRenderHint(QPainter.RenderHint.Antialiasing, True)
        rect = QRectF(option.rect.adjusted(0, 3, -4, -3))
        if selected:
            painter.fillPath(rounded_path(rect, max(2, t.radius - 5)), QColor(t.accent))
            fg = QColor(getattr(t, "on_accent", "#0D0D0D"))
            dot = fg
        else:
            if hover:
                painter.fillPath(rounded_path(rect, max(2, t.radius - 5)), QColor(t.surface2))
            fg = QColor(t.text if data == "tab" else t.text)
            dot = QColor(t.accent if data == "view" else t.muted)
        # dot
        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(QBrush(dot))
        painter.drawEllipse(QPoint(int(rect.left() + 15), int(rect.center().y())), 3 if data == "tab" else 4, 3 if data == "tab" else 4)
        f = QFont(QApplication.font())
        f.setPointSizeF(9.3)
        f.setWeight(QFont.Weight.DemiBold if data == "view" else QFont.Weight.Normal)
        f.setFamily(t.font or QApplication.font().family())
        painter.setFont(f)
        painter.setPen(fg)
        left = rect.left() + 28
        right = rect.right() - 12
        if count is not None:
            cf = QFont(f)
            cf.setPointSizeF(8.0)
            painter.setFont(cf)
            cw = QFontMetrics(cf).horizontalAdvance(str(count)) + 4
            painter.drawText(QRectF(right - cw, rect.top(), cw, rect.height()), Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter, str(count))
            painter.setFont(f)
            right -= cw + 6
        painter.drawText(QRectF(left, rect.top(), max(10, right - left), rect.height()), Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter, str(name))
        painter.restore()


class TabList(QListWidget):
    request_show = pyqtSignal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setObjectName("Tabs")
        self.setSelectionMode(QAbstractItemView.SelectionMode.SingleSelection)
        self.setVerticalScrollMode(QAbstractItemView.ScrollMode.ScrollPerPixel)
        self.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.setFrameShape(QListWidget.Shape.NoFrame)
        self.setMouseTracking(True)
        self.setUniformItemSizes(True)
        self.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        self._theme = Theme  # placeholder; replaced by set_theme
        self._delegate = None

    def set_theme(self, theme: Theme) -> None:
        self._theme = theme
        if self._delegate is None:
            self._delegate = TabDelegate(theme, self)
            self.setItemDelegate(self._delegate)
        else:
            self._delegate.set_theme(theme)
        self.viewport().update()

    def populate(self, tabs: list[str], views: tuple[str, ...], counts: dict[str, int], active: str) -> None:
        self.blockSignals(True)
        try:
            self.clear()
            for name in views:
                it = QListWidgetItem()
                it.setData(TAB_ROLE, "view")
                it.setData(NAME_ROLE, name)
                it.setData(COUNT_ROLE, counts.get(name, 0))
                it.setSizeHint(QSize(0, 40))
                self.addItem(it)
            for name in tabs:
                it = QListWidgetItem()
                it.setData(TAB_ROLE, "tab")
                it.setData(NAME_ROLE, name)
                it.setData(COUNT_ROLE, counts.get(name, 0))
                it.setSizeHint(QSize(0, 40))
                self.addItem(it)
            for row in range(self.count()):
                if self.item(row).data(NAME_ROLE) == active:
                    self.setCurrentRow(row)
                    break
        finally:
            self.blockSignals(False)


class ThemeCard(QWidget):
    clicked = pyqtSignal(str)

    def __init__(self, theme: Theme, selected: bool = False, parent=None):
        super().__init__(parent)
        self.theme = theme
        self.selected = selected
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.setMinimumSize(170, 94)
        self.setMaximumHeight(104)

    def sizeHint(self) -> QSize:  # noqa: N802
        return QSize(190, 100)

    def set_selected(self, selected: bool) -> None:
        self.selected = selected
        self.update()

    def paintEvent(self, event) -> None:  # noqa: N802
        t = self.theme
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing, True)
        r = QRectF(self.rect()).adjusted(1, 1, -1, -1)
        p.fillPath(rounded_path(r, 10), QColor(t.surface))
        # miniature app preview
        inner = QRectF(r.left() + 10, r.top() + 10, r.width() - 20, 40)
        p.fillPath(rounded_path(inner, 5), QColor(t.bg))
        sidebar = QRectF(inner.left(), inner.top(), 37, inner.height())
        p.fillPath(rounded_path(sidebar, 5), QColor(t.surface2))
        p.fillRect(QRectF(sidebar.left(), sidebar.top() + 12, 37, 4), QColor(t.accent))
        for i in range(2):
            card = QRectF(inner.left() + 46, inner.top() + 6 + i * 14, inner.width() - 54, 10)
            p.fillPath(rounded_path(card, 3), QColor(t.card))
            p.setPen(QPen(QColor(t.border), 1))
            p.drawPath(rounded_path(card, 3))
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(QBrush(QColor(t.accent)))
        p.drawEllipse(QPoint(int(inner.right() - 12), int(inner.bottom() - 10)), 3, 3)
        # name and check
        f = QFont(QApplication.font())
        f.setPointSizeF(9.4)
        f.setWeight(QFont.Weight.DemiBold)
        p.setFont(f)
        p.setPen(QColor(t.text))
        p.drawText(QRectF(r.left() + 10, r.top() + 58, r.width() - 30, 20), Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter, t.name)
        f.setPointSizeF(7.7)
        f.setWeight(QFont.Weight.Normal)
        p.setFont(f)
        p.setPen(QColor(t.muted))
        p.drawText(QRectF(r.left() + 10, r.top() + 76, r.width() - 18, 16), Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter, t.description)
        p.setPen(QPen(QColor(t.accent if self.selected else t.border), 2 if self.selected else 1))
        p.setBrush(Qt.BrushStyle.NoBrush)
        p.drawPath(rounded_path(r, 10))
        if self.selected:
            p.setBrush(QBrush(QColor(t.accent)))
            p.setPen(Qt.PenStyle.NoPen)
            p.drawEllipse(QPoint(int(r.right() - 12), int(r.top() + 12)), 5, 5)

    def mousePressEvent(self, event) -> None:  # noqa: N802
        if event.button() == Qt.MouseButton.LeftButton:
            self.clicked.emit(self.theme.key)
        super().mousePressEvent(event)


class Toast(QWidget):
    _current: "Toast | None" = None

    def __init__(self, theme: Theme, icon: QPixmap | None, title: str, message: str, parent=None, on_click=None):
        super().__init__(parent)
        self.theme = theme
        self.icon = icon
        self.title = title
        self.message = message
        self.on_click = on_click
        self.setWindowFlags(
            Qt.WindowType.Tool
            | Qt.WindowType.FramelessWindowHint
            | Qt.WindowType.WindowStaysOnTopHint
            | Qt.WindowType.NoDropShadowWindowHint
        )
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground, True)
        self.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating, True)
        self.setFixedSize(350, 96)
        self._fade_in = QPropertyAnimation(self, b"windowOpacity", self)
        self._fade_in.setDuration(180)
        self._fade_in.setStartValue(0.0)
        self._fade_in.setEndValue(0.98)
        self._fade_out = QPropertyAnimation(self, b"windowOpacity", self)
        self._fade_out.setDuration(280)
        self._fade_out.setStartValue(0.98)
        self._fade_out.setEndValue(0.0)
        self._fade_out.finished.connect(self.close)
        self._timer = QTimer(self)
        self._timer.setSingleShot(True)
        self._timer.timeout.connect(self._begin_hide)
        self.setCursor(Qt.CursorShape.PointingHandCursor)

    def paintEvent(self, event) -> None:  # noqa: N802
        t = self.theme
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing, True)
        r = QRectF(self.rect()).adjusted(1, 1, -1, -1)
        p.fillPath(rounded_path(r, 13), QColor(t.card))
        p.setPen(QPen(QColor(t.border), 1))
        p.drawPath(rounded_path(r, 13))
        p.fillPath(rounded_path(QRectF(r.left() + 7, r.top() + 20, 3, r.height() - 40), 1.5), QColor(t.accent))
        if self.icon is not None:
            p.drawPixmap(QRectF(r.left() + 18, r.top() + 24, 48, 48).toRect(), self.icon)
        f = QFont(QApplication.font())
        f.setPointSizeF(10.3)
        f.setWeight(QFont.Weight.DemiBold)
        p.setFont(f)
        p.setPen(QColor(t.text))
        p.drawText(QRectF(r.left() + 82, r.top() + 20, r.width() - 96, 22), Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter, self.title)
        f.setPointSizeF(8.8)
        f.setWeight(QFont.Weight.Normal)
        p.setFont(f)
        p.setPen(QColor(t.muted))
        p.drawText(QRectF(r.left() + 82, r.top() + 45, r.width() - 96, 20), Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter, self.message)

    def _begin_hide(self) -> None:
        self._fade_out.start()

    def show_toast(self, duration: int = 2800) -> None:
        if Toast._current is not None and Toast._current is not self:
            Toast._current.close()
        Toast._current = self
        screen = QApplication.screenAt(QPoint(*self._cursor_pos())) or QApplication.primaryScreen()
        geo = screen.availableGeometry()
        self.move(geo.right() - self.width() - 20, geo.bottom() - self.height() - 20)
        self.setWindowOpacity(0.0)
        self.show()
        self.raise_()
        self._fade_in.start()
        self._timer.start(duration)

    @staticmethod
    def _cursor_pos() -> tuple[int, int]:
        from PyQt6.QtGui import QCursor

        p = QCursor.pos()
        return p.x(), p.y()

    def mousePressEvent(self, event) -> None:  # noqa: N802
        self._timer.stop()
        if self.on_click is not None:
            try:
                self.on_click()
            except Exception:
                pass
        self._begin_hide()
        super().mousePressEvent(event)

    def closeEvent(self, event) -> None:  # noqa: N802
        if Toast._current is self:
            Toast._current = None
        super().closeEvent(event)
