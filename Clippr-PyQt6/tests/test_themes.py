"""Theme and settings round-trip tests."""
from __future__ import annotations

import shutil
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from clippr.config import Settings  # noqa: E402
from clippr.themes import DEFAULT_THEME, THEMES, build_qss, theme  # noqa: E402


class ThemeTests(unittest.TestCase):
    def test_four_named_themes(self) -> None:
        self.assertEqual(set(THEMES), {"swiss", "brass", "brutal", "calm"})
        self.assertEqual(theme("nope").key, DEFAULT_THEME)
        for key, t in THEMES.items():
            qss = build_qss(t)
            self.assertIn(t.accent, qss)
            self.assertIn(t.bg, qss)
            self.assertIn("QListView#History", qss)
            self.assertNotIn("{t.", qss)

    def test_settings_roundtrip(self) -> None:
        d = Path(tempfile.gettempdir()) / "opencode" / "clippr-py-settings-test"
        shutil.rmtree(d, ignore_errors=True)
        d.mkdir(parents=True)
        p = d / "settings.json"
        s = Settings(theme="calm", strip_images=False, history_limit=123)
        s.save(p)
        loaded = Settings.load(p)
        self.assertEqual(loaded.theme, "calm")
        self.assertFalse(loaded.strip_images)
        self.assertEqual(loaded.history_limit, 123)
        shutil.rmtree(d, ignore_errors=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
