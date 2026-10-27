"""Exercise the application controller, tray and persistence."""
from __future__ import annotations

import os
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
DATA = Path(tempfile.gettempdir()) / "opencode" / "clippr-py-app-test"
shutil.rmtree(DATA, ignore_errors=True)
DATA.mkdir(parents=True)
os.environ["CLIPPR_DATA_DIR"] = str(DATA)

from PyQt6.QtCore import QTimer  # noqa: E402

from clippr.app import ClipprApp  # noqa: E402


def main() -> int:
    cli = ClipprApp([sys.argv[0]])
    assert cli.window is not None, "window was not created"
    assert cli.tray is not None, "system tray is unavailable"
    cli.window.show()
    cli.window.resize(1040, 704)

    def finish() -> None:
        cli.window.hide()
        cli._on_hidden_to_tray()
        assert cli.toast is not None and cli.toast.isVisible(), "toast did not show"
        print("PASS tray + toast")
        cli.quit()

    QTimer.singleShot(900, finish)
    code = cli.run()
    print("PASS app quit, code", code)
    assert (DATA / "history.json").exists(), "history was not saved"
    assert (DATA / "settings.json").exists(), "settings were not saved"
    print("PASS persistence", sorted(p.name for p in DATA.iterdir()))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
