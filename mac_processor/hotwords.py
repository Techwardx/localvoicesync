"""从历史回传结果里自动提炼「家庭词汇表」，作为 Whisper 的提示词。

为什么需要它
------------
Whisper 的 `initial_prompt` 是**条件解码的上下文**，不是"给模型的指令"。
同一条 48 秒真实录音（large-v3-turbo / int8 / beam_size=5）实测：

| 提示词 | 转写字数 | 「万圣节」 |
| --- | --- | --- |
| 无 | 85 | 温盛节 ✗ |
| 指令式「以下是普通话的句子，请用简体中文转写…」 | **23** | 整段丢掉 |
| 词表式「家庭语音备忘。常提到：万圣节、要糖、…」 | 119 | 万圣节 ✓ |

两个结论，都反直觉：

1. **提示词必须写成「转写结果」的样子。** 写成指令会让模型把指令本身当成
   音频内容去"转写"，结果是丢掉 80% 的内容（85 字 → 23 字）。
2. **词表能纠正专有名词，且不会把词注入到内容里。** 给一份完全无关的词表
   （股票、基金、区块链、并购…）去转写同一条录音，122 个字里一个词都没串进来。

预算是硬的
----------
faster-whisper 的 `get_prompt()` 只保留 initial_prompt 的**最后 223 个 token**
（`previous_tokens[-(448 // 2 - 1):]`）。中文 3 字词约 4~5 token，也就是说
整个提示词最多装 40~50 个词，超出的部分会被**静默丢掉前面的词**。
所以这里按真实 Whisper tokenizer 计数，并主动留到 180 token，
绝不靠"字符数 ≈ token 数"这种错误假设。

v0.2 改了什么
-------------
旧版扫**全家** `*/inbox/*.json` 的 tags 按频次取 Top24，结果 Me 的停车场
录音里被塞进了别人（甚至自己粘贴的长文笔记里）的「手语 AI / Web3 激励 /
聋哑人数据采集」，提示词 202/223 token 几乎撑满，「万圣节」反而进不去。
现在改成：

- **按成员隔离**：只扫 `<author>_Notes/inbox`，别人的词汇不串场；
- **音频笔记加权**：kind=audio 的权重 ×3，粘贴的长文本笔记不再主导；
- **时间衰减**：30 天半衰，最近的词优先；
- **从转写正文挖专名**：用 jieba 词性标注抓 nr/ns/nz/nt（人名、地名、
  其他专名），比 LLM 给的抽象分类标签（"系统测试""社区服务"）靠谱得多；
- **手写 + 自动合并**：旧版 `manual or auto` 是二选一，手写了就丢掉全部自动词；
- **上限 12 个词**，把 token 预算留给真正可能用到的专名。
"""

from __future__ import annotations

import json
import threading
import time
from collections import defaultdict
from pathlib import Path
from typing import Callable, Iterable

# 这些是流程产物 / 抽象主题标签，不是"词汇"，塞进提示词只会浪费 token。
_STOPLIST = frozenset(
    {
        "语音备忘", "语音记录", "待确认", "待办", "待办事项", "测试", "记录",
        "其他", "无", "未知", "未分类", "系统测试", "版本测试", "软件更新",
        "数据库优化", "家庭出行", "出行准备", "硬件维修", "问题", "方案",
        "总结", "内容", "信息", "情况", "建议", "注意", "备注", "日常",
    }
)

_MIN_TERM = 2
_MAX_TERM = 12
# Whisper 硬上限 223 token；留 43 token 余量给时间戳 / 特殊 token 和估算误差。
_MAX_PROMPT_TOKENS = 180
_SCAN_LIMIT = 200
_TTL_SECONDS = 600.0
_HALF_LIFE_DAYS = 30.0
_DEFAULT_MAX_TERMS = 12
_PROPER_NOUN_FLAGS = frozenset({"nr", "nrt", "ns", "nz", "nt", "nw"})
_CUSTOM_FILE = Path(__file__).resolve().parent / "lexicon" / "custom.txt"
_custom_cache: tuple[float, frozenset[str]] | None = None
_custom_lock = threading.Lock()


def _custom_terms() -> frozenset[str]:
    """项目自建的日常专名表（lexicon/custom.txt），一分钟缓存。"""
    global _custom_cache
    now = time.monotonic()
    cached = _custom_cache
    if cached and now - cached[0] < 60.0:
        return cached[1]
    terms: set[str] = set()
    try:
        for line in _CUSTOM_FILE.read_text(encoding="utf-8").splitlines():
            word = line.strip()
            if word and not word.startswith("#"):
                terms.add(word)
    except OSError:
        pass
    frozen = frozenset(terms)
    with _custom_lock:
        _custom_cache = (now, frozen)
    return frozen


