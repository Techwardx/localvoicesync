"""一次性整理已有笔记的标签：把同义/同主题标签收敛成统一写法。

平时靠 `tag_registry.TagRegistry` + 提炼提示词防增量，但已经长出来的
几十个重复标签得单独清一次。命令：

    ./run.sh --normalize-tags            # 只预览，不写文件
    ./run.sh --normalize-tags --apply    # 备份后实际写回

分层设计（LLM 只负责"判断语义"，代码负责"硬保证"）：
- LLM 一次调用给出分组建议；**输出全部校验**，任何一个字段越界就丢弃该组；
- 确定性规则（归一后相同 / 包含关系）再补一遍，Ollama 没起也能用；
- 写回前备份，写回用原子写，且保留 `original_tags` 便于追溯和回退。

被合并掉的旧标签名不会消失：补进 `aliases`。手机端 `searchableText` 包含
aliases，所以按旧词仍然搜得到，Whisper 热词也仍然认得。
"""

from __future__ import annotations

import logging
import shutil
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any, Iterable

from config import Config
from embedder import Embedder
from extractor import OllamaClient
from tag_registry import (
    GENERIC_TAGS,
    all_tags,
    core_label,
    deterministic_edges,
    group_is_plausible,
    iter_notes,
    normalize_tag,
    shared_core,
    tag_counts,
)
from writer import write_result

LOGGER = logging.getLogger("lvs.tagclean")

_MAX_TAGS_PER_NOTE = 6
_MAX_ALIASES = 12
_MAX_CANONICAL_LEN = 8


@dataclass
class CleanupReport:
    before_count: int = 0
    after_count: int = 0
    groups: list[tuple[str, list[str]]] = field(default_factory=list)
    mapping: dict[str, str] = field(default_factory=dict)
    changes: list[dict[str, Any]] = field(default_factory=list)
    backup_dir: Path | None = None
    applied: bool = False
    llm_groups: int = 0

    @property
    def changed_notes(self) -> int:
        return len(self.changes)


class _DisjointSet:
    def __init__(self, items: Iterable[str]) -> None:
        self.parent = {item: item for item in items}

    def find(self, item: str) -> str:
        parent = self.parent.setdefault(item, item)
        while parent != self.parent[parent]:
            self.parent[parent] = self.parent[self.parent[parent]]
            parent = self.parent[parent]
        return parent

    def union(self, a: str, b: str) -> None:
        ra, rb = self.find(a), self.find(b)
        if ra != rb:
            # 用字符串较小的当根，保证同输入下结果稳定
            if ra < rb:
                self.parent[rb] = ra
            else:
                self.parent[ra] = rb


def validate_groups(
    raw_groups: Iterable[Any], allowed: set[str]
) -> list[tuple[str | None, list[str]]]:
    """把 LLM 的分组建议洗成可信数据。**宁可丢组，不可误并。**"""
    result: list[tuple[str | None, list[str]]] = []
    used: set[str] = set()
    for raw in list(raw_groups)[:30]:
        if not isinstance(raw, dict):
            continue
        canonical = str(raw.get("canonical") or "").strip()
        members_raw = raw.get("members")
        if not isinstance(members_raw, list):
            continue

        members: list[str] = []
        for item in members_raw[:10]:
            tag = str(item).strip()
            # 幻觉出来的标签、跨组重复出现的标签，一律不认
            if tag not in allowed or tag in used or tag in members:
                continue
            members.append(tag)
        if len(members) < 2:
            continue
        # 跨维度合并（"停车 + 导航 → 出行"）在这里被整组丢弃：
        # 组内任一对既不包含、也不共享词根，就不认。
        if not group_is_plausible(members):
            continue
        used.update(members)

        # 规范名：允许是组里已有的词，也允许是某个成员里真实出现的片段
        # （"ASL手语" → "手语"）。凭空生造的"数据工程""系统管理"一律不认。
        clean = (
            canonical
            if _valid_canonical(canonical) and _canonical_allowed(canonical, members)
            else None
        )
        result.append((clean, members))
    return result


