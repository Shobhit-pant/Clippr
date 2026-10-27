# Clippr — Python + PyQt6

A cross-platform clipboard manager with saved tabs, image history, preview,
screen-region capture, OCR, strip-images, eight themes, and a tray icon.

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
- **OCR with bring-your-own providers**: built-in Windows/macOS/Tesseract engines,
  OCR.space, Azure AI Vision, Google Cloud Vision, and PaddleOCR/self-hosted
  servers with API-key or OAuth2 authentication.
- **Auto-name new images from OCR** (optional; uses the selected provider).
- **Eight themes**: Swiss Paper, Midnight Brass, Neo-Brutalist, Calm Slate,
  Forest Ink, Rose Quartz, Sunset Ember, and Mono Terminal.
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
| `Ctrl/Cmd + Shift + S` | Create a new snip (screen region) |
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

Open **Settings > OCR** to choose an engine and enter provider keys. Keys are
stored locally in `settings.json` and are sent only to the provider you select.
The **AUTHENTICATE** button runs the selected provider against a small test
image before you save.

### Built-in engines

| Option | Platform | Notes |
|---|---|---|
| **Auto** | All | Windows OCR on Windows, Apple Vision on macOS, Tesseract elsewhere; native failure falls back to Tesseract |
| **Windows OCR** | Windows only | Windows.Media.Ocr; no key or extra package |
| **macOS Vision** | macOS only | Apple Vision via PyObjC |
| **Tesseract** | All | Requires `tesseract` + `pytesseract` |

Explicit **Windows OCR** or **macOS Vision** choices fail with a clear message
on the other operating system. If you do not have either native engine, choose
**Tesseract**, **OCR.space**, or another cloud provider.

### Bring your own OCR

| Provider | Required settings |
|---|---|
| **OCR.space** | API key; language (default `eng`) |
| **Azure AI Vision** | Endpoint + subscription key |
| **Google Cloud Vision** | API key |
| **PaddleOCR / custom server** | Endpoint, optional API key/header, request mode |

Paddle supports **PaddleHub JSON (`images[]`)**, **multipart file**, and
**Gravitee-style `image_url` (`input[]`)** requests. It also supports OAuth2
client credentials (token URL, client ID, secret, optional scope); OAuth2
overrides the API-key header.

**Auto** uses a configured cloud provider first (OCR.space, Azure, Google,
Paddle), then the built-in engine. If a cloud provider is selected explicitly
and fails, Clippr falls back to the built-in engine and reports the fallback in
the OCR status instead of losing the operation.

> **Security:** keys are plain text in the local `settings.json`. Do not commit
> that file; it is already ignored by Git. Use a self-hosted Paddle server if
> you do not want images leaving your network.

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
python tests/test_ocr_config.py      # provider resolution, parsers, fallback
python tests/test_settings_ocr.py    # OCR settings tab + Authenticate
python tests/test_clipboard.py       # saves/restores the real clipboard
python tests/test_ocr_preview.py     # Windows/macOS OCR + clipboard restore
python tests/smoke_gui.py            # renders all eight themes
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
