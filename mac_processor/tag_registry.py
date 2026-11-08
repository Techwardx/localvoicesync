"""标签词表：新标签先查已有标签，能归类的尽量归类合并。

问题背景：提炼模型每次只看一条笔记，不知道知识库里已经有哪些标签，于是
「ASL手语 / 手语 AI / 无障碍数据集」「系统测试 / 版本测试 / 测试」
「QCY / QCY T20」这类同义变体会不断增殖。十几条笔记能长出三十个标签，
标签云和按标签浏览就失去意义了。

本模块做两件事：

1. 从所有成员的 ``*/inbox/*.json`` 汇总「现有标签词表」（带出现次数和时间）；
2. 给定模型新提出的标签，用**确定性规则**把它映射到已有标签，
   映射不掉的才允许新建，且每篇笔记最多新建 N 个。

语义判断交给提炼时的 LLM（把词表塞进提示词，让它直接照抄已有标签原文），
这里只做硬保证：即使模型没听话，也不会再冒出一对「QCY / QCY T20」。
所有规则都是纯本地、纯字符串的，不联网、不加载模型、不依赖 Ollama。
"""

from __future__ import annotations

import json
import logging
import threading
import time
import unicodedata
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, Iterator

LOGGER = logging.getLogger("lvs.tags")

_TTL_SECONDS = 45.0
_MAX_TAG_LEN = 24

# 这些词太泛，一旦成为「短标签」就会把无数不相干的标签吞掉
# （"数据" 会吃掉 "无障碍数据集"，"设计" 会吃掉 "无障碍设计"）。
# 它们可以正常作为标签存在，但不参与「包含关系」归并。
GENERIC_TAGS = frozenset(
    {
        "数据", "系统", "信息", "内容", "记录", "笔记", "问题", "设计",
        "优化", "管理", "其他", "技术", "方案", "方法", "状态", "功能",
        "时间", "地点", "人物", "应用", "服务", "工作", "生活", "学习",
        "事项", "准备", "分类", "更新", "情况", "备忘", "内容", "主题",
    }
)


def normalize_tag(text: str) -> str:
    """把标签压成可比较的形式：全角转半角、去空白标点、英文小写。

    "ＱＣＹ Ｔ２０" / "QCY T20" / "qcyt20" 归一后是同一个键。
    中文不受 casefold 影响，汉字全部保留。
    """
    folded = unicodedata.normalize("NFKC", str(text)).strip().casefold()
    return "".join(ch for ch in folded if ch.isalnum())


def _containment_ok(shorter: str) -> bool:
    """包含关系是否可信到足以合并两个标签。"""
    if len(shorter) < 2:
        return False
    # "AI" / "3D" 这种两字符英文缩写到处都是，不能当归并依据。
    if shorter.isascii() and len(shorter) < 3:
        return False
    if shorter in GENERIC_TAGS:
        return False
    return True


def containment_key(a: str, b: str) -> bool:
    """两个规范化标签是否构成「一个是另一个的子串」。

    "测试" ⊂ "系统测试"、"手语" ⊂ "ASL手语"、"qcy" ⊂ "qcyt20" 都算。
    """
    if not a or not b or a == b:
        return False
    shorter, longer = (a, b) if len(a) <= len(b) else (b, a)
    return _containment_ok(shorter) and shorter in longer


def core_label(core: str, candidates: Iterable[str]) -> str:
    """把规范化后的词根还原成原文写法（"qcy" → "QCY"）。

    shared_core() 工作在 lowercase 的规范化串上，直接拿它当标签会写出
    小写的 "qcy"。中文没有大小写问题，但品牌/型号会很难看。
    """
    for tag in candidates:
        folded = unicodedata.normalize("NFKC", str(tag)).strip()
        kept = "".join(ch for ch in folded if ch.isalnum())
        index = kept.lower().find(core)
        if index >= 0:
            return kept[index : index + len(core)]
    return core


def _core_ok(core: str) -> bool:
    """公共片段是否足以证明两个标签讲的是同一个主题。"""
    if len(core) < 2 or core in GENERIC_TAGS:
        return False
    cjk = sum("\u4e00" <= ch <= "\u9fff" for ch in core)
    if cjk >= 2:
        return True
    return bool(core.isascii() and core.isalnum() and len(core) >= 3)


