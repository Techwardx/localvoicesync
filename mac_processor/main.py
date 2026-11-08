#!/usr/bin/env python3
"""LocalVoiceSync —— Mac Mini M4 后台处理流水线。

职责：监听 Syncthing 同步目录里的 `*/outbox/`，把手机上传的音频/文本
加工成结构化笔记，写回 `*/inbox/`，由 Syncthing 自动反向同步回手机。

三步流水线：
    1. faster-whisper（large-v3-turbo，int8）转写
    2. 本地 Ollama（qwen3.5:9b-q4_K_M）提炼摘要 / 知识点 / TODO / 标签 / 别名
    3. bge-small-zh-v1.5 向量化

用法：
    python main.py                      # 常驻监听
    python main.py --check              # 只做环境自检
    python main.py --once               # 处理完积压就退出（适合 cron）
    python main.py --file a.m4a         # 处理单个文件（调试用）
    python main.py --todos              # 汇总所有笔记待办 + 手机同步过来的勾选状态
"""

from __future__ import annotations

import argparse
import logging
import re
import signal
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, replace
from datetime import datetime
from pathlib import Path

import corrector
from config import Config
from embedder import Embedder
from extractor import ExtractionError, OllamaClient
from state import StateStore, sha256_of
from tag_cleanup import normalize_existing_notes, print_report
from tag_registry import TagRegistry
from todo_state import format_report, state_stats
from transcriber import WhisperPool
from writer import write_error, write_result
try:
    from watchdog.events import FileSystemEvent, FileSystemEventHandler
    from watchdog.observers import Observer
except ImportError:  # pragma: no cover
    Observer = None  # type: ignore[assignment]
    FileSystemEventHandler = object  # type: ignore[misc,assignment]
    FileSystemEvent = object  # type: ignore[misc,assignment]

LOGGER = logging.getLogger("lvs")

AUDIO_SUFFIXES = {".m4a", ".mp3", ".wav", ".aac", ".caf", ".flac", ".ogg", ".opus"}
TEXT_SUFFIXES = {".txt", ".md"}
SCHEMA_VERSION = 1

_MEMO_ID_RE = re.compile(r"memo_(\d{8})_(\d{6})")


# ---------------------------------------------------------------- 任务解析


@dataclass(frozen=True)
class Job:
    path: Path
    inbox_dir: Path
    author: str
    kind: str
    memo_id: str
    created_at: str


def build_job(path: Path) -> Job | None:
    """从文件路径推断成员、收件箱位置、作者与时间。"""
    parts = path.parts
    if "outbox" not in parts:
        return None
    index = parts.index("outbox")
    if index == 0:
        return None
    member_dir = Path(*parts[:index])
    inbox_dir = member_dir / "inbox"

    name = path.name
    if name.startswith(".") or name.endswith(".part"):
        return None

    suffix = path.suffix.lower()
    if suffix in AUDIO_SUFFIXES:
        kind = "audio"
    elif suffix in TEXT_SUFFIXES:
        kind = "text"
    else:
        return None

    memo_id = path.stem
    if not memo_id.startswith("memo_"):
        memo_id = f"memo_{memo_id}"

    author = _author_from_dir(member_dir.name)
    created_at = _created_at_from_id(path.stem) or _created_at_from_stat(path)
    return Job(
        path=path,
        inbox_dir=inbox_dir,
        author=author,
        kind=kind,
        memo_id=memo_id,
        created_at=created_at,
    )


def _author_from_dir(dir_name: str) -> str:
    if dir_name.endswith("_Notes"):
        return dir_name[: -len("_Notes")]
    return dir_name


def _created_at_from_id(stem: str) -> str | None:
    match = _MEMO_ID_RE.search(stem)
    if not match:
        return None
    try:
        moment = datetime.strptime(
            f"{match.group(1)}_{match.group(2)}", "%Y%m%d_%H%M%S"
        )
    except ValueError:
        return None
    return moment.strftime("%Y-%m-%d %H:%M:%S")


