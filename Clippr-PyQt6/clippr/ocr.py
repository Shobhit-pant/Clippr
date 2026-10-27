"""Cross-platform OCR with built-in and bring-your-own-provider support.

Providers:
  * built-in: Windows.Media.Ocr, Apple Vision, or Tesseract
  * OCR.space
  * Azure AI Vision (v3.2 OCR)
  * Google Cloud Vision
  * PaddleOCR / a custom self-hosted OCR server (PaddleHub, multipart or
    Gravitee-style image_url requests; optional API key or OAuth2)
"""
from __future__ import annotations

import base64
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from dataclasses import dataclass, replace
from pathlib import Path

from PyQt6.QtCore import QThread, pyqtSignal

from .config import Settings


class OcrUnavailable(RuntimeError):
    pass


class OcrError(RuntimeError):
    pass


@dataclass
class OcrOutcome:
    text: str
    provider: str
    notice: str = ""


PROVIDERS = ("auto", "builtin", "ocrspace", "azure", "google", "paddle")
CLOUD_PROVIDERS = ("ocrspace", "azure", "google", "paddle")
ENGINES = ("auto", "windows", "macos", "tesseract")

PROVIDER_LABELS = {
    "auto": "Auto",
    "builtin": "Built-in OCR",
    "ocrspace": "OCR.space",
    "azure": "Azure AI Vision",
    "google": "Google Cloud Vision",
    "paddle": "PaddleOCR / custom server",
}
ENGINE_LABELS = {
    "auto": "Auto (platform native)",
    "windows": "Windows OCR (Windows only)",
    "macos": "macOS Vision (macOS only)",
    "tesseract": "Tesseract",
}
_AUTO_CLOUD_ORDER = ("ocrspace", "azure", "google", "paddle")


# ---------------------------------------------------------------------------
# Built-in engines
# ---------------------------------------------------------------------------
def _windows_ocr(path: Path) -> str:
    script = Path(__file__).resolve().parent.parent / "ocr_windows.ps1"
    if not script.exists():
        raise OcrUnavailable("Windows OCR helper is missing.")
    powershell = shutil.which("powershell.exe") or shutil.which("powershell")
    if not powershell:
        raise OcrUnavailable("PowerShell was not found.")
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0) if os.name == "nt" else 0
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
    if sys.platform != "darwin":
        raise OcrUnavailable("macOS Vision OCR is only available on macOS.")
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
            "macOS Vision support is not installed. Run: "
            "pip install pyobjc-framework-Vision pyobjc-framework-Quartz"
        ) from exc
    url = NSURL.fileURLWithPath_(str(path))
    source = CGImageSourceCreateWithURL(url, None)
    if source is None:
        raise OcrUnavailable("Could not read the image for OCR.")
    cg = CGImageSourceCreateImageAtIndex(source, 0, None)
    request = VNRecognizeTextRequest.alloc().init()
    request.setRecognitionLevel_(VNRequestTextRecognitionLevelAccurate)
    request.setUsesLanguageCorrection_(True)
    handler = VNImageRequestHandler.alloc().initWithCGImage_options_(cg, None)
    ok, err = handler.performRequests_error_([request], None)
    if not ok:
        raise OcrUnavailable(str(err) if err else "Apple Vision OCR failed.")
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
            "Tesseract OCR is not installed. Install Tesseract and run "
            "pip install pytesseract Pillow, or choose another provider."
        ) from exc
    try:
        with Image.open(path) as img:
            return pytesseract.image_to_string(img).strip()
    except Exception as exc:
        raise OcrUnavailable(str(exc)) from exc


def platform_engine() -> str:
    return {"win32": "windows", "darwin": "macos"}.get(sys.platform, "tesseract")


def builtin_engine(settings: Settings | None = None) -> str:
    wanted = ((settings.ocr_builtin_engine if settings is not None else "auto") or "auto").strip().lower()
    if wanted in ("windows", "macos", "tesseract"):
        return wanted
    return platform_engine()


def _run_engine(engine: str, path: Path) -> str:
    if engine == "windows":
        if sys.platform != "win32":
            raise OcrUnavailable("Windows OCR is only available on Windows.")
        return _windows_ocr(path)
    if engine == "macos":
        if sys.platform != "darwin":
            raise OcrUnavailable("macOS Vision OCR is only available on macOS.")
        return _macos_ocr(path)
    return _tesseract_ocr(path)


