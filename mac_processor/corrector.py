"""本地词典纠错 —— 放在 Whisper **之后**、LLM 提炼之前。

为什么不是把词典塞进 initial_prompt
------------------------------------
Whisper 的 tokenizer 是固定 51,866 词的 byte-level BPE，任何汉字组合都能编码。
「万圣洁」不是 OOV，而是解码时在同音字里**选错了**；给模型一份词典既不会
扩充它的词表，也不会给候选字加权。更硬的限制是 faster-whisper 的
`get_prompt()` 会把 initial_prompt 截到**最后 223 个 token**
（`previous_tokens[-(448 // 2 - 1):]`）。中文一个 3 字词约 4~5 token，
223 token 只够 40~50 个词；实测一个 5,000 词的词库是 33,598 token，
只有末尾 0.66% 能进模型。

所以词典的正确位置是**转写之后**，并且分成两种角色：

1. 全量 15.6 万词只用来判断「这个片段是不是一个已知词」——
   词库越大，被误判成生词的正常口语越少，纠错越安全。
2. 只有高置信专名（项目自建 custom.txt + 家庭历史词汇 + THUOCL 里
   高频的地名/人名/饮食/汽车词）才允许**自动替换**，或作为提示交给 LLM。

踩过的坑：一开始把整个 THUOCL 都当替换候选，结果它是名词词库、不收
「显示」这类常用动词，「显示」被改成「显式」，「设置里」被切成
「置里 → 治理」。改错比不改更伤，所以现在收敛成上面两条。

设计原则：宁可不改，不可改错
----------------------------
- 文字随手记（kind=text）**绝不**走这一层：那是用户亲手打的字；
- 只处理 2~5 个纯汉字、且不在词库里的片段；
- 自动替换只接受等长、拼音完全相同（无声调，覆盖同音不同调）的候选；
- 同音候选有多个且分数接近时直接放弃；
- 一条转写最多改 4 处，每处都留记录，可审计、可回退。
"""

from __future__ import annotations

import logging
import math
import re
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

try:
    from pypinyin import lazy_pinyin
except ImportError:  # pragma: no cover - 纯文本流水线不该被这一个依赖卡死
    lazy_pinyin = None  # type: ignore[assignment]

LOGGER = logging.getLogger("lvs.correct")

LEXICON_DIR = Path(__file__).resolve().parent / "lexicon"
CUSTOM_FILE = LEXICON_DIR / "custom.txt"

_CJK_RE = re.compile(r"^[\u4e00-\u9fff]+$")
_MIN_LEN = 2
_MAX_LEN = 5
_MAX_REPLACEMENTS = 4

# 允许作为高置信专名的上游类别。IT / 财经 / 法律 / 成语 / 诗词故意排除：
# 它们会把口语改成术语或文言，纠错风险远大于收益。
_PRIORITY_STEMS = frozenset(
    {"THUOCL_diming", "THUOCL_lishimingren", "THUOCL_food", "THUOCL_car"}
)
_MIN_PRIORITY_DF = 100_000
# 合成权重（log10）：custom 9 分、家庭词汇 10 分，上游词最高约 6.3 分。
_DF_CUSTOM = 1_000_000_000
_DF_PERSONAL = 10_000_000_000
_DOMINANCE = 1.0  # 最高分至少领先 1.0（10 倍）才允许自动替换


@dataclass(frozen=True)
class Correction:
    original: str
    corrected: str
    source: str  # personal / custom / lexicon

    def as_dict(self) -> dict[str, str]:
        return {"from": self.original, "to": self.corrected, "source": self.source}


@dataclass
class CorrectionResult:
    text: str
    corrections: list[Correction]

    @property
    def changed(self) -> bool:
        return bool(self.corrections)

    def as_dicts(self) -> list[dict[str, str]]:
        return [item.as_dict() for item in self.corrections]


def syllables(text: str) -> tuple[str, ...]:
    """无声调拼音音节序列。同音不同调（洁 / 节）自然相等。"""
    return tuple(lazy_pinyin(text))  # type: ignore[misc]


def _levenshtein(a: str, b: str) -> int:
    if a == b:
        return 0
    if not a:
        return len(b)
    if not b:
        return len(a)
    previous = list(range(len(b) + 1))
    for i, char_a in enumerate(a, 1):
        current = [i]
        for j, char_b in enumerate(b, 1):
            current.append(
                min(
                    current[j - 1] + 1,
                    previous[j] + 1,
                    previous[j - 1] + (char_a != char_b),
                )
            )
        previous = current
    return previous[-1]


