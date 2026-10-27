"""Persistent clipboard history and tab model."""
from __future__ import annotations

import hashlib
import json
import time
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path

from .config import _atomic_json

VIEW_ALL = "All items"
VIEW_TEXT = "Text"
VIEW_IMAGES = "Images"
VIEW_NAMES = (VIEW_ALL, VIEW_TEXT, VIEW_IMAGES)
GENERAL_TAB = "General"


@dataclass
class HistoryItem:
    id: str
    kind: str                  # "text" or "image"
    text: str
    tab: str
    created: float
    hash: str
    image: str = ""            # filename under images/
    width: int = 0
    height: int = 0
    ocr_text: str = ""

    @property
    def created_label(self) -> str:
        return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(self.created))

    def short_time(self) -> str:
        now = time.time()
        if now - self.created < 60:
            return "just now"
        if now - self.created < 3600:
            return f"{int((now - self.created) / 60)} min ago"
        if now - self.created < 86400:
            return f"{int((now - self.created) / 3600)} h ago"
        return time.strftime("%d %b, %H:%M", time.localtime(self.created))

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, data: dict) -> "HistoryItem":
        known = {f for f in cls.__dataclass_fields__}
        return cls(**{k: v for k, v in data.items() if k in known})


@dataclass
class StoreData:
    version: int = 1
    items: list[HistoryItem] = field(default_factory=list)
    tabs: list[str] = field(default_factory=lambda: [GENERAL_TAB])
    active_tab: str = GENERAL_TAB
    last_tab: str = GENERAL_TAB