def _run_builtin(path: Path, settings: Settings | None) -> tuple[str, str]:
    wanted = ((settings.ocr_builtin_engine if settings is not None else "auto") or "auto").strip().lower()
    if wanted in ("windows", "macos", "tesseract"):
        engine = wanted
        return _run_engine(engine, path), engine
    engine = platform_engine()
    try:
        return _run_engine(engine, path), engine
    except Exception as native_exc:
        # Native OCR can be absent (no language pack, missing PyObjC, or no
        # screen/OCR support on Linux). Tesseract is a useful last resort.
        try:
            return _tesseract_ocr(path), "tesseract"
        except Exception as tess_exc:
            raise OcrUnavailable(
                f"{ENGINE_LABELS.get(engine, engine)} failed: {native_exc}. "
                f"Tesseract fallback failed: {tess_exc}"
            ) from tess_exc


# ---------------------------------------------------------------------------
# HTTP + image helpers
# ---------------------------------------------------------------------------
def _http_json(
    url: str,
    *,
    data: bytes | None = None,
    headers: dict | None = None,
    timeout: int = 90,
) -> dict:
    req = urllib.request.Request(url, data=data, headers=headers or {}, method="POST" if data is not None else "GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            raw = response.read()
    except urllib.error.HTTPError as exc:
        body = ""
        try:
            body = exc.read().decode("utf-8", "replace")[:800]
        except Exception:
            pass
        raise OcrError(f"HTTP {exc.code}: {body or exc.reason}") from exc
    except urllib.error.URLError as exc:
        raise OcrError(f"Network error: {exc.reason}") from exc
    try:
        return json.loads(raw.decode("utf-8"))
    except Exception as exc:
        raise OcrError("The OCR provider returned a non-JSON response.") from exc


def _image_bytes(path: Path, fmt: str = "JPEG", max_dim: int = 1600, quality: int = 82) -> bytes:
    try:
        from PIL import Image
    except Exception as exc:
        raise OcrUnavailable("Pillow is required for cloud OCR image encoding.") from exc
    with Image.open(path) as img:
        img.thumbnail((max_dim, max_dim), Image.Resampling.LANCZOS)
        buf = io.BytesIO()
        if fmt.upper() == "JPEG":
            img.convert("RGB").save(buf, "JPEG", quality=quality, optimize=True)
        else:
            img.save(buf, "PNG", optimize=True)
        return buf.getvalue()


def _image_b64(path: Path, fmt: str = "JPEG", max_dim: int = 1600, quality: int = 82) -> str:
    return base64.b64encode(_image_bytes(path, fmt, max_dim, quality)).decode("ascii")


def _text(value) -> str:
    return "" if value is None else str(value).strip()


# ---------------------------------------------------------------------------
# Provider resolution and parsers
# ---------------------------------------------------------------------------
def _has(value) -> bool:
    return bool(_text(value))


def configured_cloud_provider(settings: Settings | None) -> str | None:
    if settings is None:
        return None
    p = (settings.ocr_provider or "auto").strip().lower()
    if p in CLOUD_PROVIDERS:
        return p
    if p in ("auto", ""):
        if _has(settings.ocr_space_key):
            return "ocrspace"
        if _has(settings.azure_key) and _has(settings.azure_endpoint):
            return "azure"
        if _has(settings.google_key):
            return "google"
        if _has(settings.paddle_endpoint):
            return "paddle"
    return None


def provider_label(key: str) -> str:
    return PROVIDER_LABELS.get(key, key)


def parse_ocr_space(payload: dict) -> str:
    if payload.get("IsErroredOnProcessing"):
        messages = payload.get("ErrorMessage") or []
        if isinstance(messages, str):
            messages = [messages]
        msg = " ".join(str(x) for x in messages if x) or "unknown error"
        raise OcrError(f"OCR.space: {msg}")
    parts = []
    for item in payload.get("ParsedResults") or []:
        if isinstance(item, dict) and item.get("ParsedText"):
            parts.append(str(item["ParsedText"]))
    return "".join(parts).strip()


def parse_azure(payload: dict) -> str:
    lines = []
    for region in payload.get("regions") or []:
        for line in region.get("lines") or []:
            words = [str(w.get("text", "")) for w in line.get("words") or []]
            words = [w for w in words if w]
            if words:
                lines.append(" ".join(words))
    return "\n".join(lines).strip()


def parse_google(payload: dict) -> str:
    responses = payload.get("responses") or []
    if not responses:
        return ""
    response = responses[0] or {}
    if response.get("error"):
        err = response["error"]
        raise OcrError(f"Google Vision: {err.get('message') or err}")
    full = (response.get("fullTextAnnotation") or {}).get("text")
    if full:
        return str(full).strip()
    annotations = response.get("textAnnotations") or []
    if annotations and isinstance(annotations[0], dict):
        return _text(annotations[0].get("description"))
    return ""


_LEAF_KEYS = ("text", "rec_text", "content", "description", "ParsedText")
_CONTAINER_KEYS = (
    "results", "result", "res", "data", "lines", "regions", "words",
    "ocr_result", "ocrResults", "prunedResult", "texts", "text_detections",
    "text_prediction",
)


def extract_text_any(obj, depth: int = 0) -> str:
    """Best-effort text extraction for varied self-hosted OCR responses."""
    if obj is None or depth > 9:
        return ""
    if isinstance(obj, str):
        return obj.strip()
    if isinstance(obj, (int, float)):
        return ""
    if isinstance(obj, dict):
        for key in _LEAF_KEYS:
            value = obj.get(key)
            if isinstance(value, (dict, list)):
                found = extract_text_any(value, depth + 1)
            else:
                found = _text(value)
            if found:
                return found
        rec_texts = obj.get("rec_texts")
        if isinstance(rec_texts, list) and rec_texts:
            return "\n".join(str(x) for x in rec_texts if _text(x)).strip()
        for key in _CONTAINER_KEYS:
            if key in obj and obj[key] is not None:
                found = extract_text_any(obj[key], depth + 1)
                if found:
                    return found
        return ""
    if isinstance(obj, (list, tuple)):
        parts = []
        for item in obj:
            found = extract_text_any(item, depth + 1)
            if found:
                parts.append(found.strip())
        return "\n".join(parts).strip()
    return ""


# ---------------------------------------------------------------------------
# Cloud providers
# ---------------------------------------------------------------------------
def _ocr_space(path: Path, settings: Settings) -> str:
    key = _text(settings.ocr_space_key)
    if not key:
        raise OcrError("OCR.space API key is not set.")
    form = urllib.parse.urlencode(
        {
            "apikey": key,
            "base64Image": "data:image/jpeg;base64," + _image_b64(path, "JPEG", 1600, 82),
            "language": _text(settings.ocr_space_language) or "eng",
            "OCREngine": "2",
            "scale": "true",
            "isTable": "false",
        }
    ).encode("utf-8")
    payload = _http_json(
        "https://api.ocr.space/parse/image",
        data=form,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    return parse_ocr_space(payload)


def _azure(path: Path, settings: Settings) -> str:
    endpoint = _text(settings.azure_endpoint)
    key = _text(settings.azure_key)
    if not endpoint:
        raise OcrError("Azure endpoint is not set.")
    if not key:
        raise OcrError("Azure key is not set.")
    uri = endpoint.rstrip("/") + "/vision/v3.2/ocr?language=unk&detectOrientation=true"
    payload = _http_json(
        uri,
        data=path.read_bytes(),
        headers={"Ocp-Apim-Subscription-Key": key, "Content-Type": "application/octet-stream"},
    )
    return parse_azure(payload)


def _google(path: Path, settings: Settings) -> str:
    key = _text(settings.google_key)
    if not key:
        raise OcrError("Google Cloud Vision API key is not set.")
    b64 = _image_b64(path, "JPEG", 2500, 85)
    payload = {
        "requests": [
            {
                "image": {"content": b64},
                "features": [{"type": "TEXT_DETECTION", "maxResults": 1}],
            }
        ]
    }
    uri = "https://vision.googleapis.com/v1/images:annotate?key=" + urllib.parse.quote(key, safe="")
    response = _http_json(
        uri,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    return parse_google(response)


_OAUTH_CACHE: dict[tuple[str, str], tuple[str, float]] = {}


def _oauth_token(settings: Settings) -> str:
    token_url = _text(settings.paddle_token_url)
    client_id = _text(settings.paddle_client_id)
    client_secret = _text(settings.paddle_client_secret)
    if not (token_url and client_id and client_secret):
        return ""
    cache_key = (token_url, client_id)
    cached = _OAUTH_CACHE.get(cache_key)
    if cached and cached[1] > time.monotonic():
        return cached[0]
    body = {
        "grant_type": "client_credentials",
        "client_id": client_id,
        "client_secret": client_secret,
    }
    scope = _text(settings.paddle_scope)
    if scope:
        body["scope"] = scope
    payload = _http_json(
        token_url,
        data=urllib.parse.urlencode(body).encode("utf-8"),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        timeout=60,
    )
    token = _text(payload.get("access_token"))
    if not token:
        raise OcrError("OAuth2 token endpoint returned no access_token.")
    try:
        expires = int(payload.get("expires_in") or 300)
    except Exception:
        expires = 300
    _OAUTH_CACHE[cache_key] = (token, time.monotonic() + max(60, expires - 30))
    return token


def _paddle_headers(settings: Settings) -> dict[str, str]:
    token = _oauth_token(settings)
    if token:
        return {"Authorization": "Bearer " + token}
    key = _text(settings.paddle_key)
    if not key:
        return {}
    header = _text(settings.paddle_key_header) or "Authorization"
    if header.lower() == "authorization" and not re.match(r"(?i)^\s*(Bearer|Basic)\s", key):
        key = "Bearer " + key
    return {header: key}


def _multipart_body(path: Path, boundary: str) -> bytes:
    image = _image_bytes(path, "JPEG", 2500, 88)
    head = (
        f"--{boundary}\r\n"
        'Content-Disposition: form-data; name="file"; filename="image.jpg"\r\n'
        "Content-Type: image/jpeg\r\n\r\n"
    ).encode("utf-8")
    tail = f"\r\n--{boundary}--\r\n".encode("utf-8")
    return head + image + tail


def _paddle(path: Path, settings: Settings) -> str:
    endpoint = _text(settings.paddle_endpoint)
    if not endpoint:
        raise OcrError("PaddleOCR endpoint URL is not set.")
    headers = _paddle_headers(settings)
    mode = (_text(settings.paddle_mode) or "hub").lower()
    if mode in ("imageurl", "image_url", "gravitee"):
        b64 = _image_b64(path, "PNG", 2200)
        body = json.dumps({"input": [{"type": "image_url", "url": "data:image/png;base64," + b64}]}).encode("utf-8")
        headers["Content-Type"] = "application/json"
    elif mode == "multipart":
        boundary = uuid.uuid4().hex
        body = _multipart_body(path, boundary)
        headers["Content-Type"] = f"multipart/form-data; boundary={boundary}"
    else:
        b64 = _image_b64(path, "JPEG", 2500, 88)
        body = json.dumps({"images": [b64]}).encode("utf-8")
        headers["Content-Type"] = "application/json"
    payload = _http_json(endpoint, data=body, headers=headers, timeout=120)
    text = extract_text_any(payload)
    if not text:
        raise OcrError("PaddleOCR returned no text. Check the endpoint URL and request mode.")
    return text


def _run_cloud(provider: str, path: Path, settings: Settings) -> str:
    if provider == "ocrspace":
        return _ocr_space(path, settings)
    if provider == "azure":
        return _azure(path, settings)
    if provider == "google":
        return _google(path, settings)
    if provider == "paddle":
        return _paddle(path, settings)
    raise OcrError(f"Unknown OCR provider: {provider}")


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------
def run_ocr(path: str | Path, settings: Settings | None = None) -> OcrOutcome:
    """Run OCR using the configured provider, with built-in fallback."""
    settings = settings or Settings()
    path = Path(path)
    if not path.exists():
        raise OcrUnavailable("Image file not found.")
    chosen = (settings.ocr_provider or "auto").strip().lower()
    if chosen not in PROVIDERS:
        chosen = "auto"
    cloud = configured_cloud_provider(settings) if chosen in ("auto", "builtin") else chosen
    if cloud is None or chosen == "builtin":
        text, engine = _run_builtin(path, settings)
        if not text.strip():
            raise OcrError("No readable text was found in that image.")
        return OcrOutcome(text=text.strip(), provider="builtin:" + engine)

    label = provider_label(cloud)
    try:
        text = _run_cloud(cloud, path, settings)
        if not text.strip():
            raise OcrError("The provider returned no text.")
        return OcrOutcome(text=text.strip(), provider=cloud)
    except Exception as cloud_exc:
        reason = str(cloud_exc).strip().rstrip(".")
        notice = f"{label} failed: {reason}. Used built-in OCR instead."
        try:
            fallback, engine = _run_builtin(path, settings)
        except Exception as builtin_exc:
            raise OcrError(f"{label} failed: {reason}. Built-in OCR also failed: {builtin_exc}") from builtin_exc
        if not fallback.strip():
            raise OcrError(f"{label} failed: {reason}. Built-in OCR found no text.")
        return OcrOutcome(text=fallback.strip(), provider="builtin:" + engine, notice=notice)


def recognize_text(path: str | Path, settings: Settings | None = None) -> str:
    """Backward-compatible helper used by tests and simple callers."""
    return run_ocr(path, settings).text


def recognize_with_provider(path: str | Path, settings: Settings) -> OcrOutcome:
    return run_ocr(path, settings)


class OcrWorker(QThread):
    recognized = pyqtSignal(str)
    failed = pyqtSignal(str)
    notice = pyqtSignal(str)

    def __init__(self, path: str | Path, settings: Settings | None = None, parent=None):
        super().__init__(parent)
        self.path = Path(path)
        self.settings = replace(settings) if settings is not None else Settings()

    def run(self) -> None:
        try:
            outcome = run_ocr(self.path, self.settings)
            if outcome.notice:
                self.notice.emit(outcome.notice)
            self.recognized.emit(outcome.text)
        except Exception as exc:
            self.failed.emit(str(exc))


def make_test_image(text: str = "Clippr OCR test 12345") -> Path:
    """Create a temporary PNG with text, used by tests and authentication."""
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
