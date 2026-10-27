"""Application paths, settings and small platform helpers."""
from __future__ import annotations

import json
import os
import platform
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path


APP_NAME = "Clippr"
APP_SLUG = "ClipprPy"
VERSION = "1.0.0"


def app_data_dir() -> Path:
    override = os.environ.get("CLIPPR_DATA_DIR")
    if override:
        p = Path(override).expanduser()
    else:
        home = Path.home()
        if sys.platform == "darwin":
            p = home / "Library" / "Application Support" / APP_SLUG
        elif os.name == "nt":
            base = os.environ.get("APPDATA") or str(home / "AppData" / "Roaming")
            p = Path(base) / APP_SLUG
        else:
            base = os.environ.get("XDG_DATA_HOME") or str(home / ".local" / "share")
            p = Path(base) / APP_SLUG
    p.mkdir(parents=True, exist_ok=True)
    (p / "images").mkdir(exist_ok=True)
    return p


def app_asset(name: str) -> Path:
    here = Path(__file__).resolve().parent
    return here.parent / "assets" / name


def system_font_family() -> str:
    if sys.platform == "darwin":
        return "SF Pro Text"
    if os.name == "nt":
        return "Segoe UI"
    return "DejaVu Sans"


@dataclass
class Settings:
    theme: str = "swiss"
    strip_images: bool = True
    history_limit: int = 300
    capture_paused: bool = False
    start_at_login: bool = False
    window_geometry: str = ""
    splitter_sizes: list[int] = field(default_factory=list)

    @classmethod
    def load(cls, path: Path) -> "Settings":
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            known = {f for f in cls.__dataclass_fields__}
            return cls(**{k: v for k, v in data.items() if k in known})
        except Exception:
            return cls()

    def save(self, path: Path) -> None:
        _atomic_json(path, asdict(self))


def _atomic_json(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(tmp, path)


def open_path(path: Path) -> None:
    """Open a file/folder in the OS file manager."""
    import subprocess

    if sys.platform == "darwin":
        subprocess.Popen(["open", str(path)])
    elif os.name == "nt":
        os.startfile(str(path))  # type: ignore[attr-defined]
    else:
        subprocess.Popen(["xdg-open", str(path)])


def platform_name() -> str:
    return {"darwin": "macOS", "win32": "Windows"}.get(sys.platform, platform.system())