class HistoryStore:
    def __init__(self, data_dir: Path, history_limit: int = 300):
        self.data_dir = Path(data_dir)
        self.images_dir = self.data_dir / "images"
        self.images_dir.mkdir(parents=True, exist_ok=True)
        self.path = self.data_dir / "history.json"
        self.history_limit = max(20, int(history_limit))
        self.data = StoreData()
        self.load()

    # ---------- persistence ----------
    def load(self) -> None:
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8"))
            items = [HistoryItem.from_dict(x) for x in raw.get("items", []) if isinstance(x, dict)]
            tabs = [str(x) for x in raw.get("tabs", [GENERAL_TAB]) if str(x).strip()]
            if not tabs:
                tabs = [GENERAL_TAB]
            if GENERAL_TAB not in tabs:
                tabs.insert(0, GENERAL_TAB)
            active = str(raw.get("active_tab") or GENERAL_TAB)
            if active not in tabs and active not in VIEW_NAMES:
                active = GENERAL_TAB
            last = str(raw.get("last_tab") or GENERAL_TAB)
            if last not in tabs:
                last = GENERAL_TAB
            self.data = StoreData(items=items, tabs=tabs, active_tab=active, last_tab=last)
        except Exception:
            self.data = StoreData()
        self._normalise_items()

    def _normalise_items(self) -> None:
        seen = set()
        clean: list[HistoryItem] = []
        for item in self.data.items:
            if not item.id:
                item.id = uuid.uuid4().hex
            if item.tab not in self.data.tabs:
                item.tab = GENERAL_TAB
            if item.kind == "image" and item.image:
                if not (self.images_dir / item.image).exists():
                    continue
            if item.kind == "text" and not item.text:
                continue
            if item.id in seen:
                continue
            seen.add(item.id)
            clean.append(item)
        self.data.items = clean
        self._prune()

    def save(self) -> None:
        payload = {
            "version": self.data.version,
            "items": [i.to_dict() for i in self.data.items],
            "tabs": self.data.tabs,
            "active_tab": self.data.active_tab,
            "last_tab": self.data.last_tab,
        }
        _atomic_json(self.path, payload)

    def prune(self) -> None:
        self._prune()

    def _prune(self) -> None:
        if len(self.data.items) <= self.history_limit:
            return
        removed = self.data.items[self.history_limit:]
        self.data.items = self.data.items[: self.history_limit]
        for item in removed:
            self.delete_image(item)

    # ---------- queries ----------
    @property
    def items(self) -> list[HistoryItem]:
        return self.data.items

    @property
    def tabs(self) -> list[str]:
        return self.data.tabs

    @property
    def active_tab(self) -> str:
        return self.data.active_tab

    @active_tab.setter
    def active_tab(self, name: str) -> None:
        if name in VIEW_NAMES or name in self.data.tabs:
            self.data.active_tab = name
            if name in self.data.tabs:
                self.data.last_tab = name

    def target_tab(self) -> str:
        if self.data.active_tab in self.data.tabs:
            return self.data.active_tab
        return self.data.last_tab if self.data.last_tab in self.data.tabs else GENERAL_TAB

    def tab_count(self, name: str) -> int:
        if name == VIEW_ALL:
            return len(self.data.items)
        if name == VIEW_TEXT:
            return sum(1 for i in self.data.items if i.kind == "text")
        if name == VIEW_IMAGES:
            return sum(1 for i in self.data.items if i.kind == "image")
        return sum(1 for i in self.data.items if i.tab == name)

    def filtered(self, view: str, search: str = "") -> list[HistoryItem]:
        if view == VIEW_TEXT:
            items = [i for i in self.data.items if i.kind == "text"]
        elif view == VIEW_IMAGES:
            items = [i for i in self.data.items if i.kind == "image"]
        elif view in self.data.tabs:
            items = [i for i in self.data.items if i.tab == view]
        else:
            items = list(self.data.items)
        q = (search or "").strip().lower()
        if not q:
            return items
        out = []
        for item in items:
            hay = " ".join((item.text or "", item.ocr_text or "", item.tab, item.kind)).lower()
            if q in hay:
                out.append(item)
        return out

    def get(self, item_id: str) -> HistoryItem | None:
        return next((i for i in self.data.items if i.id == item_id), None)

    # ---------- mutations ----------
    def add_text(self, text: str, tab: str | None = None) -> HistoryItem | None:
        text = (text or "").replace("\x00", "").strip("\n")
        if not text.strip():
            return None
        digest = hashlib.sha1(text.encode("utf-8", "replace")).hexdigest()
        if self.data.items and self.data.items[0].hash == digest:
            self.data.items[0].created = time.time()
            return None
        existing = next((i for i in self.data.items if i.hash == digest and i.kind == "text"), None)
        if existing is not None:
            self.data.items.remove(existing)
            existing.created = time.time()
            self.data.items.insert(0, existing)
            return existing
        item = HistoryItem(
            id=uuid.uuid4().hex,
            kind="text",
            text=text,
            tab=tab or self.target_tab(),
            created=time.time(),
            hash=digest,
        )
        self.data.items.insert(0, item)
        self._prune()
        return item

    def add_image(self, png_bytes: bytes, width: int, height: int, tab: str | None = None) -> HistoryItem | None:
        if not png_bytes:
            return None
        digest = hashlib.sha1(png_bytes).hexdigest()
        if self.data.items and self.data.items[0].hash == digest:
            self.data.items[0].created = time.time()
            return None
        existing = next((i for i in self.data.items if i.hash == digest and i.kind == "image"), None)
        if existing is not None:
            self.data.items.remove(existing)
            existing.created = time.time()
            self.data.items.insert(0, existing)
            return existing
        name = f"{digest[:20]}.png"
        path = self.images_dir / name
        if not path.exists():
            path.write_bytes(png_bytes)
        item = HistoryItem(
            id=uuid.uuid4().hex,
            kind="image",
            text="",
            tab=tab or self.target_tab(),
            created=time.time(),
            hash=digest,
            image=name,
            width=int(width),
            height=int(height),
        )
        self.data.items.insert(0, item)
        self._prune()
        return item

    def update_ocr(self, item_id: str, text: str) -> None:
        item = self.get(item_id)
        if item is not None:
            item.ocr_text = text or ""

    def delete(self, item_id: str) -> bool:
        item = self.get(item_id)
        if item is None:
            return False
        self.data.items.remove(item)
        self.delete_image(item)
        return True

    def clear_view(self, view: str) -> int:
        if view == VIEW_TEXT:
            doomed = [i for i in self.data.items if i.kind == "text"]
        elif view == VIEW_IMAGES:
            doomed = [i for i in self.data.items if i.kind == "image"]
        elif view in self.data.tabs:
            doomed = [i for i in self.data.items if i.tab == view]
        else:
            doomed = list(self.data.items)
        for item in doomed:
            if item in self.data.items:
                self.data.items.remove(item)
            self.delete_image(item)
        return len(doomed)

    def delete_image(self, item: HistoryItem) -> None:
        if item.kind != "image" or not item.image:
            return
        try:
            (self.images_dir / item.image).unlink(missing_ok=True)
        except OSError:
            pass

    def image_path(self, item: HistoryItem) -> Path | None:
        if item.kind != "image" or not item.image:
            return None
        p = self.images_dir / item.image
        return p if p.exists() else None

    # ---------- tabs ----------
    def add_tab(self, name: str) -> bool:
        name = (name or "").strip()
        if not name or name in VIEW_NAMES or name in self.data.tabs:
            return False
        self.data.tabs.append(name)
        return True

    def rename_tab(self, old: str, new: str) -> bool:
        old = (old or "").strip()
        new = (new or "").strip()
        if old not in self.data.tabs or old == GENERAL_TAB:
            return False
        if not new or new in VIEW_NAMES or new in self.data.tabs:
            return False
        idx = self.data.tabs.index(old)
        self.data.tabs[idx] = new
        for item in self.data.items:
            if item.tab == old:
                item.tab = new
        if self.data.active_tab == old:
            self.data.active_tab = new
        if self.data.last_tab == old:
            self.data.last_tab = new
        return True

    def delete_tab(self, name: str) -> bool:
        name = (name or "").strip()
        if name not in self.data.tabs or name == GENERAL_TAB:
            return False
        self.clear_view(name)
        self.data.tabs.remove(name)
        if self.data.active_tab == name:
            self.data.active_tab = GENERAL_TAB
        if self.data.last_tab == name:
            self.data.last_tab = GENERAL_TAB
        return True
