"""Theme definitions and Qt stylesheets for Clippr PyQt6."""
from __future__ import annotations

from dataclasses import dataclass


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
    """