def _created_at_from_stat(path: Path) -> str:
    try:
        return datetime.fromtimestamp(path.stat().st_mtime).strftime(
            "%Y-%m-%d %H:%M:%S"
        )
    except OSError:
        return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def wait_until_stable(path: Path, quiet: float, timeout: float) -> bool:
    """等文件大小稳定。

    Syncthing 是分块写入的，事件触发的瞬间文件可能只有几 KB。
    这里不信任任何单次事件，只认"连续 quiet 秒大小不变"。
    """
    deadline = time.monotonic() + timeout
    last_size: int | None = None
    last_change = time.monotonic()

    while time.monotonic() < deadline:
        try:
            size = path.stat().st_size
        except OSError:
            return False
        now = time.monotonic()
        if last_size is None or size != last_size:
            last_size = size
            last_change = now
        elif now - last_change >= quiet and size > 0:
            return True
        time.sleep(0.2)
    return False


# ---------------------------------------------------------------- 处理器


class Processor:
    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg
        self.state = StateStore(cfg.state_db)
        self.pool = WhisperPool(cfg)
        self.embedder = Embedder(cfg)
        self.ollama = OllamaClient(cfg)
        self.tags = TagRegistry(cfg.sync_root, max_new_tags=cfg.tag_max_new)

        self._executor = ThreadPoolExecutor(
            max_workers=max(1, cfg.concurrency), thread_name_prefix="lvs"
        )
        self._inflight: set[str] = set()
        self._inflight_lock = threading.Lock()
        self._done = threading.Event()
        self._pending = 0
        self._pending_lock = threading.Lock()

    # ------------------------------------------------------------- 调度

    def submit(self, path: Path) -> None:
        key = str(path.resolve())
        with self._inflight_lock:
            if key in self._inflight:
                return
            self._inflight.add(key)
        with self._pending_lock:
            self._pending += 1
        self._executor.submit(self._run, path, key)

    def _run(self, path: Path, key: str) -> None:
        try:
            self.process(path)
        except Exception as error:  # noqa: BLE001 - 单个文件失败不能拖垮服务
            LOGGER.exception("处理 %s 时发生未捕获异常：%s", path, error)
        finally:
            with self._inflight_lock:
                self._inflight.discard(key)
            with self._pending_lock:
                self._pending -= 1
                if self._pending == 0:
                    self._done.set()

    def scan_backlog(self) -> int:
        """启动时把已经躺在 outbox 里、还没处理过的文件捞一遍。"""
        count = 0
        root = self.cfg.sync_root
        if not root.exists():
            LOGGER.warning("同步根目录不存在：%s", root)
            return 0
        for outbox in root.glob("*/outbox"):
            if not outbox.is_dir():
                continue
            for entry in sorted(outbox.iterdir()):
                if entry.is_file() and build_job(entry) is not None:
                    self.submit(entry)
                    count += 1
        if count:
            LOGGER.info("积压扫描：提交 %d 个文件", count)
        return count

    def wait_idle(self, timeout: float = 3600) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with self._pending_lock:
                if self._pending == 0:
                    return
            time.sleep(0.2)

    def shutdown(self) -> None:
        self._executor.shutdown(wait=True)
        self.state.close()

    # ------------------------------------------------------------- 主流程

    def process(self, path: Path, *, force: bool = False) -> None:
        if not path.exists():
            return

        job = build_job(path)
        if job is None:
            return

        if not wait_until_stable(
            path, self.cfg.stability_seconds, self.cfg.stability_timeout
        ):
            LOGGER.warning("文件迟迟没有写完，跳过本轮：%s", path.name)
            return

        digest = sha256_of(path)
        # force 只给 --file 用：调完转写参数（比如换提示词、调 beam）之后，
        # 用户需要能把某条旧录音重新跑一遍看效果，否则只能手工去删状态库。
        if not force and self.state.already_done(str(path), digest):
            LOGGER.debug("已处理过，跳过：%s", path.name)
            return

        LOGGER.info("开始处理 %s/%s", job.author, path.name)
        started = time.monotonic()

        try:
            payload, degraded = self._build_payload(job, path)
        except ExtractionError as error:
            LOGGER.error("提炼失败 %s：%s", path.name, error)
            write_error(job.inbox_dir, job.memo_id, str(error))
            self.state.mark(str(path), digest, "failed", str(error))
            return
        except Exception as error:  # noqa: BLE001
            LOGGER.exception("处理失败 %s", path.name)
            write_error(job.inbox_dir, job.memo_id, "处理失败", str(error))
            self.state.mark(str(path), digest, "failed", str(error))
            return

        elapsed = time.monotonic() - started
        LOGGER.info(
            "完成 %s：%.1fs，摘要「%s」%s",
            path.name,
            elapsed,
            payload["summary"][:30],
            "（降级模式：仅转写，未提炼）" if degraded else "",
        )

        if self.cfg.dry_run:
            LOGGER.info("试运行模式，不写文件")
            return

        write_result(job.inbox_dir, job.memo_id, payload)
        # 刚落盘的笔记里可能有新标签，下一篇文章必须马上看得到。
        self.tags.invalidate()
        self.state.mark(str(path), digest, "ok", f"{elapsed:.1f}s")

    def _correct(
        self, job: Job, transcript: str
    ) -> tuple[str, list[dict[str, str]]]:
        """转写后的两层校正：本地词库（确定性）+ 本地 LLM（上下文）。

        任何一层失败都只是少改几处，绝不能让整条记录处理失败。
        """
        text = transcript
        corrections: list[dict[str, str]] = []
        vocabulary = self.pool.vocabulary(job.author, limit=200)

        if self.cfg.lexicon_correct:
            try:
                result = corrector.correct(text, personal_terms=vocabulary)
                if result.changed:
                    text = result.text
                    corrections.extend(result.as_dicts())
                    LOGGER.info("词典纠错 %d 处", len(result.corrections))
            except Exception as error:  # noqa: BLE001
                LOGGER.warning("词典纠错跳过：%s", error)

        if self.cfg.llm_correct:
            try:
                hints = corrector.collect_hints(text, personal_terms=vocabulary)
                fix = self.ollama.correct_transcript(
                    text, terms=vocabulary, hints=hints
                )
                if fix.applied and fix.corrections:
                    text = fix.text
                    corrections.extend(fix.corrections)
                    LOGGER.info("LLM 校正 %d 处", len(fix.corrections))
                elif not fix.applied and fix.reason != "无需修改":
                    LOGGER.warning("LLM 校正未采用：%s", fix.reason)
            except Exception as error:  # noqa: BLE001
                LOGGER.warning("LLM 校正跳过：%s", error)

        return text, corrections

    def _build_payload(self, job: Job, path: Path) -> tuple[dict, bool]:
        transcript = ""
        language = ""
        duration = 0.0
        segments = 0

        if job.kind == "audio":
            result = self.pool.transcribe(path, author=job.author)
            transcript = result.text
            language = result.language
            duration = result.duration
            segments = result.segment_count
            LOGGER.info(
                "转写完成：%.1fs 音频，%d 段，语种 %s(%.2f)",
                duration,
                segments,
                language,
                result.language_probability,
            )
        else:
            transcript = path.read_text(encoding="utf-8", errors="replace").strip()

        if not transcript:
            raise ExtractionError("转写结果为空，无法提炼")

        # 校正只对音频生效。文字随手记是用户亲手打的字（还有 Markdown、
        # 英文术语、型号），任何自动纠错都只会帮倒忙。
        original_transcript = transcript
        corrections: list[dict[str, str]] = []
        if job.kind == "audio":
            transcript, corrections = self._correct(job, transcript)

        # 提炼失败不阻断流程：用户至少还能拿到原始转写。
        degraded = False
        try:
            extracted = self.ollama.extract(
                body=transcript,
                author=job.author,
                created_at=job.created_at,
                kind=job.kind,
                existing_tags=self.tags.tags(limit=40),
            )
        except ExtractionError as error:
            LOGGER.warning("提炼降级（只回传转写）：%s", error)
            degraded = True
            extracted = {
                "summary": transcript[:60].replace("\n", " "),
                "knowledge_points": [],
                "todos": [],
                "tags": [],
                "aliases": [],
            }

        # LLM 负责语义复用（提示词里给了全部已有标签），这里再做一次确定性
        # 兜底：即使模型没听话造了「QCY」这种变体，也一定会被并回已有标签。
        if not degraded and self.cfg.tag_merge:
            resolution = self.tags.resolve(extracted.get("tags", []))
            # 无论有没有"改动"都要用归并结果：它还会做大小写/空格归一和去重。
            extracted["tags"] = resolution.tags
            if resolution.changed:
                aliases = list(extracted.get("aliases") or [])
                for variant in resolution.variants:
                    if variant not in aliases and len(aliases) < 12:
                        aliases.append(variant)
                extracted["aliases"] = aliases
                LOGGER.info(
                    "标签归并：%s → %s；新建 %s；旧写法保留进 aliases %s",
                    resolution.mapped or "无",
                    resolution.tags,
                    resolution.created or "无",
                    resolution.variants or "无",
                )

        vector = self.embedder.embed(
            " ".join(
                [
                    extracted.get("summary", ""),
                    " ".join(extracted.get("knowledge_points", [])),
                    " ".join(extracted.get("tags", [])),
                    transcript,
                ]
            ).strip()
        )

        payload = {
            "id": job.memo_id,
            "created_at": job.created_at,
            "kind": job.kind,
            "audio_filename": path.name if job.kind == "audio" else None,
            "author": job.author,
            "summary": extracted.get("summary", ""),
            "knowledge_points": extracted.get("knowledge_points", []),
            "todos": extracted.get("todos", []),
            "tags": extracted.get("tags", []),
            "aliases": extracted.get("aliases", []),
            # raw_transcript 放**校正后**的最终文本：手机端一直读这个字段，
            # 这样不用重装 APK 就能看到纠错效果。原始 ASR 结果另存
            # original_transcript，任何改动都能追溯、能回退。
            "raw_transcript": transcript,
            "corrections": corrections,
            "embedding": vector or [],
            "embedding_model": self.embedder.model_id if vector else None,
            "embedding_dim": len(vector) if vector else None,
            "schema_version": SCHEMA_VERSION,
            "processed_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "processing": {
                "degraded": degraded,
                "whisper_model": self.cfg.whisper_model if job.kind == "audio" else None,
                "language": language or None,
                "duration_seconds": round(duration, 2),
                "segment_count": segments,
                "llm_model": None if degraded else self.cfg.ollama_model,
                "correction_count": len(corrections),
            },
        }
        # 只有真的改过才存原始文本，避免每条记录都多一份全文副本。
        if original_transcript != transcript:
            payload["original_transcript"] = original_transcript
        return payload, degraded


