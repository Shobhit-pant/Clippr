# Clippr

<img src="clippr.png" width="104" alt="Clippr icon">

**Friendly Neighborhood Clipboard manager**

Clippr is a lightweight Windows clipboard manager with saved tabs, image capture, a preview window, and OCR. It is a single PowerShell + WinForms app with a deep-slate glassmorphism look and no external runtime dependencies.

## Features

- **Persistent clipboard history** - text and images survive restarts.
- **Saved tabs** - built-in `All items`, `Text`, and `Images` views plus your own tabs, each with its own history.
- **On/Off capture switch** - pause and resume clipboard capture from the header or the tray menu.
- **Instant image capture** - an image gets a temporary size label immediately, while OCR runs afterwards in a background process and replaces the label with the first readable line.
- **Preview window** - double-click an item to copy it, or use **PREVIEW** to open a larger image/text view with a separate **OCR TEXT** tab.
- **Screen capture** - click **CAPTURE** (or press `Ctrl+Shift+S`) and drag a rectangle; `Esc` cancels.
- **OCR providers** - Windows OCR, OCR.space, Azure AI Vision, Google Cloud Vision, and self-hosted PaddleOCR, including Paddle Hub, multipart, and `image_url` request modes.
- **Windows OCR fallback** - if a cloud provider is not configured or fails, Clippr falls back to the local Windows OCR engine.
- **Search and tab management** - filter the active view, create/rename/delete tabs.
- **Tray support** - minimize to the tray; reopen, capture, pause, open settings, or exit from the tray menu.
- **Glassmorphism theme** - deep-slate canvas, blurred emerald and violet mesh gradients, frosted panels with 1px cyan-tinted borders, Segoe UI typography, dark title bar, and a slim custom scrollbar.

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 (included with Windows)
- .NET Framework 4.8 (included with current Windows releases)
- An installed Windows OCR language pack for local OCR

Cloud OCR providers are optional and require your own API key or endpoint.

## Run

Double-click **`Clippr.vbs`** for a silent launch, or run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\Clippr.ps1
```

The app is single-instance: launching it again brings the existing window to the front. You can create a desktop shortcut to `Clippr.vbs` and pin it wherever you like.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `Ctrl+Tab` / `Ctrl+Shift+Tab` | Next / previous tab |
| `Ctrl+1` ... `Ctrl+3` | Jump to a tab |
| `Ctrl+F` | Focus search |
| `Esc` | Clear search (or close a dialog) |
| `Enter` | Preview the selected item |
| `Ctrl+Shift+S` | Start a screen capture |

## OCR setup

Open **SETTINGS** and choose a provider:

- **Auto** - uses the first configured cloud provider, in this order: OCR.space, Azure, Google, Paddle. If none is configured, or the request fails, Clippr uses Windows OCR.
- **Windows OCR** - fully local, no key required.
- **OCR.space / Azure / Google** - enter the matching API key (and Azure endpoint).
- **PaddleOCR** - enter the full inference endpoint, optional API key and header, and choose a request mode. OAuth2 client credentials are supported as an alternative to an API key.

Keys are stored only on this PC in `%APPDATA%\Clippr\settings.json`. Cloud OCR sends the selected image to the provider you configure; choose Windows OCR if you want OCR to stay local.

## Data and privacy

All clipboard data stays under your Windows profile:

```
%APPDATA%\Clippr\
  clippr.json      clipboard history and tab state
  settings.json    OCR configuration (may contain API keys)
  images\          captured images
```

`clippr.json`, `settings.json`, and `images\` are deliberately excluded from this repository. Do not commit them - they can contain personal or customer data.

## Development notes

- `Clippr.ps1` is the whole application: UI, persistence, clipboard polling, screen capture, OCR, and background auto-naming.
- `Clippr.vbs` is a location-independent silent launcher.
- `clippr.png` is the master icon artwork; `clippr.ico` contains its Windows icon sizes.
- `tools/make-icon.ps1` rebuilds `clippr.ico` from `clippr.png` (or a PNG passed with `-Source`).
- Image auto-naming runs in a separate hidden PowerShell process so OCR never blocks the UI or delays the image appearing in history.

## License

MIT - see [LICENSE](LICENSE).

Author: **Shobhit Pant**