def shared_core(a: str, b: str) -> str | None:
    """两个规范化标签的最长、且非泛化的公共片段。

    「ASL手语」和「手语 AI」没有包含关系，但共享「手语」——这正是同类
    笔记该统一到「手语」的词汇证据。反过来「系统测试」和「系统优化」
    只共享「系统」（太泛），不会被误并。
    """
    if not a or not b or a == b:
        return None
    shorter, longer = (a, b) if len(a) <= len(b) else (b, a)
    for size in range(len(shorter), 1, -1):
        for start in range(len(shorter) - size + 1):
            part = shorter[start : start + size]
            if part in longer and _core_ok(part):
                return part
    return None


@dataclass(frozen=True)
class TagStat:
    tag: str
    count: int
    last_used: str


@dataclass
class TagResolution:
    """一次标签归并的结果。"""

    tags: list[str]
    """最终写进笔记的标签。"""

    mapped: dict[str, str] = field(default_factory=dict)
    """被归到已有标签的写法：{"ASL手语": "手语"}。"""

    created: list[str] = field(default_factory=list)
    """确实是新主题、允许新建的标签。"""

    variants: list[str] = field(default_factory=list)
    """没进 tags 的写法（被合并的 / 超过新建上限的）。

    调用方应把它们补进 aliases：手机上仍能搜到旧词，Whisper 也仍能
    把它们当热词，但标签云不再被重复词撑爆。
    """

    @property
    def changed(self) -> bool:
        return bool(self.mapped or self.variants)


class TagRegistry:
    """带 TTL 的现有标签词表。转写服务是多线程的，所有读写都过锁。"""

    def __init__(
        self,
        sync_root: Path,
        *,
        ttl: float = _TTL_SECONDS,
        max_new_tags: int = 1,
    ) -> None:
        self._root = Path(sync_root)
        self._ttl = ttl
        self._max_new_tags = max(0, int(max_new_tags))
        self._lock = threading.Lock()
        self._stats: list[TagStat] = []
        self._loaded_at = 0.0

    def invalidate(self) -> None:
        """写完一条新笔记后调用，让下一次提炼看到刚落盘的新标签。"""
        with self._lock:
            self._loaded_at = 0.0

    def _scan(self) -> list[TagStat]:
        counts: Counter[str] = Counter()
        last_used: dict[str, str] = {}
        if not self._root.exists():
            return []
        for path in iter_note_paths(self._root):
            data = _read_json(path)
            if data is None:
                continue
            tags = data.get("tags")
            if not isinstance(tags, list):
                continue
            stamp = str(data.get("processed_at") or data.get("created_at") or "")
            for raw in tags:
                tag = str(raw).strip()
                if not tag or len(tag) > _MAX_TAG_LEN:
                    continue
                counts[tag] += 1
                if stamp > last_used.get(tag, ""):
                    last_used[tag] = stamp
        return [TagStat(tag, count, last_used.get(tag, "")) for tag, count in counts.items()]

    def stats(self) -> list[TagStat]:
        now = time.monotonic()
        with self._lock:
            fresh = self._loaded_at > 0 and now - self._loaded_at < self._ttl
            if fresh:
                return list(self._stats)
        scanned = self._scan()
        with self._lock:
            self._stats = scanned
            self._loaded_at = time.monotonic()
        return list(scanned)

    def tags(self, limit: int = 60) -> list[str]:
        """给提示词用的词表：用得多的在前，同样频次时短标签优先。

        短标签更适合当「规范名」——它更容易被包含匹配命中。
        """
        ordered = sorted(
            self.stats(),
            key=lambda s: (s.count, -len(s.tag), s.last_used),
            reverse=True,
        )
        return [s.tag for s in ordered[:limit]]

    def _index(self) -> dict[str, TagStat]:
        best: dict[str, TagStat] = {}
        for stat in self.stats():
            key = normalize_tag(stat.tag)
            if not key:
                continue
            current = best.get(key)
            if current is None or (stat.count, -len(stat.tag)) > (
                current.count,
                -len(current.tag),
            ):
                best[key] = stat
        return best

    def lookup(self, text: str) -> str | None:
        """把一个写法映射到现有标签；返回 None 表示确实是新词。"""
        key = normalize_tag(text)
        if not key:
            return None
        index = self._index()
        exact = index.get(key)
        if exact is not None:
            return exact.tag
        matches = [
            stat
            for norm, stat in index.items()
            if containment_key(key, norm)
        ]
        if not matches:
            return None
        return sorted(matches, key=lambda s: (-s.count, len(s.tag), s.tag))[0].tag

    def resolve(
        self,
        proposed: Iterable[str],
        *,
        max_new: int | None = None,
    ) -> TagResolution:
        """把模型提出的标签收敛成最终标签列表。"""
        known = self.stats()
        cap = self._max_new_tags if max_new is None else max(0, int(max_new))
        # 冷启动：词表还很小的时候放宽，否则第一篇笔记只能有 1 个标签。
        if len(known) < 6:
            cap = max(cap, 3)

        tags: list[str] = []
        mapped: dict[str, str] = {}
        created: list[str] = []
        variants: list[str] = []
        seen: set[str] = set()

        for raw in proposed:
            text = str(raw).strip()
            if not text or len(text) > _MAX_TAG_LEN:
                continue
            key = normalize_tag(text)
            if not key or key in seen:
                continue
            seen.add(key)

            hit = self.lookup(text)
            if hit is not None:
                if hit not in tags:
                    tags.append(hit)
                # 连大小写/空格不同的写法也记一笔，旧写法补进 aliases 后
                # 仍可搜索（"Web3激励" → "Web3 激励"）。
                if hit != text:
                    mapped[text] = hit
                    variants.append(text)
                continue

            if len(created) < cap:
                created.append(text)
                tags.append(text)
            else:
                # 不是"错了"，只是这一篇新词太多：不进标签云，但保留检索。
                variants.append(text)

        return TagResolution(tags[:6], mapped, created, variants)


