"""文本笔记「编辑旁车」的单测。

两条硬约束：
1. 没有旁车时，去重哈希必须**等于正文 sha256**——否则升级后所有历史音频
   都会被当成"没处理过"，启动时把整个 outbox 重跑一遍。
2. 旁车一变（只改标签、正文没动），哈希必须变——否则用户改的标签永远
   到不了 Mac，App 上看着像"改了没生效"。
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from note_meta import (  # noqa: E402
    MAX_USER_TAGS,
    META_SUFFIX,
    digest_for,
    meta_path,
    note_path_for_meta,
    read_meta,
)
from state import sha256_of  # noqa: E402


class TempNote:
    """临时目录里的一条文本笔记 + 它的旁车。"""

    def __init__(self) -> None:
        self._dir = tempfile.TemporaryDirectory()
        self.root = Path(self._dir.name)
        self.note = self.root / "memo_20261115_153000.txt"
        self.note.write_text("原始正文", encoding="utf-8")

    def write_meta(self, payload: dict | str) -> Path:
        path = meta_path(self.note)
        text = payload if isinstance(payload, str) else json.dumps(
            payload, ensure_ascii=False
        )
        path.write_text(text, encoding="utf-8")
        return path

    def close(self) -> None:
        self._dir.cleanup()


class MetaPathTest(unittest.TestCase):
    def test_meta_path_keeps_the_id(self) -> None:
        note = Path("/tmp/Me_Notes/outbox/memo_20261115_153000.txt")
        self.assertEqual(
            meta_path(note).name, f"memo_20261115_153000{META_SUFFIX}"
        )
        self.assertEqual(meta_path(note).parent, note.parent)

    def test_meta_maps_back_to_note(self) -> None:
        item = TempNote()
        try:
            self.assertEqual(note_path_for_meta(meta_path(item.note)), item.note)
        finally:
            item.close()

    def test_markdown_note_also_supported(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            md = root / "memo_20261115_153000.md"
            md.write_text("正文", encoding="utf-8")
            self.assertEqual(note_path_for_meta(root / f"memo_20261115_153000{META_SUFFIX}"), md)

    def test_orphan_meta_returns_none(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            orphan = root / f"memo_20261115_153000{META_SUFFIX}"
            orphan.write_text("{}", encoding="utf-8")
            self.assertIsNone(note_path_for_meta(orphan))

    def test_non_meta_name_returns_none(self) -> None:
        self.assertIsNone(note_path_for_meta(Path("/tmp/memo.txt")))


class ReadMetaTest(unittest.TestCase):
    def test_missing_meta_is_none(self) -> None:
        item = TempNote()
        try:
            self.assertIsNone(read_meta(item.note))
        finally:
            item.close()

    def test_broken_json_is_none(self) -> None:
        item = TempNote()
        try:
            item.write_meta("{ 这不是 json")
            self.assertIsNone(read_meta(item.note))
        finally:
            item.close()

    def test_non_object_is_none(self) -> None:
        item = TempNote()
        try:
            item.write_meta('["手语"]')
            self.assertIsNone(read_meta(item.note))
        finally:
            item.close()

    def test_standard_payload(self) -> None:
        item = TempNote()
        try:
            item.write_meta(
                {
                    "id": "memo_20261115_153000",
                    "tags": ["手语", "无障碍"],
                    "tags_edited": True,
                    "edited_at": "2026-11-15 15:30:00",
                }
            )
            meta = read_meta(item.note)
            assert meta is not None
            self.assertEqual(meta.tags, ["手语", "无障碍"])
            self.assertTrue(meta.tags_edited)
            self.assertEqual(meta.edited_at, "2026-11-15 15:30:00")
        finally:
            item.close()

    def test_comma_string_and_duplicates(self) -> None:
        item = TempNote()
        try:
            item.write_meta({"tags": "手语，无障碍、手语", "tags_edited": True})
            meta = read_meta(item.note)
            assert meta is not None
            self.assertEqual(meta.tags, ["手语", "无障碍"])
        finally:
            item.close()

    def test_legacy_payload_without_flag_is_treated_as_edited(self) -> None:
        item = TempNote()
        try:
            item.write_meta({"tags": ["手语"]})
            meta = read_meta(item.note)
            assert meta is not None
            self.assertTrue(meta.tags_edited)
        finally:
            item.close()

    def test_cleared_tags_still_count_as_edited(self) -> None:
        # 用户把标签全删了，也是"用户说了算"，不能让 AI 再补回来。
        item = TempNote()
        try:
            item.write_meta({"tags": [], "tags_edited": True})
            meta = read_meta(item.note)
            assert meta is not None
            self.assertEqual(meta.tags, [])
            self.assertTrue(meta.tags_edited)
        finally:
            item.close()

    def test_too_many_tags_are_truncated(self) -> None:
        item = TempNote()
        try:
            item.write_meta(
                {"tags": [f"标签{i}" for i in range(20)], "tags_edited": True}
            )
            meta = read_meta(item.note)
            assert meta is not None
            self.assertEqual(len(meta.tags), MAX_USER_TAGS)
        finally:
            item.close()

    def test_overlong_tag_is_dropped(self) -> None:
        item = TempNote()
        try:
            item.write_meta({"tags": ["x" * 40, "手语"], "tags_edited": True})
            meta = read_meta(item.note)
            assert meta is not None
            self.assertEqual(meta.tags, ["手语"])
        finally:
            item.close()


class DigestTest(unittest.TestCase):
    def test_without_meta_digest_is_plain_sha256(self) -> None:
        # 这条是升级安全阀：历史音频没有旁车，哈希必须保持原样。
        item = TempNote()
        try:
            self.assertEqual(digest_for(item.note), sha256_of(item.note))
        finally:
            item.close()

    def test_meta_changes_digest_even_if_text_is_untouched(self) -> None:
        item = TempNote()
        try:
            before = digest_for(item.note)
            item.write_meta({"tags": ["手语"], "tags_edited": True})
            after = digest_for(item.note)
            self.assertNotEqual(before, after)
        finally:
            item.close()

    def test_editing_tags_again_changes_digest_again(self) -> None:
        item = TempNote()
        try:
            item.write_meta({"tags": ["手语"], "tags_edited": True})
            first = digest_for(item.note)
            item.write_meta({"tags": ["手语", "无障碍"], "tags_edited": True})
            second = digest_for(item.note)
            self.assertNotEqual(first, second)
        finally:
            item.close()

    def test_text_edit_changes_digest(self) -> None:
        item = TempNote()
        try:
            item.write_meta({"tags": ["手语"], "tags_edited": True})
            before = digest_for(item.note)
            item.note.write_text("原始正文，又补了一句", encoding="utf-8")
            self.assertNotEqual(before, digest_for(item.note))
        finally:
            item.close()

    def test_broken_meta_still_participates(self) -> None:
        # 坏旁车也要算进哈希：否则用户修好它的那一刻反而不会触发重跑。
        item = TempNote()
        try:
            before = digest_for(item.note)
            item.write_meta("{ 坏的")
            self.assertNotEqual(before, digest_for(item.note))
        finally:
            item.close()

    def test_digest_is_stable_for_same_content(self) -> None:
        item = TempNote()
        try:
            item.write_meta({"tags": ["手语"], "tags_edited": True})
            self.assertEqual(digest_for(item.note), digest_for(item.note))
        finally:
            item.close()


if __name__ == "__main__":
    unittest.main()