def _canonical_allowed(canonical: str, members: list[str]) -> bool:
    key = normalize_tag(canonical)
    return any(
        key == normalize_tag(member) or key in normalize_tag(member)
        for member in members
    )


def _valid_canonical(text: str) -> bool:
    if not 2 <= len(text) <= _MAX_CANONICAL_LEN:
        return False
    key = normalize_tag(text)
    if not key or key in GENERIC_TAGS:
        return False
    # 至少得有个汉字或字母，挡住 "---" 这类垃圾
    return any(ch.isalnum() for ch in text)


def build_merge_map(
    tags: list[str],
    counts: dict[str, int],
    groups: list[tuple[str | None, list[str]]],
    *,
    use_deterministic: bool = True,
) -> tuple[dict[str, str], list[tuple[str, list[str]]]]:
    """把 LLM 分组 + 确定性边合成并查集，产出 ``旧标签 → 规范标签``。"""
    dsu = _DisjointSet(tags)
    hints: list[tuple[list[str], str | None]] = []

    for canonical, members in groups:
        for member in members[1:]:
            dsu.union(members[0], member)
        hints.append((members, canonical))

    core_candidates: dict[str, list[str]] = {}
    if use_deterministic:
        edges = deterministic_edges(tags)
        for left, right in edges:
            dsu.union(left, right)
        # 共享词根本身就是最自然的规范名（"ASL手语 / 手语 AI" → "手语"）。
        for left, right in edges:
            core = shared_core(normalize_tag(left), normalize_tag(right))
            if core:
                core_candidates.setdefault(dsu.find(left), []).append(core)

    components: dict[str, list[str]] = {}
    for tag in tags:
        components.setdefault(dsu.find(tag), []).append(tag)

    def best_existing(members: list[str]) -> str:
        return sorted(
            members, key=lambda t: (-counts.get(t, 1), len(t), t)
        )[0]

    mapping: dict[str, str] = {}
    report: list[tuple[str, list[str]]] = []
    used_canonicals: set[str] = set()

    for root, members in sorted(components.items()):
        if len(members) < 2:
            continue
        hint = next(
            (
                canonical
                for hint_members, canonical in hints
                if canonical and dsu.find(hint_members[0]) == root
            ),
            None,
        )
        cores = core_candidates.get(root, [])
        established = [tag for tag in members if counts.get(tag, 1) >= 2]
        # 已经被反复使用的老名字最稳（"系统测试" 比 LLM 简化出来的 "测试"
        # 更贴合这个项目）；其次才用 LLM 的语义命名；都没有就用共享词根
        # 造一个短名字（"ASL手语 / 手语 AI" → "手语"）。
        if established:
            chosen = best_existing(members)
        elif hint:
            chosen = hint
        elif cores:
            best_core = sorted(cores, key=lambda c: (-cores.count(c), len(c), c))[0]
            chosen = core_label(best_core, members)
        else:
            chosen = best_existing(members)
        # 两个不同分组撞同一个规范名会意外把两个主题粘起来，退回本组已有词。
        if normalize_tag(chosen) in used_canonicals:
            chosen = best_existing(members)
        used_canonicals.add(normalize_tag(chosen))
        for tag in members:
            mapping[tag] = chosen
        report.append((chosen, sorted(members)))

    return mapping, report


def _retag(data: dict[str, Any], mapping: dict[str, str]) -> tuple[list[str], list[str]] | None:
    old = [str(t).strip() for t in (data.get("tags") or []) if str(t).strip()]
    new: list[str] = []
    for tag in old:
        canonical = mapping.get(tag, tag)
        if canonical not in new:
            new.append(canonical)
    new = new[:_MAX_TAGS_PER_NOTE]
    if new == old:
        return None
    variants = [tag for tag in old if tag not in new]
    return new, variants


def _refresh_vector(data: dict[str, Any], embedder: Embedder) -> None:
    """标签是向量输入的一部分，改了标签就顺手重算，避免语义检索有偏差。"""
    if not data.get("embedding"):
        return
    text = " ".join(
        [
            str(data.get("summary") or ""),
            " ".join(str(p) for p in (data.get("knowledge_points") or [])),
            " ".join(str(t) for t in (data.get("tags") or [])),
            str(data.get("raw_transcript") or ""),
        ]
    ).strip()
    vector = embedder.embed(text)
    if vector:
        data["embedding"] = vector
        data["embedding_model"] = embedder.model_id
        data["embedding_dim"] = len(vector)