# ---------------------------------------------------------------- 文件监听


class OutboxHandler(FileSystemEventHandler):  # type: ignore[misc]
    def __init__(self, processor: Processor) -> None:
        self._processor = processor
        self._recent: dict[str, float] = {}
        self._lock = threading.Lock()

    def _maybe_submit(self, raw_path: str) -> None:
        path = Path(raw_path)
        if path.suffix.lower() not in AUDIO_SUFFIXES | TEXT_SUFFIXES:
            return
        if path.name.startswith(".") or path.name.endswith(".part"):
            return
        if "outbox" not in path.parts:
            return

        # watchdog 在 macOS 上会对同一次写入连发多个事件，这里做 3 秒去抖。
        key = str(path)
        now = time.monotonic()
        with self._lock:
            last = self._recent.get(key)
            if last is not None and now - last < 3.0:
                return
            self._recent[key] = now
            if len(self._recent) > 512:
                cutoff = now - 60
                self._recent = {
                    k: v for k, v in self._recent.items() if v > cutoff
                }
        self._processor.submit(path)

    def on_created(self, event: FileSystemEvent) -> None:  # type: ignore[override]
        if not event.is_directory:
            self._maybe_submit(str(event.src_path))

    def on_moved(self, event: FileSystemEvent) -> None:  # type: ignore[override]
        if not event.is_directory:
            # 原子重命名（手机端的 .tmp → memo_*.m4a）会走 moved 事件，
            # 这才是最常见、最可靠的触发点。
            self._maybe_submit(str(event.dest_path))

    def on_modified(self, event: FileSystemEvent) -> None:  # type: ignore[override]
        if not event.is_directory:
            self._maybe_submit(str(event.src_path))


