"""Cross-platform OCR.

Windows uses the built-in Windows.Media.Ocr engine through a tiny PowerShell
helper. macOS uses Apple's Vision framework through PyObjC. Linux and other
platforms fall back to Tesseract when pytesseract is installed.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from PyQt6.QtCore import QThread, pyqtSignal


class OcrUnavailable(RuntimeError):
    pass


def _windows_ocr(path: Path) -> str:
    script = Path(__file__).resolve().parent.parent / "ocr_windows.ps1"
    if not script.exists():
        raise OcrUnavailable("Windows OCR helper is missing.")
    powershell = shutil.which("powershell.exe") or shutil.which("powershell")
    if not powershell:
        raise OcrUnavailable("PowerShell was not found.")
    flags = 0
    if os.name == "nt":
        flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    proc = subprocess.run(
        [powershell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script), "-Path", str(path)],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=45,
        creationflags=flags,
    )
    if proc.returncode != 0:
        msg = (proc.stderr or proc.stdout or "").strip()
        raise OcrUnavailable(msg or "Windows OCR failed.")
    return (proc.stdout or "").strip()


def _macos_ocr(path: Path) -> str:
    try:
        import objc  # noqa: F401
        from Foundation import NSURL
        from Quartz import CGImageSourceCreateWithURL, CGImageSourceCreateImageAtIndex
        from Vision import (
            VNImageRequestHandler,
            VNRecognizeTextRequest,
            VNRequestTextRecognitionLevelAccurate,
        )
    except Exception as exc:
        raise OcrUnavailable(
            "Install macOS OCR support with: pip install pyobjc-framework-Vision pyobjc-framework-Quartz"
        ) from exc
    url = NSURL.fileURLWithPath_(str(path))
    source = CGImageSourceCreateWithURL(url, None)
    if source is None:
        raise OcrUnavailable("Could not read image for OCR.")
    cg = CGImageSourceCreateImageAtIndex(source, 0, None)
    request = VNRecognizeTextRequest.alloc().init()
    request.setRecognitionLevel_(VNRequestTextRecognitionLevelAccurate)
    request.setUsesLanguageCorrection_(True)
    handler = VNImageRequestHandler.alloc().initWithCGImage_options_(cg, None)
    ok, err = handler.performRequests_error_([request], None)
    if not ok:
        raise OcrUnavailable(str(err) if err else "Vision OCR failed.")
    lines = []
    for observation in request.results() or []:
        candidates = observation.topCandidates_(1)
        if candidates:
            lines.append(str(candidates[0].string()))
    return "\n".join(lines).strip()


def _tesseract_ocr(path: Path) -> str:
    try:
        import pytesseract
        from PIL import Image
    except Exception as exc:
        raise OcrUnavailable(
            "Install Tesseract OCR plus: pip install pytesseract Pillow"
        ) from exc
    try:
        with Image.open(path) as img:
            return pytesseract.image_to_string(img).strip()
    except Exception as exc:
        raise OcrUnavailable(str(exc)) from exc


def recognize_text(path: str | Path) -> str:
    path = Path(path)
    if not path.exists():
        raise OcrUnavailable("Image file not found.")
    if sys.platform == "win32":
        return _windows_ocr(path)
    if sys.platform == "darwin":
        try:
            return _macos_ocr(path)
        except OcrUnavailable:
            return _tesseract_ocr(path)
    return _tesseract_ocr(path)


class OcrWorker(QThread):
    recognized = pyqtSignal(str)
    failed = pyqtSignal(str)

    def __init__(self, path: str | Path, parent=None):
        super().__init__(parent)
        self.path = Path(path)

    def run(self) -> None:
        try:
            self.recognized.emit(recognize_text(self.path))
        except Exception as exc:
            self.failed.emit(str(exc))


def make_test_image(text: str = "Clippr OCR test 12345") -> Path:
    """Create a temporary PNG with text, used by tests and diagnostics."""
    from PIL import Image, ImageDraw, ImageFont

    img = Image.new("RGB", (1000, 280), "white")
    draw = ImageDraw.Draw(img)
    font = None
    for name in (
        "arial.ttf",
        "segoeui.ttf",
        r"C:\Windows\Fonts\arial.ttf",
        r"C:\Windows\Fonts\segoeui.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "DejaVuSans.ttf",
    ):
        try:
            font = ImageFont.truetype(name, 54)
            break
        except OSError:
            continue
    if font is None:
        font = ImageFont.load_default()
    draw.text((50, 100), text, fill="black", font=font)
    fd, name = tempfile.mkstemp(suffix=".png", prefix="clippr-ocr-")
    os.close(fd)
    img.save(name)
    return Path(name)
