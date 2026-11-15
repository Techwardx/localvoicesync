"""文本笔记的「编辑旁车」：手机端改过的标签，以及重提炼用的组合哈希。

## 为什么需要这个文件

文本笔记的正文就是 ``<成员>_Notes/outbox/<id>.txt``，Mac 直接读它当转写。
用户在手机上改正文 → 覆盖同名 txt → sha256 变了 → 自动重跑，这条路是通的。

但**只改标签不改正文**时，txt 一个字节都没变，`state.already_done()` 会认为
"处理过了"直接跳过，用户改的标签永远到不了 Mac。

所以手机端改标签时会额外写一份旁车 ``<id>.meta.json``::

    {
      "id": "memo_20261031_123000",
      "tags": ["手语", "无障碍"],
      "tags_edited": true,
      "edited_at": "2026-11-15 15:30:00"
    }

Mac 端做两件事：

1. 去重哈希改成 ``sha256(txt) + sha256(meta)`` 的组合哈希——旁车一变就重跑；
2. 提炼时若 ``tags_edited`` 为真，**标签以用户写的为准**，AI 只负责摘要、
   知识点和待办。

## 为什么不用「把标签写进 txt 首行」

那会污染正文：用户在 Mac 上打开文件会看到一行元数据，而且 ``raw_transcript``
也得跟着做剥离，任何一处漏掉都会把标签当成正文喂给模型。旁车是独立文件，
坏了最多是标签退回 AI 版本，正文永远干净。

## 为什么旁车不会被重复处理

``build_job()`` 只认音频/文本后缀，``.json`` 直接返回 None。旁车本身不是任务，
真正要重跑的是同名正文——所以监听与积压扫描都要把它映射回 ``.txt``。
"""

from __future__ import annotations

import hashlib
import json
import logging
from dataclasses import dataclass, field
from pathlib import Path

from state import sha256_of

LOGGER = logging.getLogger("lvs.meta")

META_SUFFIX = ".meta.json"

# 手机上最多保留几个用户标签。和 Dart 端 AppConfig.maxUserTags 保持一致。
MAX_USER_TAGS = 8
MAX_TAG_LEN = 24


@dataclass(frozen=True)
class NoteMeta:
    """一份旁车的内容。"""

    tags: list[str] = field(default_factory=list)
    tags_edited: bool = False
    edited_at: str = ""


def meta_path(note_path: Path) -> Path:
    """``memo_x.txt`` → ``memo_x.meta.json``。

    不用 ``with_suffix()``：它把 ``.txt`` 换成 ``.meta.json`` 的行为在不同
    Python 版本上不够直观，直接拼名字最稳。
    """
    note_path = Path(note_path)
    return note_path.with_name(f"{note_path.stem}{META_SUFFIX}")


def note_path_for_meta(meta_file: Path) -> Path | None:
    """旁车 → 它对应的正文。文件不存在时返回 None（等正文同步到位再说）。"""
    meta_file = Path(meta_file)
    name = meta_file.name
    if not name.endswith(META_SUFFIX):
        return None
    stem = name[: -len(META_SUFFIX)]
    for suffix in (".txt", ".md"):
        candidate = meta_file.with_name(f"{stem}{suffix}")
        if candidate.exists():
            return candidate
    return None


def _clean_tags(raw: object) -> list[str]:
    """防御式解析：数组、逗号分隔字符串、混杂类型都收，脏值直接丢。"""
    items: list[object]
    if isinstance(raw, list):
        items = raw
    elif isinstance(raw, str):
        items = raw.replace("，", ",").replace("、", ",").split(",")
    else:
        return []

    tags: list[str] = []
    seen: set[str] = set()
    for item in items:
        text = str(item).strip()
        if not text or len(text) > MAX_TAG_LEN:
            continue
        key = text.casefold()
        if key in seen:
            continue
        seen.add(key)
        tags.append(text)
        if len(tags) >= MAX_USER_TAGS:
            break
    return tags


def read_meta(note_path: Path) -> NoteMeta | None:
    """读旁车。没有 / 坏了 / 不是对象，一律返回 None（退回 AI 标签）。"""
    path = meta_path(note_path)
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(raw, dict):
        return None

    tags = _clean_tags(raw.get("tags"))
    flag = raw.get("tags_edited")
    if flag is None:
        # 老格式没有这个字段：有标签就说明是用户写的。
        tags_edited = bool(tags)
    else:
        tags_edited = bool(flag)
    return NoteMeta(
        tags=tags,
        tags_edited=tags_edited,
        edited_at=str(raw.get("edited_at") or ""),
    )


def digest_for(note_path: Path) -> str:
    """正文 + 旁车的组合哈希，用来做处理去重。

    ⚠️ 没有旁车时必须**原样返回正文的 sha256**。否则升级后所有历史音频的
    哈希都变了，启动时的积压扫描会把整个 outbox 重跑一遍（几十条 Whisper +
    LLM，还会覆盖用户改过的笔记）。
    """
    base = sha256_of(note_path)
    meta = meta_path(note_path)
    if not meta.exists():
        return base
    try:
        meta_digest = sha256_of(meta)
    except OSError:
        return base
    return hashlib.sha256(f"{base}|{meta_digest}".encode("ascii")).hexdigest()
