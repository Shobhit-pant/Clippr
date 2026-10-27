# Clippr — Python + PyQt6

A cross-platform clipboard manager with saved tabs, image history, preview,
screen-region capture, OCR, strip-images, four themes, and a tray icon.

This is the Python/PyQt6 edition of Clippr. It runs on **macOS, Windows and
Linux** from the same codebase. The original PowerShell + WinForms edition
remains in the repository root and is Windows-only.

## Features

- **Clipboard history** for text and images, with deduplication.
- **All items / Text / Images** views and user-created tabs.
- **Search** across text, image captions and OCR results.
- **Preview** window with copy, image preview and **OCR + COPY**.
- **Strip images (text only)** for Excel/Office clips that contain both a
  bitmap and text; enabled by default.
- **Screen-region capture** with a dimmed selection overlay.
- **OCR** using Windows.Media.Ocr on Windows and Apple Vision on macOS.
- **Four themes**: Swiss Paper, Midnight Brass, Neo-Brutalist, Calm Slate.
- **System tray** with reopen, capture, pause, settings and quit.
- **Start at login** (Windows Run key, macOS LaunchAgent, Linux autostart).
- **Single instance**, JSON persistence, history limits, image pruning.
- Theme-aware "still running in the tray" toast with the Clippr icon.

## Requirements

- Python **3.10+** (tested on 3.14).
- PyQt6 6.5+.
- Pillow (tests / optional OCR fallback).

### Windows

```powershell
python -m pip install -r requirements.txt
python main.py
```

Or double-click `run_windows.bat`.

Windows OCR needs no extra install; it uses the built-in OCR language pack.
If no OCR language is installed, Windows Settings → Time & Language →
Language & region → English → Language options → Optical character recognition.

### macOS

```bash
cd Clippr-PyQt6
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements-macos.txt
python main.py
```

Or `chmod +x run_macos.command` and double-click it.

macOS uses **Apple Vision** for OCR through PyObjC. Grant **Screen Recording**
permission in System Settings → Privacy & Security → Screen Recording for
region capture. Clipboard access does not need a permission prompt.

### Linux

```bash
python3 -m pip install -r requirements.txt
python3 main.py
```

For OCR install Tesseract and `pytesseract`:

```bash
sudo apt install tesseract-ocr
python3 -m pip install pytesseract
```

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| `Ctrl/Cmd + F` | Focus search |
| `Ctrl/Cmd + Shift + S` | Capture a screen region |
| `Delete` (list focused) | Delete selected item |
| `Enter` / double-click | Preview selected item |

## Data

| Platform | Folder |
|---|---|
| Windows | `%APPDATA%\ClipprPy` |
| macOS | `~/Library/Application Support/ClipprPy` |
| Linux | `~/.local/share/ClipprPy` |

Files: `history.json`, `settings.json`, `images/`. Set `CLIPPR_DATA_DIR` to
override the folder (used by the tests).

The Python app deliberately uses a separate folder from the PowerShell app so
the two histories never mix.

## OCR

| Platform | Backend | Notes |
|---|---|---|
| Windows | Windows.Media.Ocr | Built in; no API keys |
| macOS | Apple Vision | `pyobjc-framework-Vision` |
| Linux | Tesseract | `pytesseract` + `tesseract-ocr` |

If OCR is unavailable, the preview shows a readable error instead of failing
silently.

## Build a standalone app

### macOS `.app`

On a Mac:

```bash
chmod +x build_macos.sh
./build_macos.sh
open dist/Clippr.app
```

The script creates a `.icns` from `assets/clippr.png` and bundles assets and
the OCR helper. Distribution outside your Mac requires an Apple Developer
account, code signing and notarization (`codesign`, `notarytool`).

### Windows `.exe`

```powershell
.\build_windows.ps1
```

Output: `dist\ClipprPy\ClipprPy.exe`.

## Tests and smoke checks

```bash
python tests/test_store.py
python tests/test_themes.py
python tests/test_ui_logic.py
python tests/test_clipboard.py       # saves/restores the real clipboard
python tests/test_ocr_preview.py     # Windows/macOS OCR + clipboard restore
python tests/smoke_gui.py            # renders all four themes
python tests/smoke_dialogs.py        # preview + settings dialogs
python tests/smoke_app.py            # tray, toast, persistence
```

Pause or quit other clipboard managers before running the clipboard tests;
otherwise they may record the temporary test clips. The tests snapshot and
restore the current clipboard in a `finally` block. The GUI smoke scripts use
sample data and temporary folders; they never read the live Clippr history.

## Known limitations

- Region capture covers the **primary display**; multi-monitor capture is not
  implemented.
- No global hotkey yet; use the tray or `Ctrl/Cmd + Shift + S` while the window
  is focused.
- No import of the PowerShell edition's `clippr.json` history.
- macOS builds must be signed/notarized for warning-free distribution.

## License

MIT, same as the main Clippr project. See `../LICENSE`.