# ---------------------------------------------------------------- 自检


def run_check(cfg: Config) -> int:
    ok = True
    print("=" * 62)
    print("LocalVoiceSync 环境自检")
    print("=" * 62)
    print(cfg.describe())
    print("-" * 62)

    print(f"同步根目录存在      {'✓' if cfg.sync_root.exists() else '✗'}  {cfg.sync_root}")
    ok &= cfg.sync_root.exists()

    try:
        import faster_whisper  # noqa: F401

        print("faster-whisper      ✓")
    except ImportError:
        print("faster-whisper      ✗  请 pip install faster-whisper")
        ok = False

    # 提示词是影响转写质量的关键输入，自检时必须能直接看到它，
    # 否则"识别不准"永远只能靠猜。同时显示真实 token 占用，
    # 因为 Whisper 只保留最后 223 个 token，超了会静默丢掉前面的词。
    try:
        from hotwords import build_prompt, collect, make_token_cost, merge_terms

        manual = cfg.manual_hotwords()
        auto = [] if cfg.hotwords_disabled else collect(cfg.sync_root)
        terms = merge_terms(manual, auto)
        token_cost = make_token_cost(cfg.cache_dir)
        prompt = build_prompt(cfg.whisper_prompt_base, terms, token_cost=token_cost)
        used = token_cost(prompt) if token_cost else None
        source = (
            "已关闭"
            if cfg.hotwords_disabled
            else f"手写 {len(manual)} + 自动 {len(auto)}，实际装入 {len(terms)}"
        )
        print(f"转写提示词          {prompt}")
        print(
            f"                    词表（{source}）"
            + (f"，{used}/223 token" if used is not None else "，tokenizer 未加载")
        )
    except Exception as error:  # noqa: BLE001
        print(f"转写提示词          ✗  {error}")

    try:
        import corrector

        lexicon = corrector.get_lexicon()
        if lexicon is None:
            print("本地词库            ✗  未加载（检查 pypinyin 与 lexicon/ 目录）")
        else:
            print(
                f"本地词库            ✓  {len(lexicon.words)} 个已知词，"
                f"{len(lexicon._priority)} 个高置信专名"
            )
    except Exception as error:  # noqa: BLE001
        print(f"本地词库            ✗  {error}")

    try:
        from tag_registry import all_tags, iter_note_paths

        tags = all_tags(cfg.sync_root)
        notes = len(list(iter_note_paths(cfg.sync_root)))
        print(f"标签词表            ✓  {len(tags)} 个标签 / {notes} 篇笔记")
        if tags:
            print(
                "                    "
                + "、".join(tags[:12])
                + (" …" if len(tags) > 12 else "")
            )
    except Exception as error:  # noqa: BLE001
        print(f"标签词表            ✗  {error}")

    try:
        print(f"待办状态            ✓  {state_stats(cfg.sync_root)}")
    except Exception as error:  # noqa: BLE001
        print(f"待办状态            ✗  {error}")

    ollama = OllamaClient(cfg)
    if ollama.health():
        has_model = ollama.has_model()
        print(f"Ollama 服务         ✓  {cfg.ollama_url}")
        print(f"模型 {cfg.ollama_model}  {'✓' if has_model else '✗  请 ollama pull ' + cfg.ollama_model}")
        ok &= has_model
    else:
        print(f"Ollama 服务         ✗  无法连接 {cfg.ollama_url}")
        ok = False

    try:
        from fastembed import TextEmbedding  # noqa: F401

        print("fastembed           ✓")
    except ImportError:
        print("fastembed           ✗  请 pip install fastembed（只影响向量化）")

    try:
        from watchdog.observers import Observer as _Observer  # noqa: F401

        print("watchdog            ✓")
    except ImportError:
        print("watchdog            ✗  请 pip install watchdog")
        ok = False

    print("-" * 62)
    print("结论：" + ("环境就绪，可以启动服务" if ok else "存在阻塞项，请先修复上面标 ✗ 的条目"))
    return 0 if ok else 1