def _worth_taking_from_text_note(term: str, custom: frozenset[str]) -> bool:
    """文字笔记的标签要不要收进提示词。

    粘贴的长文笔记（"手语 AI / 数据众包 / 多模态大模型训练数据"）反映的是
    文章主题，不是这家人会说的话，收进来只会挤掉真正有用的词。
    只保留两类：日常专名表里的词，以及**纯英文/数字**的名字
    （QCY T20、AilyPods、Sam 这种品牌和英文名）。
    中英混排的「手语 AI」「3D打印」一律不要——它们几乎都是文章主题词。
    """
    if term in custom:
        return True
    return all(ch.isascii() for ch in term) and any(ch.isalnum() for ch in term)


def _usable(term: str) -> bool:
    """判断一个 tag / alias / 专名值不值得进提示词。"""
    if not (_MIN_TERM <= len(term) <= _MAX_TERM):
        return False
    if term in _STOPLIST:
        return False
    if term.isdigit():
        return False
    if any(ch in term for ch in "\r\n\t"):
        return False
    return True


def _drop_redundant(terms: Iterable[str]) -> list[str]:
    """去掉互相包含的近重复词。

    历史 tags 里常见「左耳不亮」和「左耳不亮灯」这种，两个都塞进去只是
    白占提示词预算（Whisper 上限 223 token），并不会提高纠错率。
    输入按权重降序，所以保留的是更常用、更短的那个。
    """
    kept: list[str] = []
    for term in terms:
        if any(term in existing or existing in term for existing in kept):
            continue
        kept.append(term)
    return kept


def merge_terms(manual: Iterable[str], auto: Iterable[str]) -> list[str]:
    """手写词优先，其后接自动词；去重并去掉互相包含的词。"""
    ordered: list[str] = []
    seen: set[str] = set()
    for raw in list(manual) + list(auto):
        term = str(raw).strip()
        if not _usable(term) or term in seen:
            continue
        seen.add(term)
        ordered.append(term)
    return _drop_redundant(ordered)


def _fallback_token_cost(text: str) -> float:
    """没有 Whisper tokenizer 时的保守估算（宁可高估，少放几个词）。

    实测 tokenizer：3 字中文词 4~5 token、4 字词 7 token、ASCII 约 0.7/字符。
    """
    total = 0.0
    for char in text:
        if "\u4e00" <= char <= "\u9fff":
            total += 1.8
        elif char.isspace():
            total += 0.4
        else:
            total += 0.9
    return total


def make_token_cost(cache_dir: Path) -> Callable[[str], int] | None:
    """尝试加载缓存里的 Whisper tokenizer，返回精确 token 计数函数。

    faster-whisper 依赖 `tokenizers`，模型下载后 tokenizer.json 就在缓存里。
    找不到（比如只跑文字流水线、模型还没下）就返回 None，由调用方退回估算。
    """
    try:
        from tokenizers import Tokenizer
    except ImportError:
        return None

    whisper_root = Path(cache_dir).expanduser() / "whisper"
    if not whisper_root.exists():
        return None
    for path in sorted(whisper_root.rglob("tokenizer.json")):
        try:
            tokenizer = Tokenizer.from_file(str(path))
        except Exception:  # noqa: BLE001 - 某个损坏的缓存不该拖垮启动
            continue
        return lambda text: len(tokenizer.encode(text, add_special_tokens=False).ids)
    return None


def build_prompt(
    base: str,
    hotwords: Iterable[str],
    *,
    token_cost: Callable[[str], float] | None = None,
    max_tokens: float = _MAX_PROMPT_TOKENS,
) -> str:
    """拼出最终提示词，按 token 预算贪心装词。

    刻意**不加**任何内容词做铺垫：实测加一句"今天带孩子出去转了一圈，
    停车排了好一会儿队"这种主题相近的话，会把音频里的"听到"带偏成"停到"。
    只有格式前缀 + 词表，模型才不会替我们编内容。
    """
    cost = token_cost or _fallback_token_cost
    base = base.strip()
    terms: list[str] = []
    for term in hotwords:
        candidate_terms = terms + [term]
        candidate = f"{base}常提到：{'、'.join(candidate_terms)}。"
        if cost(candidate) > max_tokens:
            break
        terms.append(term)
    if not terms:
        return base
    return f"{base}常提到：{'、'.join(terms)}。"


# ---------------------------------------------------------------- 收集


def _member_inbox_files(sync_root: Path, author: str | None) -> list[Path]:
    try:
        dirs = [p for p in sync_root.iterdir() if p.is_dir()]
    except OSError:
        return []
    if author:
        wanted = {author, f"{author}_Notes"}
        dirs = [p for p in dirs if p.name in wanted]
    files: list[Path] = []
    for member_dir in dirs:
        try:
            files.extend(member_dir.glob("inbox/*.json"))
        except OSError:
            continue
    return files