# ---------------------------------------------------------------- 目录遍历


def iter_note_paths(sync_root: Path) -> Iterator[Path]:
    """所有成员收件箱里的结果 JSON（跳过错误文件和隐藏文件）。"""
    root = Path(sync_root)
    if not root.exists():
        return
    for path in sorted(root.glob("*/inbox/*.json")):
        if path.name.startswith(".") or path.name.endswith(".error.json"):
            continue
        yield path


def _read_json(path: Path) -> dict | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def iter_notes(sync_root: Path) -> Iterator[tuple[Path, dict]]:
    for path in iter_note_paths(sync_root):
        data = _read_json(path)
        if data is not None:
            yield path, data


def tag_counts(sync_root: Path) -> dict[str, int]:
    """现有标签 → 出现次数。整理命令用。"""
    counts: Counter[str] = Counter()
    for _, data in iter_notes(sync_root):
        tags = data.get("tags")
        if isinstance(tags, list):
            for raw in tags:
                tag = str(raw).strip()
                if tag:
                    counts[tag] += 1
    return dict(counts)


def all_tags(sync_root: Path) -> list[str]:
    """现有标签全集（按出现次数降序）。整理命令用。"""
    counts = tag_counts(sync_root)
    return [tag for tag, _ in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))]


def deterministic_edges(tags: Iterable[str]) -> list[tuple[str, str]]:
    """确定性归并边：归一后相同 / 包含关系 / 共享非泛化词根。

    这是标签整理的**主逻辑**，完全不依赖 Ollama。LLM 只用来提建议，
    且建议必须能通过这里的同一套判据才被采纳（见 tag_cleanup.py）。
    """
    items = [str(t).strip() for t in tags if str(t).strip()]
    edges: list[tuple[str, str]] = []
    for i, left in enumerate(items):
        for right in items[i + 1 :]:
            a, b = normalize_tag(left), normalize_tag(right)
            if not a or not b:
                continue
            if a == b or containment_key(a, b) or shared_core(a, b):
                edges.append((left, right))
    return edges


def group_is_plausible(members: Iterable[str]) -> bool:
    """一组标签里的**每一对**是否都有词汇证据支持合并。

    用来挡住 LLM 那种「把停车和导航都叫出行」的跨维度合并：任一对
    既不包含、也不共享词根，整组就丢弃。
    """
    items = [str(t).strip() for t in members if str(t).strip()]
    for i, left in enumerate(items):
        for right in items[i + 1 :]:
            a, b = normalize_tag(left), normalize_tag(right)
            if not (containment_key(a, b) or shared_core(a, b)):
                return False
    return True