# ---------------------------------------------------------------- 入口


def configure_logging(level: str) -> None:
    logging.basicConfig(
        level=getattr(logging, level, logging.INFO),
        format="%(asctime)s %(levelname)-5s [%(name)s] %(message)s",
        datefmt="%H:%M:%S",
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="LocalVoiceSync Mac 端处理流水线",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--sync-root", help="覆盖同步根目录")
    parser.add_argument("--check", action="store_true", help="只做环境自检")
    parser.add_argument(
        "--todos",
        action="store_true",
        help="汇总所有笔记待办与手机同步过来的完成状态（只读，不改文件）",
    )
    parser.add_argument("--once", action="store_true", help="处理完积压后退出")
    parser.add_argument("--file", help="只处理指定文件")
    parser.add_argument(
        "--force",
        action="store_true",
        help="配合 --file：忽略去重记录，强制重新处理（调完转写参数后重跑用）",
    )
    parser.add_argument("--dry-run", action="store_true", help="只处理不写文件")
    parser.add_argument(
        "--normalize-tags",
        action="store_true",
        help="整理已有标签：默认只预览，加 --apply 才写回（自动备份）",
    )
    parser.add_argument(
        "--apply", action="store_true", help="配合 --normalize-tags：实际写回"
    )
    parser.add_argument(
        "--no-llm",
        action="store_true",
        help="配合 --normalize-tags：只用确定性规则，不调用 Ollama",
    )
    args = parser.parse_args(argv)

    cfg = Config.load(args.sync_root)
    if args.dry_run:
        cfg = replace(cfg, dry_run=True)
    configure_logging(cfg.log_level)

    if args.check:
        return run_check(cfg)

    if args.todos:
        print(format_report(cfg.sync_root))
        return 0

    if args.normalize_tags:
        report = normalize_existing_notes(
            cfg,
            OllamaClient(cfg),
            apply=args.apply and not args.dry_run,
            use_llm=not args.no_llm,
        )
        print_report(report)
        return 0

    processor = Processor(cfg)

    # 单文件模式：直接跑，不需要 watchdog
    if args.file:
        target = Path(args.file).expanduser().resolve()
        if not target.exists():
            LOGGER.error("文件不存在：%s", target)
            return 2
        processor.process(target, force=args.force)
        processor.shutdown()
        return 0

    processor.scan_backlog()

    if args.once:
        processor.wait_idle()
        processor.shutdown()
        LOGGER.info("积压处理完毕，退出")
        return 0

    if Observer is None:
        LOGGER.error("未安装 watchdog，无法监听目录。请 pip install watchdog")
        processor.shutdown()
        return 2

    observer = Observer()
    observer.schedule(OutboxHandler(processor), str(cfg.sync_root), recursive=True)
    observer.start()
    LOGGER.info("开始监听 %s", cfg.sync_root)
    LOGGER.info("按 Ctrl+C 退出")

    stop = threading.Event()

    def _handle_signal(signum, _frame):  # noqa: ANN001
        LOGGER.info("收到信号 %s，准备退出…", signum)
        stop.set()

    signal.signal(signal.SIGINT, _handle_signal)
    signal.signal(signal.SIGTERM, _handle_signal)

    try:
        while not stop.is_set():
            stop.wait(0.5)
    finally:
        LOGGER.info("停止监听，等待在途任务…")
        observer.stop()
        observer.join(timeout=5)
        processor.wait_idle(timeout=120)
        processor.shutdown()
        LOGGER.info("已退出")
    return 0


if __name__ == "__main__":
    sys.exit(main())
