"""词典纠错的回归测试。

这里每一条都对应一次真实的踩坑，别再改回去：

- 「万圣洁 → 万圣节」：同音不同调的专名必须能纠；
- 「显示 → 显式」「置里 → 治理」：THUOCL 是名词库、不收常用动词，
  早期版本把整个词库当替换候选，把正常口语改坏了；
- 「一下 → 地下」：2 字词的近音候选全是噪音，只允许 3 字以上做近音提示。
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from corrector import (  # noqa: E402
    collect_hints,
    correct,
    get_lexicon,
    syllable_distance,
    syllables,
)


class SyllableTest(unittest.TestCase):
    def test_homophone_same_key(self) -> None:
        self.assertEqual(syllables("万圣节"), syllables("万圣洁"))

    def test_near_pinyin_detected(self) -> None:
        # 温盛节 / 万圣节：只有第一个音节差一个字母（en → an）
        self.assertEqual(
            syllable_distance(syllables("温盛节"), syllables("万圣节")), 1
        )

    def test_unrelated_not_matched(self) -> None:
        self.assertIsNone(
            syllable_distance(syllables("停车场"), syllables("棉花糖"))
        )


class LexiconTest(unittest.TestCase):
    def setUp(self) -> None:
        self.lexicon = get_lexicon()
        if self.lexicon is None:  # pragma: no cover - 依赖缺失时跳过
            self.skipTest("pypinyin 或词库不可用")

    def test_lexicon_loaded(self) -> None:
        self.assertGreater(len(self.lexicon.words), 100_000)

    def test_custom_daily_nouns_present(self) -> None:
        for word in ("万圣节", "停车场", "蓝牙耳机", "快递站"):
            self.assertIn(word, self.lexicon.words)


class CorrectTest(unittest.TestCase):
    def test_fixes_homophone_proper_noun(self) -> None:
        result = correct("Hello。万圣洁。停车,停在哪?")
        self.assertEqual(result.text, "Hello。万圣节。停车,停在哪?")
        self.assertEqual(
            result.as_dicts(),
            [{"from": "万圣洁", "to": "万圣节", "source": "custom"}],
        )

    def test_does_not_break_common_words(self) -> None:
        # 回归：THUOCL 不收「显示」，早期版本会把它改成「显式」。
        text = "需要新增一个页面显示左右的待办事项。然后设置里还是提示fts5未编译"
        self.assertEqual(correct(text).text, text)

    def test_leaves_clean_sentence_untouched(self) -> None:
        text = "这是第一次测试，看看成不成功"
        result = correct(text)
        self.assertEqual(result.text, text)
        self.assertFalse(result.changed)

    def test_personal_terms_enable_replacement(self) -> None:
        # 「棉花唐」不在词库，但家庭词汇里有「棉花糖」，同音即可纠正。
        result = correct("去棉花唐家", personal_terms=["棉花糖"])
        self.assertEqual(result.text, "去棉花糖家")
        self.assertEqual(result.corrections[0].source, "personal")

    def test_max_replacements_capped(self) -> None:
        text = "万圣洁万圣洁万圣洁万圣洁万圣洁"
        result = correct(text, max_replacements=2)
        self.assertEqual(len(result.corrections), 2)

    def test_empty_input(self) -> None:
        result = correct("")
        self.assertEqual(result.text, "")
        self.assertFalse(result.changed)


class HintTest(unittest.TestCase):
    def test_near_pinyin_hint_for_three_chars(self) -> None:
        hints = collect_hints("温盛节那天去停车场接娃")
        self.assertTrue(hints)
        self.assertEqual(hints[0]["fragment"], "温盛节")
        self.assertIn("万圣节", hints[0]["candidates"])

    def test_no_noise_for_two_char_fragments(self) -> None:
        # 回归：「一下 / 地下」「第一 / 弟弟」这类 2 字近音全是噪音。
        hints = collect_hints("这是第一次测试，看看成不成功")
        self.assertEqual(hints, [])

    def test_no_hint_for_known_words(self) -> None:
        hints = collect_hints("今天去停车场接孩子")
        self.assertEqual(hints, [])


if __name__ == "__main__":
    unittest.main()
