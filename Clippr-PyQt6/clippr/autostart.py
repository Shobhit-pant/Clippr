"""Launch-at-login support for Windows, macOS and Linux."""
from __future__ import annotations

import os
import plistlib
import sys
from pathlib import Path

APP_KEY = "ClipprPy"
MAC_LABEL = "com.clippr.pyqt6"


def _launch_args() -> list[str]:
    entry = Path(__file__).resolve().parent.parent / "main.py"
    exe = sys.executable
    if os.name == "nt" and not getattr(sys, "frozen", False):
        candidate = Path(exe).with_name("pythonw.exe")
        if candidate.exists():
            exe = str(candidate)
    if getattr(sys, "frozen", False):
        return [exe, "--hidden"]
    return [exe, str(entry), "--hidden"]


def is_enabled() -> bool:
    if os.name == "nt":
        try:
            import winreg

            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\Run") as key:
                winreg.QueryValueEx(key, APP_KEY)
            return True
        except OSError:
            return False
    if sys.platform == "darwin":
        return _mac_plist().exists()
    return _linux_desktop().exists()


def enable() -> None:
    if os.name == "nt":
        import winreg

        command = subprocess_quote(_launch_args())
        with winreg.CreateKey(winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\Run") as key:
            winreg.SetValueEx(key, APP_KEY, 0, winreg.REG_SZ, command)
        return
    if sys.platform == "darwin":
        path = _mac_plist()
        path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "Label": MAC_LABEL,
            "ProgramArguments": _launch_args(),
            "RunAtLoad": True,
            "KeepAlive": False,
        }
        with path.open("wb") as fh:
            plistlib.dump(payload, fh)
        return
    desktop = _linux_desktop()
    desktop.parent.mkdir(parents=True, exist_ok=True)
    exec_line = " ".join(subprocess_quote([a]) for a in _launch_args())
    desktop.write_text(
        "[Desktop Entry]\nType=Application\nName=Clippr\n"
        f"Exec={exec_line}\nX-GNOME-Autostart-enabled=true\n",
        encoding="utf-8",
    )


def disable() -> None:
    if os.name == "nt":
        try:
            import winreg

            with winreg.OpenKey(
                winreg.HKEY_CURRENT_USER,
                r"Software\Microsoft\Windows\CurrentVersion\Run",
                0,
                winreg.KEY_SET_VALUE,
            ) as key:
                winreg.DeleteValue(key, APP_KEY)
        except OSError:
            pass
        return
    if sys.platform == "darwin":
        _mac_plist().unlink(missing_ok=True)
        return
    _linux_desktop().unlink(missing_ok=True)


def _mac_plist() -> Path:
    return Path.home() / "Library" / "LaunchAgents" / f"{MAC_LABEL}.plist"


def _linux_desktop() -> Path:
    return Path.home() / ".config" / "autostart" / "clippr.desktop"


def subprocess_quote(args: list[str]) -> str:
    if os.name != "nt":
        import shlex

        return " ".join(shlex.quote(a) for a in args)
    return " ".join(f'"{a}"' if " " in a else a for a in args)
