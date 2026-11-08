"""LLM 二次校正的安全护栏测试。

LLM 校正最大的风险不是改错一个字，而是顺手"润色"、补内容、或者干脆
改写整段。`_unsafe_reason` 是最后一道闸：长度、相似度、改动量任何一项
越界就整体退回原文。
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from extractor import (  # noqa: E402
    _diff_corrections,
    _is_punctuation_only,
    _unsafe_reason,
)


class UnsafeReasonTest(unittest.TestCase):
    def test_small_homophone_fix_is_safe(self) -> None:
        original = "Hello。万圣洁。停车,停在哪?"
        corrected = "Hello。万圣节。停车,停在哪?"
        self.assertEqual(_unsafe_reason(original, corrected), "")

    def test_rewrite_is_rejected(self) -> None:
        original = "今天天气很好我们去公园散步"
        corrected = "今天天气不错，我们一起去公园走走吧，顺便买点东西"
        self.assertNotEqual(_unsafe_reason(original, corrected), "")

    def test_length_blowup_rejected(self) -> None:
        original = "停车停在哪"
        corrected = "停车停在哪停车停在哪停车停在哪停车停在哪"
        self.assertIn("长度", _unsafe_reason(original, corrected))

    def test_too_many_edits_rejected(self) -> None:
        original = "一二三四五六七八九十"
        corrected = "甲乙丙丁戊己庚辛壬癸"
        self.assertNotEqual(_unsafe_reason(original, corrected), "")

    def test_identical_is_safe(self) -> None:
        text = "万圣节在停车场"
        self.assertEqual(_unsafe_reason(text, text), "")


class DiffTest(unittest.TestCase):
    def test_punctuation_is_stripped_from_entries(self) -> None:
        # 半角逗号变全角时，记录要呈现「近 → 尽」，而不是「,近 → ，尽」。
        items = _diff_corrections("对,近可能往里走", "对，尽可能往里走")
        self.assertEqual(items, [{"from": "近", "to": "尽", "source": "llm"}])

    def test_pure_punctuation_change_not_listed(self) -> None:
        self.assertEqual(_diff_corrections("停车,停在哪", "停车，停在哪"), [])

    def test_real_word_fix_listed(self) -> None:
        items = _diff_corrections("听到棉花糖家", "停到棉花糖家")
        self.assertEqual(items[0]["from"], "听")
        self.assertEqual(items[0]["to"], "停")

    def test_punctuation_only_helper(self) -> None:
        self.assertTrue(_is_punctuation_only("，。？"))
        self.assertFalse(_is_punctuation_only("停，"))


if __name__ == "__main__":
    unittest.main()