def syllable_distance(a: tuple[str, ...], b: tuple[str, ...]) -> int | None:
    """完全相同返回 0；只有一个音节差 1 个字母返回 1；否则 None。

    覆盖 Whisper 常见的 en/an、in/ing、n/l、zh/z 混淆，
    例如「温盛节」wen sheng jie 与「万圣节」wan sheng jie。
    """
    if len(a) != len(b):
        return None
    differences = [(x, y) for x, y in zip(a, b) if x != y]
    if not differences:
        return 0
    if len(differences) > 1:
        return None
    return 1 if _levenshtein(*differences[0]) <= 1 else None


class Lexicon:
    """静态词库 + 高置信专名的拼音倒排索引，进程内只建一次。"""

    def __init__(self, root: Path = LEXICON_DIR) -> None:
        if lazy_pinyin is None:
            raise RuntimeError("缺少 pypinyin，请 pip install -r requirements.txt")
        self.words: set[str] = set()  # 全量，只用于「是不是已知词」
        self._priority: dict[str, float] = {}
        self._index: dict[tuple[str, ...], list[tuple[str, float]]] = {}
        self._load(root)
        LOGGER.info(
            "本地词库就绪：%d 个已知词，%d 个高置信专名",
            len(self.words),
            len(self._priority),
        )

    def _add_priority(self, word: str, score: float) -> None:
        old = self._priority.get(word, 0.0)
        if score <= old:
            return
        self._priority[word] = score
        bucket = self._index.setdefault(syllables(word), [])
        for position, (existing, _) in enumerate(bucket):
            if existing == word:
                bucket[position] = (word, score)
                return
        bucket.append((word, score))

    def _load(self, root: Path) -> None:
        thuocl_dir = root / "thuocl"
        custom_file = root / "custom.txt"

        for path in sorted(thuocl_dir.glob("THUOCL_*.txt")):
            eligible = path.stem in _PRIORITY_STEMS
            # 地名表是上游原文件：带 UTF-8 BOM + CR 换行，splitlines() 通吃。
            content = path.read_text(encoding="utf-8-sig", errors="replace")
            for line in content.splitlines():
                bits = line.split("\t")
                word = bits[0].strip()
                if not word:
                    continue
                self.words.add(word)
                if not eligible or not _CJK_RE.match(word):
                    continue
                if not _MIN_LEN <= len(word) <= _MAX_LEN:
                    continue
                df = int(bits[1]) if len(bits) > 1 and bits[1].strip().isdigit() else 0
                if df >= _MIN_PRIORITY_DF:
                    self._add_priority(word, math.log10(df + 1))

        if custom_file.exists():
            custom_score = math.log10(_DF_CUSTOM + 1)
            for line in custom_file.read_text(encoding="utf-8").splitlines():
                word = line.strip()
                if not word or word.startswith("#"):
                    continue
                self.words.add(word)
                if _CJK_RE.match(word) and _MIN_LEN <= len(word) <= _MAX_LEN:
                    self._add_priority(word, custom_score)

    def candidates(self, fragment: str, *, near: bool = False) -> list[tuple[str, float]]:
        """等长的高置信专名候选。near=False 只收完全同音。"""
        key = syllables(fragment)
        length = len(fragment)
        buckets = self._index.items() if near else ((key, self._index.get(key, [])),)
        found: list[tuple[str, float]] = []
        for candidate_key, bucket in buckets:
            distance = syllable_distance(key, candidate_key)
            if distance is None or (not near and distance != 0):
                continue
            for word, score in bucket:
                if len(word) == length and word != fragment:
                    found.append((word, score))
        found.sort(key=lambda item: item[1], reverse=True)
        return found


_lexicon: Lexicon | None = None
_lexicon_lock = threading.Lock()


def get_lexicon() -> Lexicon | None:
    """延迟构建：文字随手记和 --check 不需要付这 1~2 秒的启动成本。"""
    global _lexicon
    if lazy_pinyin is None:
        LOGGER.warning("未安装 pypinyin，跳过词典纠错")
        return None
    if _lexicon is None:
        with _lexicon_lock:
            if _lexicon is None:
                try:
                    _lexicon = Lexicon()
                except Exception as error:  # noqa: BLE001
                    LOGGER.warning("词库加载失败，跳过词典纠错：%s", error)
                    return None
    return _lexicon


def _personal_pool(terms: Iterable[str]) -> list[tuple[str, float]]:
    score = math.log10(_DF_PERSONAL + 1)
    pool: list[tuple[str, float]] = []
    for raw in terms:
        term = str(raw).strip()
        if _CJK_RE.match(term) and _MIN_LEN <= len(term) <= _MAX_LEN:
            pool.append((term, score))
    return pool