def _backup(sync_root: Path, paths: list[Path], backup_root: Path | None = None) -> Path:
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    base = backup_root or (Path.home() / ".localvoicesync" / "tag-backups")
    dest = base / stamp
    dest.mkdir(parents=True, exist_ok=True)
    for path in paths:
        rel = path.relative_to(sync_root)
        target = dest / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
        markdown = path.with_suffix(".md")
        if markdown.exists():
            shutil.copy2(markdown, target.with_suffix(".md"))
    return dest


def normalize_existing_notes(
    cfg: Config,
    ollama: OllamaClient,
    *,
    apply: bool = False,
    use_llm: bool = True,
    embedder: Embedder | None = None,
    backup_root: Path | None = None,
) -> CleanupReport:
    root = cfg.sync_root
    tags = all_tags(root)
    counts = tag_counts(root)
    report = CleanupReport(before_count=len(tags), after_count=len(tags))

    raw_groups = ollama.plan_tag_merge(tags, counts) if use_llm else []
    groups = validate_groups(raw_groups, set(tags))
    report.llm_groups = len(groups)
    report.mapping, report.groups = build_merge_map(tags, counts, groups)

    if report.mapping:
        report.after_count = len(
            {report.mapping.get(tag, tag) for tag in tags}
        )

    touched: list[tuple[Path, dict[str, Any]]] = []
    for path, data in iter_notes(root):
        retagged = _retag(data, report.mapping)
        if retagged is None:
            continue
        new_tags, variants = retagged
        old = [str(t).strip() for t in (data.get("tags") or []) if str(t).strip()]
        aliases = [str(a).strip() for a in (data.get("aliases") or []) if str(a).strip()]
        for variant in variants:
            if variant not in aliases and len(aliases) < _MAX_ALIASES:
                aliases.append(variant)

        data.setdefault("original_tags", list(old))
        data["tags"] = new_tags
        data["aliases"] = aliases
        data["processed_at"] = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        report.changes.append(
            {"file": path.name, "before": old, "after": new_tags, "aliases_added": variants}
        )
        touched.append((path, data))

    if not apply or not touched:
        return report

    report.backup_dir = _backup(root, [path for path, _ in touched], backup_root)
    if embedder is None:
        embedder = Embedder(cfg)
    for path, data in touched:
        try:
            _refresh_vector(data, embedder)
        except Exception as error:  # noqa: BLE001 - 向量只是锦上添花
            LOGGER.warning("重算向量失败（保留原值）：%s", error)
        write_result(path.parent, str(data.get("id") or path.stem), data)
    report.applied = True
    LOGGER.info("标签整理写回 %d 篇笔记，备份在 %s", len(touched), report.backup_dir)
    return report


def print_report(report: CleanupReport) -> None:
    print("=" * 62)
    print("标签整理" + ("（已写回）" if report.applied else "（预览，未写文件）"))
    print("=" * 62)
    print(f"现有 {report.before_count} 个标签 → 归并后 {report.after_count} 个")
    print(f"分组来源：LLM {report.llm_groups} 组 + 确定性规则兜底")
    print("-" * 62)
    if not report.groups:
        print("没有需要合并的标签。")
    for canonical, members in report.groups:
        print(f"  {canonical}  ←  {'、'.join(members)}")
    print("-" * 62)
    print(f"将改动 {report.changed_notes} 篇笔记：")
    for change in report.changes:
        print(f"  {change['file']}")
        print(f"    {'、'.join(change['before'])}")
        print(f"  → {'、'.join(change['after'])}")
        if change["aliases_added"]:
            print(f"    补进 aliases：{'、'.join(change['aliases_added'])}")
    if report.backup_dir:
        print("-" * 62)
        print(f"备份目录：{report.backup_dir}")
    if not report.applied and report.changes:
        print("-" * 62)
        print("确认无误后加 --apply 实际写回。")