def _proper_nouns(transcript: str) -> list[str]:
    """从转写正文里挖人名 / 地名 / 其他专名（懒加载 jieba）。

    只收 3 字以上或含英文/数字的词：jieba 会把「高清」「关怀」这类
    两字常用词也标成 nz，收进来只会白占提示词预算。
    """
    if not transcript:
        return []
    try:
        import jieba.posseg as posseg
    except ImportError:
        return []
    found: list[str] = []
    try:
        for word, flag in posseg.cut(transcript[:600]):
            if flag not in _PROPER_NOUN_FLAGS or not _usable(word):
                continue
            if len(word) >= 3 or any(ch.isascii() and not ch.isspace() for ch in word):
                found.append(word)
    except Exception:  # noqa: BLE001 - 分词是锦上添花，不能拖垮转写
        return []
    return found


def collect(
    sync_root: Path,
    *,
    author: str | None = None,
    max_terms: int = _DEFAULT_MAX_TERMS,
    now: float | None = None,
) -> list[str]:
    """扫描成员 inbox，按「音频加权 × 时间衰减」返回家庭专名。

    任何异常都吞掉并返回空列表：提示词是锦上添花，绝不能因为它让转写失败。
    """
    now = time.time() if now is None else now
    weights: dict[str, float] = defaultdict(float)
    try:
        files = sorted(
            _member_inbox_files(sync_root, author),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )[:_SCAN_LIMIT]
    except OSError:
        return []

    for path in files:
        try:
            data = json.loads(path.read_text(encoding="utf-8", errors="replace"))
            age_days = max(0.0, (now - path.stat().st_mtime) / 86400.0)
        except (OSError, ValueError):
            continue
        if not isinstance(data, dict):
            continue

        decay = 0.5 ** (min(age_days, 180.0) / _HALF_LIFE_DAYS)
        spoken = data.get("kind") == "audio"
        weight = decay * (3.0 if spoken else 1.0)
        custom = _custom_terms()

        for key in ("tags", "aliases"):
            values = data.get(key)
            if not isinstance(values, list):
                continue
            for raw in values:
                term = str(raw).strip()
                if not _usable(term):
                    continue
                if not spoken and not _worth_taking_from_text_note(term, custom):
                    continue
                weights[term] += weight

        # 正文里真正被说出口的专名，比抽象分类标签更值钱。
        # 只从**音频**转写里挖：文字笔记常常是整段粘贴的文章，
        # 里面的「高中生」「多模态大模型」不是这家人会说的话。
        if spoken:
            for term in _proper_nouns(str(data.get("raw_transcript") or "")):
                weights[term] += weight * 2.0

    ranked_pairs = sorted(weights.items(), key=lambda item: (-item[1], item[0]))
    if ranked_pairs:
        # 相对门槛：一次性出现的抽象标签权重会被头部词甩开，直接丢掉，
        # 别拿 12 个名额去装「Web3 激励」这种一年只用一次的词。
        floor = ranked_pairs[0][1] * 0.25
        ranked_pairs = [item for item in ranked_pairs if item[1] >= floor]
    ranked = [term for term, _ in ranked_pairs]
    return _drop_redundant(ranked)[:max_terms]


class HotwordCache:
    """按成员分别缓存、带 TTL 的词汇表。

    转写是逐文件串行跑的，每次都去扫 200 个 JSON 纯属浪费；
    但也不能启动时算一次就永远不变——新词要能进来。

    缓存里存的是**完整排序**，提示词取前 12 个，纠错层要前 200 个，
    两边共用一次扫描，不用为不同上限重复读盘。
    """

    def __init__(
        self,
        sync_root: Path,
        *,
        ttl: float = _TTL_SECONDS,
        max_terms: int = _DEFAULT_MAX_TERMS,
    ) -> None:
        self._root = sync_root
        self._ttl = ttl
        self._max_terms = max_terms
        self._lock = threading.Lock()
        self._cache: dict[str, tuple[float, list[str]]] = {}

    def get(self, author: str | None = None, *, max_terms: int | None = None) -> list[str]:
        key = author or "*"
        limit = max_terms or self._max_terms
        now = time.monotonic()
        with self._lock:
            cached = self._cache.get(key)
            if cached and now - cached[0] < self._ttl:
                return cached[1][:limit]
        terms = collect(self._root, author=author, max_terms=_SCAN_LIMIT)
        with self._lock:
            self._cache[key] = (now, terms)
        return terms[:limit]