def _best_candidate(
    fragment: str,
    lexicon: Lexicon,
    personal: list[tuple[str, float]],
) -> tuple[str, float] | None:
    pool = list(lexicon.candidates(fragment))
    key = syllables(fragment)
    for word, score in personal:
        if len(word) == len(fragment) and word != fragment and syllables(word) == key:
            pool.append((word, score))
    if not pool:
        return None
    merged: dict[str, float] = {}
    for word, score in pool:
        merged[word] = max(merged.get(word, 0.0), score)
    ranked = sorted(merged.items(), key=lambda item: item[1], reverse=True)
    if len(ranked) > 1 and ranked[0][1] - ranked[1][1] < _DOMINANCE:
        return None
    return ranked[0]


def correct(
    text: str,
    *,
    personal_terms: Iterable[str] = (),
    max_replacements: int = _MAX_REPLACEMENTS,
    lexicon: Lexicon | None = None,
) -> CorrectionResult:
    """保守地修正转写里的同音专名错字，返回新文本与全部改动记录。"""
    if not text:
        return CorrectionResult(text, [])
    lex = lexicon or get_lexicon()
    if lex is None:
        return CorrectionResult(text, [])

    personal = _personal_pool(personal_terms)
    known = lex.words | {word for word, _ in personal}
    out: list[str] = []
    corrections: list[Correction] = []
    index = 0
    total = len(text)

    while index < total:
        if len(corrections) >= max_replacements:
            out.append(text[index:])
            break

        hit: tuple[int, str, tuple[str, float]] | None = None
        # 从最长片段往回试：优先把「万圣洁」当整词处理，而不是先拆成「万圣」。
        for size in range(min(_MAX_LEN, total - index), _MIN_LEN - 1, -1):
            fragment = text[index : index + size]
            if not _CJK_RE.match(fragment):
                continue
            if fragment in known:
                # 已经是合法词，别再拆成更短的片段去碰运气。
                break
            candidate = _best_candidate(fragment, lex, personal)
            if candidate is not None:
                hit = (size, fragment, candidate)
                break

        if hit is not None:
            size, fragment, (word, score) = hit
            source = (
                "personal" if score >= 9.5 else "custom" if score >= 8.5 else "lexicon"
            )
            out.append(word)
            corrections.append(Correction(fragment, word, source))
            index += size
            LOGGER.info("词典纠错：%s → %s（%s）", fragment, word, source)
        else:
            out.append(text[index])
            index += 1

    return CorrectionResult("".join(out), corrections)


def collect_hints(
    text: str,
    *,
    personal_terms: Iterable[str] = (),
    lexicon: Lexicon | None = None,
    max_hints: int = 8,
    per_fragment: int = 3,
) -> list[dict[str, object]]:
    """给 LLM 的校正提示：可疑片段 + 高置信专名同音/近音候选。

    这是大词库真正发挥作用的地方。注意只报告**高置信专名**，
    不做 fragment → 整本词库的同音映射：实测那样会产出
    「成功 → 程功」「一会 → 易慧」这种噪音，喂给 LLM 反而会诱发误改。
    """
    lex = lexicon or get_lexicon()
    if lex is None or not text:
        return []

    ranked = sorted(
        list(lex._priority.items()) + _personal_pool(personal_terms),
        key=lambda item: item[1],
        reverse=True,
    )
    # 预先算好拼音，避免在内层循环里对每个候选重复调用 pypinyin。
    pool = [(syllables(word), word, len(word)) for word, _ in ranked]
    hints: list[dict[str, object]] = []
    seen: set[str] = set()
    index = 0
    total = len(text)

    while index < total and len(hints) < max_hints:
        consumed = 1
        for size in range(min(_MAX_LEN, total - index), _MIN_LEN - 1, -1):
            fragment = text[index : index + size]
            if not _CJK_RE.match(fragment):
                continue
            if fragment in lex.words:
                break
            key = syllables(fragment)
            # 近音匹配只在 3 字以上开放：2 字词里「一下 / 地下」「第一 / 弟弟」
            # 这类巧合太多，实测全是噪音；「温盛节 → 万圣节」是 3 字，仍保留。
            allowed = 1 if size >= 3 else 0
            matches: list[str] = []
            for word_key, word, word_len in pool:
                if word_len != size or word == fragment:
                    continue
                distance = syllable_distance(key, word_key)
                if distance is not None and distance <= allowed:
                    matches.append(word)
            if matches:
                if fragment not in seen:
                    seen.add(fragment)
                    hints.append(
                        {"fragment": fragment, "candidates": matches[:per_fragment]}
                    )
                consumed = size
                break
        index += consumed
    return hints
