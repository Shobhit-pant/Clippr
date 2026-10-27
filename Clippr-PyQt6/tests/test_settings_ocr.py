"""Exercise the OCR settings tab and the Authenticate button."""
from __future__ import annotations

import os
import shutil
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt6.QtWidgets import QApplication  # noqa: E402

from clippr.config import Settings  # noqa: E402
from clippr.dialogs import SettingsDialog  # noqa: E402
from clippr.store import HistoryStore  # noqa: E402


def pump(app, ms=100):
    end = time.monotonic() + ms / 1000
    while time.monotonic() < end:
        app.processEvents()
        time.sleep(0.01)


def wait_test(app, dlg, timeout=50):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        app.processEvents()
        if dlg.btn_test.isEnabled() and dlg._test_worker is None:
            return
        time.sleep(0.03)
    raise AssertionError("Authenticate button did not finish")


def main() -> int:
    app = QApplication(sys.argv)
    data = Path(tempfile.gettempdir()) / "opencode" / "clippr-py-settings-ocr"
    shutil.rmtree(data, ignore_errors=True)
    data.mkdir(parents=True)
    store = HistoryStore(data, 20)
    settings = Settings(ocr_provider="builtin", ocr_builtin_engine="auto")
    dlg = SettingsDialog(settings, store, data, "swiss")
    dlg.tabs.setCurrentIndex(1)
    dlg.show()
    pump(app, 150)

    dlg.provider.setCurrentIndex(dlg.provider.findData("builtin"))
    dlg.engine.setCurrentIndex(dlg.engine.findData("auto"))
    dlg._test_provider()
    wait_test(app, dlg)
    assert "Read:" in dlg.test_status.text(), dlg.test_status.text()
    print("PASS built-in authenticate:", dlg.test_status.text()[:90])

    if sys.platform == "win32":
        dlg.engine.setCurrentIndex(dlg.engine.findData("macos"))
        dlg._test_provider()
        wait_test(app, dlg)
        assert "Authentication failed" in dlg.test_status.text(), dlg.test_status.text()
        print("PASS macOS guard on Windows")
        dlg.engine.setCurrentIndex(dlg.engine.findData("auto"))

    if sys.platform == "win32":
        dlg.provider.setCurrentIndex(dlg.provider.findData("ocrspace"))
        dlg.os_key.setText("")
        dlg._test_provider()
        wait_test(app, dlg)
        assert "OCR.space failed" in dlg.test_status.text(), dlg.test_status.text()
        assert "Read:" in dlg.test_status.text(), dlg.test_status.text()
        print("PASS cloud failure falls back:", dlg.test_status.text()[:100])

    dlg._done()
    assert settings.ocr_provider == "builtin" or sys.platform == "win32"
    dlg.deleteLater()
    pump(app, 50)
    print("PASS settings OCR tab")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
