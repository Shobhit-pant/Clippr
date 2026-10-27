"""Theme definitions and Qt stylesheets for Clippr PyQt6."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Theme:
    key: str
    name: str
    description: str
    bg: str
    surface: str
    surface2: str
    card: str
    card_alt: str
    border: str
    text: str
    muted: str
    accent: str
    accent2: str
    selection: str
    tag_bg: str
    tag_text: str
    is_light: bool
    radius: int = 14
    card_radius: int = 12
    border_width: int = 1
    hard_shadow: bool = False
    font: str = ""
    mono: bool = False
    on_accent: str = "#0D0D0D"


THEMES: dict[str, Theme] = {
    "swiss": Theme(
        key="swiss",
        name="Swiss Paper",
        description="Warm paper, ink, a red pencil mark.",
        bg="#EDE7DB",
        surface="#F8F4EA",
        surface2="#F1EADD",
        card="#FFFDF7",
        card_alt="#FBF6EC",
        border="#D8CFC0",
        text="#1A1815",
        muted="#827A6C",
        accent="#C8432F",
        accent2="#2F6B55",
        selection="#F3DCD7",
        tag_bg="#EFE7D9",
        tag_text="#6C6254",
        is_light=True,
        on_accent="#FFFFFF",
    ),
    "brass": Theme(
        key="brass",
        name="Midnight Brass",
        description="Deep ink with warm brass fittings.",
        bg="#101215",
        surface="#171A20",
        surface2="#1D222A",
        card="#1B2028",
        card_alt="#232A34",
        border="#333B47",
        text="#F0EBDD",
        muted="#9B9484",
        accent="#C6A15B",
        accent2="#7FA6A0",
        selection="#2E2A1F",
        tag_bg="#2A251C",
        tag_text="#C6A15B",
        is_light=False,
        on_accent="#101215",
    ),
    "brutal": Theme(
        key="brutal",
        name="Neo-Brutalist",
        description="Hard edges, loud accent, zero apologies.",
        bg="#F2EFE6",
        surface="#FFFDF5",
        surface2="#E9E4D6",
        card="#FFFFFF",
        card_alt="#F7F4EA",
        border="#0D0D0D",
        text="#0D0D0D",
        muted="#5E5A50",
        accent="#D6FF3F",
        accent2="#FF6B5A",
        selection="#E8FF9E",
        tag_bg="#0D0D0D",
        tag_text="#D6FF3F",
        is_light=True,
        radius=2,
        card_radius=2,
        border_width=2,
        hard_shadow=True,
        mono=True,
        on_accent="#0D0D0D",
    ),
    "calm": Theme(
        key="calm",
        name="Calm Slate",
        description="Cool blue-grey, quiet focus.",
        bg="#E9EFF7",
        surface="#F7FAFE",
        surface2="#EEF4FB",
        card="#FFFFFF",
        card_alt="#F4F8FD",
        border="#C7D9FB",
        text="#172033",
        muted="#64748B",
        accent="#2563EB",
        accent2="#0F9F8F",
        selection="#E7EFFE",
        tag_bg="#E7EFFE",
        tag_text="#1D4ED8",
        is_light=True,
        on_accent="#FFFFFF",
    ),
    "forest": Theme(
        key="forest",
        name="Forest Ink",
        description="Deep evergreen with moss and warm wood.",
        bg="#0E1712",
        surface="#15221A",
        surface2="#1B2D22",
        card="#192A20",
        card_alt="#21372A",
        border="#334C3B",
        text="#EAF4EC",
        muted="#94AA9C",
        accent="#7BC48A",
        accent2="#D6A45B",
        selection="#223B2C",
        tag_bg="#23382A",
        tag_text="#A8DDB3",
        is_light=False,
        on_accent="#0E1712",
    ),
    "rose": Theme(
        key="rose",
        name="Rose Quartz",
        description="Soft blush, ink, and a violet edge.",
        bg="#F7ECEF",
        surface="#FFF8FA",
        surface2="#F3E2E7",
        card="#FFFDFE",
        card_alt="#FDF1F4",
        border="#E3C3CC",
        text="#3A1E26",
        muted="#8C6874",
        accent="#C04A6A",
        accent2="#7C6BC4",
        selection="#F6DDE4",
        tag_bg="#F7E2E8",
        tag_text="#A53B5A",
        is_light=True,
        on_accent="#FFFFFF",
    ),
    "ember": Theme(
        key="ember",
        name="Sunset Ember",
        description="Charcoal evening with ember and brass.",
        bg="#1B1210",
        surface="#241A16",
        surface2="#2C211C",
        card="#2A1D18",
        card_alt="#35251E",
        border="#4A3329",
        text="#F6E8DC",
        muted="#B79A88",
        accent="#F07A3E",
        accent2="#E0B25A",
        selection="#3B241A",
        tag_bg="#3B261B",
        tag_text="#F5A36F",
        is_light=False,
        on_accent="#1B1210",
    ),
    "mono": Theme(
        key="mono",
        name="Mono Terminal",
        description="Black glass, crisp type, mint signal.",
        bg="#0B0D0E",
        surface="#121619",
        surface2="#171D20",
        card="#151C1F",
        card_alt="#1C2529",
        border="#2E3B40",
        text="#DCE6E8",
        muted="#7F9298",
        accent="#50E3C2",
        accent2="#8FA6AD",
        selection="#16302C",
        tag_bg="#16302C",
        tag_text="#50E3C2",
        is_light=False,
        on_accent="#07110F",
        radius=6,
        card_radius=4,
        mono=True,
    ),
}

DEFAULT_THEME = "swiss"


def theme(key: str | None) -> Theme:
    return THEMES.get(key or "", THEMES[DEFAULT_THEME])


def build_qss(t: Theme) -> str:
    """Return the application stylesheet for one theme."""
    r = t.radius
    cr = t.card_radius
    bw = t.border_width
    card_hover = t.card_alt
    btn_radius = max(2, r - 4)
    arrow = (Path(__file__).resolve().parent.parent / "assets" / ("chevron-dark.png" if t.is_light else "chevron-light.png")).as_posix()
    return f"""
    * {{
        outline: 0;
    }}
    QMainWindow, QDialog, QWidget#Root {{
        background: {t.bg};
        color: {t.text};
    }}
    QWidget {{
        color: {t.text};
        font-size: 10pt;
    }}
    QLabel#AppTitle {{
        font-size: 22pt;
        font-weight: 700;
        color: {t.text};
    }}
    QLabel#AppSubtitle {{
        font-size: 7.5pt;
        font-weight: 600;
        letter-spacing: 1.2px;
        color: {t.muted};
    }}
    QLabel#SectionLabel {{
        font-size: 8pt;
        font-weight: 700;
        letter-spacing: 1px;
        color: {t.muted};
    }}
    QLabel#Status {{
        color: {t.muted};
        font-size: 8.5pt;
        padding: 2px 6px;
    }}
    QLabel#Hint {{
        color: {t.muted};
        font-size: 9pt;
    }}
    QFrame#Sidebar {{
        background: {t.surface};
        border-right: {bw}px solid {t.border};
    }}
    QFrame#Header {{
        background: transparent;
    }}
    QFrame#ActionBar {{
        background: transparent;
    }}
    QFrame#Line {{
        background: {t.border};
        max-height: {bw}px;
        min-height: {bw}px;
        border: 0;
    }}
    QPushButton {{
        background: {t.surface};
        color: {t.text};
        border: {bw}px solid {t.border};
        border-radius: {btn_radius}px;
        padding: 8px 12px;
        font-size: 8.5pt;
        font-weight: 600;
    }}
    QPushButton:hover {{
        background: {card_hover};
    }}
    QPushButton:pressed {{
        background: {t.selection};
    }}
    QPushButton:disabled {{
        color: {t.muted};
        background: {t.surface2};
        border-color: {t.border};
    }}
    QPushButton[role="primary"] {{
        background: {t.accent};
        color: {t.on_accent};
        border-color: {t.accent};
    }}
    QPushButton#TopCapture {{
        background: transparent;
        color: #C8432F;
        border: 2px solid #C8432F;
        border-radius: 8px;
        padding: 8px 14px;
        font-size: 8.5pt;
        font-weight: 800;
        letter-spacing: 0.8px;
    }}
    QPushButton#TopCapture:hover {{
        background: #C8432F;
        color: #FFFFFF;
        border-color: #C8432F;
    }}
    QPushButton#TopCapture:pressed {{
        background: #A93626;
        border-color: #A93626;
        color: #FFFFFF;
    }}
    QPushButton[role="primary"]:hover {{
        background: {t.accent};
        border-color: {t.text};
    }}
    QPushButton[role="primary"]:disabled,
    QPushButton[role="capture"]:disabled {{
        background: {t.surface2};
        color: {t.muted};
        border-color: {t.border};
    }}
    QPushButton[role="danger"]:hover {{
        background: {t.selection};
        border-color: {t.accent};
    }}
    QPushButton[role="ghost"] {{
        background: transparent;
        border-color: transparent;
    }}
    QPushButton[role="ghost"]:hover {{
        background: {t.surface2};
        border-color: {t.border};
    }}
    QPushButton[role="soft"] {{
        background: transparent;
        border-color: {t.border};
        color: {t.muted};
        padding: 6px 10px;
    }}
    QPushButton[role="soft"]:hover {{
        background: {t.surface2};
        color: {t.text};
    }}
    QPushButton[role="capture"] {{
        background: {t.accent};
        color: {t.on_accent};
        border-color: {t.accent};
    }}
    QPushButton[role="capture"][paused="true"] {{
        background: {t.surface};
        color: {t.muted};
        border-color: {t.border};
    }}
    QLineEdit {{
        background: {t.surface};
        color: {t.text};
        border: {bw}px solid {t.border};
        border-radius: {btn_radius}px;
        padding: 9px 12px;
        selection-background-color: {t.accent};
        selection-color: {t.on_accent};
    }}
    QLineEdit:focus {{
        border-color: {t.accent};
    }}
    QListWidget#Tabs {{
        background: transparent;
        border: 0;
        padding: 0;
    }}
    QListWidget#Tabs::item {{
        border: 0;
        padding: 0;
    }}
    QListView#History {{
        background: transparent;
        border: 0;
        padding: 4px 6px 4px 4px;
    }}
    QListView#History::item {{
        border: 0;
        background: transparent;
    }}
    QScrollBar:vertical {{
        background: transparent;
        width: 10px;
        margin: 2px 0 2px 0;
    }}
    QScrollBar::handle:vertical {{
        background: {t.accent};
        min-height: 28px;
        border-radius: 3px;
        margin: 0 2px;
    }}
    QScrollBar::handle:vertical:hover {{
        background: {t.accent2};
    }}
    QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {{
        height: 0; background: transparent;
    }}
    QScrollBar::add-page:vertical, QScrollBar::sub-page:vertical {{
        background: transparent;
    }}
    QScrollBar:horizontal {{
        height: 0;
    }}
    QCheckBox {{
        color: {t.muted};
        spacing: 7px;
        font-size: 8.5pt;
    }}
    QCheckBox::indicator {{
        width: 15px; height: 15px;
        border: {bw}px solid {t.border};
        border-radius: 3px;
        background: {t.surface};
    }}
    QCheckBox::indicator:checked {{
        background: {t.accent};
        border-color: {t.accent};
    }}
    QSpinBox {{
        background: {t.surface};
        color: {t.text};
        border: {bw}px solid {t.border};
        border-radius: {btn_radius}px;
        padding: 5px 8px;
    }}
    QToolTip {{
        background: {t.surface};
        color: {t.text};
        border: {bw}px solid {t.border};
        padding: 5px 7px;
    }}
    QMenu {{
        background: {t.surface};
        color: {t.text};
        border: {bw}px solid {t.border};
        padding: 5px;
    }}
    QMenu::item {{
        padding: 6px 22px 6px 12px;
        border-radius: 4px;
    }}
    QMenu::item:selected {{
        background: {t.selection};
        color: {t.text};
    }}
    QTextEdit {{
        background: {t.surface};
        color: {t.text};
        border: {bw}px solid {t.border};
        border-radius: {cr}px;
        padding: 10px;
        selection-background-color: {t.accent};
        selection-color: {t.on_accent};
    }}
    QDialogButtonBox QPushButton {{
        min-width: 74px;
    }}
    QFrame#Card {{
        background: {t.card};
        border: {bw}px solid {t.border};
        border-radius: {cr}px;
    }}

    QTabWidget::pane {{
        background: {t.surface};
        border: {bw}px solid {t.border};
        border-radius: {cr}px;
        top: -1px;
    }}
    QTabBar::tab {{
        background: transparent;
        color: {t.muted};
        padding: 8px 16px;
        margin-right: 4px;
        border: 0;
        border-bottom: 2px solid transparent;
        font-weight: 600;
    }}
    QTabBar::tab:selected {{
        color: {t.text};
        border-bottom-color: {t.accent};
    }}
    QTabBar::tab:hover {{
        color: {t.text};
    }}
    QComboBox {{
        background: {t.surface};
        color: {t.text};
        border: {bw}px solid {t.border};
        border-radius: {btn_radius}px;
        padding: 6px 10px;
        min-height: 22px;
    }}
    QComboBox:focus {{
        border-color: {t.accent};
    }}
    QComboBox::drop-down {{
        border: 0;
        width: 30px;
    }}
    QComboBox::down-arrow {{
        image: url("{arrow}");
        width: 10px;
        height: 7px;
    }}
    QComboBox QAbstractItemView {{
        background: {t.surface};
        color: {t.text};
        border: {bw}px solid {t.border};
        selection-background-color: {t.selection};
        selection-color: {t.text};
        outline: 0;
    }}
    QGroupBox {{
        border: {bw}px solid {t.border};
        border-radius: {btn_radius}px;
        margin-top: 13px;
        padding: 12px 10px 8px 10px;
        font-weight: 600;
        background: transparent;
    }}
    QGroupBox::title {{
        subcontrol-origin: margin;
        subcontrol-position: top left;
        left: 10px;
        padding: 0 5px;
        color: {t.text};
        background: {t.surface};
    }}
    QScrollArea {{
        background: transparent;
        border: 0;
    }}
    QScrollArea > QWidget > QWidget {{
        background: transparent;
    }}
    """
