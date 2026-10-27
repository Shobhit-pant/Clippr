"""Unit tests for the history store."""
from __future__ import annotations

import shutil
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from clippr.store import GENERAL_TAB, VIEW_ALL, VIEW_IMAGES, VIEW_TEXT, HistoryStore  # noqa: E402


class StoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = Path(tempfile.gettempdir()) / "opencode" / "clippr-py-store-test"
        shutil.rmtree(self.dir, ignore_errors=True)
        self.dir.mkdir(parents=True)
        self.store = HistoryStore(self.dir, 40)

    def tearDown(self) -> None:
        shutil.rmtree(self.dir, ignore_errors=True)

    def test_text_dedup_and_order(self) -> None:
        a = self.store.add_text("alpha")
        b = self.store.add_text("beta")
        self.assertIsNotNone(a)
        self.assertIsNotNone(b)
        self.assertEqual([i.text for i in self.store.items], ["beta", "alpha"])
        again = self.store.add_text("alpha")
        self.assertEqual(again.text, "alpha")
        self.assertEqual([i.text for i in self.store.items], ["alpha", "beta"])
        self.assertIsNone(self.store.add_text("   "))

    def test_views_and_tabs(self) -> None:
        self.store.add_text("text one", tab="General")
        self.store.add_image(self._png(), 4, 4, tab="General")
        self.assertEqual(len(self.store.filtered(VIEW_ALL)), 2)
        self.assertEqual(len(self.store.filtered(VIEW_TEXT)), 1)
        self.assertEqual(len(self.store.filtered(VIEW_IMAGES)), 1)
        self.assertTrue(self.store.add_tab("Ideas"))
        self.store.add_text("idea", tab="Ideas")
        self.assertEqual(len(self.store.filtered("Ideas")), 1)
        self.assertEqual([i.text for i in self.store.filtered(VIEW_ALL, "idea")], ["idea"])
        self.assertTrue(self.store.rename_tab("Ideas", "Sparks"))
        self.assertEqual(len(self.store.filtered("Sparks")), 1)
        self.assertTrue(self.store.delete_tab("Sparks"))
        self.assertNotIn("Sparks", self.store.tabs)

    def test_persistence(self) -> None:
        self.store.add_text("persist me", tab="General")
        self.store.add_tab("Keep")
        self.store.add_text("in tab", tab="Keep")
        self.store.active_tab = "Keep"
        self.store.save()
        reloaded = HistoryStore(self.dir, 40)
        self.assertEqual(len(reloaded.items), 2)
        self.assertIn("Keep", reloaded.tabs)
        self.assertEqual(reloaded.active_tab, "Keep")
        self.assertEqual(reloaded.filtered("Keep")[0].text, "in tab")

    def test_prune_and_delete_images(self) -> None:
        small = HistoryStore(self.dir, 20)
        for n in range(25):
            small.add_text(f"item {n}")
        self.assertEqual(len(small.items), 20)
        self.assertEqual(small.items[0].text, "item 24")
        img = small.add_image(self._png(), 4, 4)
        path = small.image_path(img)
        self.assertIsNotNone(path)
        self.assertTrue(small.delete(img.id))
        self.assertFalse(path.exists())

    def _png(self) -> bytes:
        from PIL import Image
        import io

        buf = io.BytesIO()
        Image.new("RGB", (4, 4), "white").save(buf, "PNG")
        return buf.getvalue()


if __name__ == "__main__":
    unittest.main(verbosity=2)
