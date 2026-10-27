"""Tests for OCR provider resolution, parsers and fallbacks (no network)."""
from __future__ import annotations

import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from clippr.config import Settings  # noqa: E402
from clippr.ocr import (  # noqa: E402
    OcrOutcome,
    OcrUnavailable,
    configured_cloud_provider,
    extract_text_any,
    make_test_image,
    parse_azure,
    parse_google,
    parse_ocr_space,
    run_ocr,
)


def test_cloud_resolution() -> None:
    assert configured_cloud_provider(Settings()) is None
    assert configured_cloud_provider(Settings(ocr_space_key="abc")) == "ocrspace"
    assert configured_cloud_provider(Settings(azure_key="k", azure_endpoint="https://x")) == "azure"
    assert configured_cloud_provider(Settings(google_key="k")) == "google"
    assert configured_cloud_provider(Settings(paddle_endpoint="https://x")) == "paddle"
    assert configured_cloud_provider(Settings(ocr_provider="google", google_key="")) == "google"
    assert configured_cloud_provider(Settings(ocr_provider="builtin", google_key="k")) is None
    print("PASS cloud provider resolution")


def test_parsers() -> None:
    assert parse_ocr_space({"ParsedResults": [{"ParsedText": "one"}, {"ParsedText": "two"}]}) == "onetwo"
    try:
        parse_ocr_space({"IsErroredOnProcessing": True, "ErrorMessage": ["bad key"]})
    except Exception as exc:
        assert "bad key" in str(exc)
    else:
        raise AssertionError("OCR.space error was not raised")
    azure = {"regions": [{"lines": [{"words": [{"text": "Hello"}, {"text": "world"}]}]}]}
    assert parse_azure(azure) == "Hello world"
    google = {"responses": [{"fullTextAnnotation": {"text": "full text"}}]}
    assert parse_google(google) == "full text"
    google = {"responses": [{"textAnnotations": [{"description": "annotation"}]}]}
    assert parse_google(google) == "annotation"
    assert extract_text_any({"result": {"rec_texts": ["alpha", "beta"]}}) == "alpha\nbeta"
    assert extract_text_any({"data": {"texts": [{"text": "nested"}]}}) == "nested"
    print("PASS response parsers")


def test_cloud_failure_falls_back() -> None:
    path = make_test_image("Fallback OCR test 9876")
    try:
        settings = Settings(ocr_provider="ocrspace", ocr_space_key="")
        outcome = run_ocr(path, settings)
        assert outcome.text.strip(), "built-in fallback produced no text"
        assert "OCR.space API key is not set" in outcome.notice
        print("PASS cloud failure -> built-in fallback")
    finally:
        path.unlink(missing_ok=True)


def test_platform_switch_is_explicit() -> None:
    path = make_test_image("Engine switch test 555")
    try:
        if sys.platform == "win32":
            settings = Settings(ocr_provider="builtin", ocr_builtin_engine="macos")
            try:
                run_ocr(path, settings)
            except OcrUnavailable as exc:
                assert "only available on macOS" in str(exc)
            else:
                raise AssertionError("macOS engine should not run on Windows")
        else:
            settings = Settings(ocr_provider="builtin", ocr_builtin_engine="windows")
            try:
                run_ocr(path, settings)
            except OcrUnavailable as exc:
                assert "only available on Windows" in str(exc)
            else:
                raise AssertionError("Windows engine should not run here")
        print("PASS explicit OS engine guard")
    finally:
        path.unlink(missing_ok=True)


if __name__ == "__main__":
    test_cloud_resolution()
    test_parsers()
    test_cloud_failure_falls_back()
    test_platform_switch_is_explicit()
    print("ALL OCR CONFIG TESTS PASSED")
