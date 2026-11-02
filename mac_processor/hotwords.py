"""从历史回传结果里提炼「家庭词汇表」，作为 Whisper 的提示词。

为什么需要它
------------
Whisper 的 `initial_prompt` 是**条件解码的上下文**，不是"给模型的指令"。
同一条 48 秒真实录音（large-v3-turbo / int8 / beam_size=5）实测：

| 提示词 | 转写字数 | 「万圣节」 |
| --- | --- | --- |
| 无 | 85 | 温盛节 ✗ |
| 指令式「以下是普通话的句子，请用简体中文转写，并加上标点符号。」 | **23** | 整段丢掉 |
| 词表式「家庭语音备忘。常提到：万圣节、要糖、…」 | 119 | 万圣节 ✓ |

两个结论，都反直觉：

1. **提示词必须写成「转写结果」的样子。** 写成指令会让模型把指令本身当成
   音频内容去"转写"，结果是丢掉 80% 的内容（85 字 → 23 字）。
2. **词表能纠正专有名词，且不会把词注入到内容里。** 给一份完全无关的词表
   （股票、基金、区块链、并购…）去转写同一条录音，122 个字里一个词都没串进来。
   所以这条路是安全的，不是"靠提示词硬塞答案"。

词从哪来
--------
回传 JSON 里的 `tags` 和 `aliases`。这两个字段本来就是 LLM 对这个家庭语料
的归纳（"QCY T20"、"保险丝"、"要糖"），正是 Whisper 该认识却容易听错的词。
不额外增加用户配置负担，也不需要用户维护词表。

用户仍然可以覆盖：`LVS_WHISPER_HOTWORDS=甲,乙,丙` 手动指定，
或设成 `off` 关掉自动收集。
"""

from __future__ import annotations

import json
import threading
import time
from collections import Counter
from pathlib import Path

# 这些 tag 是流程产物，不是"词汇"，塞进提示词只会浪费 token。
_STOPLIST = frozenset(
    {
        "语音备忘",
        "待确认",
        "待办",
        "测试",
        "记录",
        "其他",
        "无",
        "未知",
        "未分类",
    }
)

# 单个词的合理长度。太短（"糖"）没有纠错价值，太长（整句）会挤占提示词预算。
_MIN_TERM = 2
_MAX_TERM = 12

# 提示词总预算。Whisper 的上限是 224 token，中文大致 1 字 ≈ 1 token，
# 留足余量给格式前缀和标点。
_MAX_PROMPT_CHARS = 180

# 最多回看多少个回传文件。按 mtime 倒序，只看最近的。
_SCAN_LIMIT = 200

# 词汇表的有效期。十分钟足够覆盖一轮批量处理，又不会让新词等太久。
_TTL_SECONDS = 600.0


def _usable(term: str) -> bool:
    """判断一个 tag / alias 值不值得进提示词。"""
    if not (_MIN_TERM <= len(term) <= _MAX_TERM):
        return False
    if term in _STOPLIST:
        return False
    if term.isdigit():
        return False
    # 换行、制表符会把提示词的排版搞乱，直接排除。
    if any(ch in term for ch in "\r\n\t"):
        return False
    return True


def _drop_redundant(terms: list[str]) -> list[str]:
    """去掉互相包含的近重复词。

    历史 tags 里常见「左耳不亮」和「左耳不亮灯」这种，两个都塞进去只是
    白占提示词预算（Whisper 上限 224 token），并不会提高纠错率。
    输入按频次降序，所以保留的是更常用、更短的那个。
    """
    kept: list[str] = []
    for term in terms:
        if any(term in existing or existing in term for existing in kept):
            continue
        kept.append(term)
    return kept


def collect(sync_root: Path, *, max_terms: int = 24) -> list[str]:
    """扫描 `*/inbox/*.json`，按出现频次返回家庭词汇。

    任何异常都吞掉并返回空列表：提示词是锦上添花，绝不能因为它让转写失败。
    """
    counter: Counter[str] = Counter()
    try:
        files = sorted(
            sync_root.glob("*/inbox/*.json"),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )[:_SCAN_LIMIT]
    except OSError:
        return []

    for path in files:
        try:
            data = json.loads(path.read_text(encoding="utf-8", errors="replace"))
        except (OSError, ValueError):
            continue
        if not isinstance(data, dict):
            continue
        for key in ("tags", "aliases"):
            values = data.get(key)
            if not isinstance(values, list):
                continue
            for raw in values:
                term = str(raw).strip()
                if _usable(term):
                    counter[term] += 1

    ranked = [term for term, _ in counter.most_common()]
    return _drop_redundant(ranked)[:max_terms]


def build_prompt(base: str, hotwords: list[str]) -> str:
    """拼出最终提示词。

    刻意**不加**任何内容词做铺垫：实测加一句"今天带孩子出去转了一圈，
    停车排了好一会儿队"这种主题相近的话，会把音频里的"听到"带偏成"停到"。
    只有格式前缀 + 词表，模型才不会替我们编内容。
    """
    base = base.strip()
    terms: list[str] = []
    used = len(base) + len("常提到：。")
    for term in hotwords:
        if used + len(term) + 1 > _MAX_PROMPT_CHARS:
            break
        terms.append(term)
        used += len(term) + 1
    if not terms:
        return base
    return f"{base}常提到：{'、'.join(terms)}。"


class HotwordCache:
    """带 TTL 的词汇表缓存。

    转写是逐文件串行跑的，每次都去扫 200 个 JSON 纯属浪费；
    但也不能启动时算一次就永远不变——新词要能进来。
    """

    def __init__(self, sync_root: Path, *, ttl: float = _TTL_SECONDS) -> None:
        self._root = sync_root
        self._ttl = ttl
        self._lock = threading.Lock()
        self._loaded_at = 0.0
        self._terms: list[str] = []

    def get(self) -> list[str]:
        now = time.monotonic()
        with self._lock:
            if self._terms and now - self._loaded_at < self._ttl:
                return self._terms
        terms = collect(self._root)
        with self._lock:
            self._terms = terms
            self._loaded_at = now
        return terms
