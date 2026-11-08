"""用本地 Ollama 把口语转写提炼成结构化知识。

关键设计：
- `format: "json"` 让 Ollama 强制走 JSON 语法约束，比在提示词里喊"请输出 JSON"可靠得多；
- `think: false` 关掉 Qwen3 系列的思考链，否则几十秒的推理过程既慢又会把
  思考内容混进 JSON 之外的地方；
- 输出一律做**防御式校验**：大模型偶尔会把数组写成字符串、把 todos 写成
  字符串数组，这里全部归一化，绝不让脏数据流到手机上把 App 搞崩。
"""

from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass
from typing import Any, Iterable

import requests

from config import Config

LOGGER = logging.getLogger("lvs.extract")


class ExtractionError(RuntimeError):
    """提炼失败（模型没起、超时、返回无法解析等）。"""


SYSTEM_PROMPT = """你是一个严谨的中文知识整理助手，服务于一个家庭私有语音备忘系统。
你的任务是把一段口语转写整理成结构化笔记，供日后检索。

必须遵守的规则：
1. 只输出一个 JSON 对象，不要任何解释、不要 Markdown 代码块。
2. 不要编造原文没有的信息。原文含糊就写得含糊，宁短勿错。
3. 所有内容用简体中文；专有名词（型号、品牌、英文术语）保留原文写法。
4. summary 是一句话摘要，40 字以内，说清"这段录音到底讲了什么"。
5. knowledge_points 是真正值得记住的事实/结论/参数，每条一个独立要点；
   纯寒暄、语气词、重复内容不要放进来。没有就给空数组。
6. todos 只收"需要有人去做"的动作，status 一律填 "pending"；
   原文明确说已经做完的才填 "completed"。没有就给空数组。
7. tags 是 2~5 个名词性标签，用于分类浏览；不要用"记录""备忘"这类无信息量的词。
   同一主题必须用同一个标签名，优先照抄输入里给出的「已有标签」原文。
8. aliases 是帮助日后搜索的同义词/别称/英文对照/常见错别字写法，
   例如"逆变器"的 aliases 可以包含 "inverter"、"变流器"。

输出 JSON 的字段必须且只能是：
{
  "summary": "字符串",
  "knowledge_points": ["字符串", ...],
  "todos": [{"task": "字符串", "status": "pending"}, ...],
  "tags": ["字符串", ...],
  "aliases": ["字符串", ...]
}"""

USER_TEMPLATE = """作者：{author}
记录时间：{created_at}
来源类型：{kind}
{tag_block}
--- 转写正文开始 ---
{body}
--- 转写正文结束 ---

请按要求输出 JSON。"""

# 提炼时把「现有标签词表」一并交给模型。模型只看得见这一条笔记，不给它
# 词表，它就每次都重新造一批同义词（ASL手语 / 手语 AI / 无障碍数据集…）。
TAG_BLOCK_TEMPLATE = """
本知识库已有标签（按使用频次排序，优先复用）：
{known}

标签规则（重要）：
- 先判断这条笔记属于上面哪些主题，**直接照抄已有标签原文**，
  不要改写、不要缩写、不要加后缀。
- 已有标签能覆盖的主题，绝不新建同义词。
  例：已有「手语」就不要再写「手语识别」「ASL手语」「手语 AI」。
- 只有主题确实不属于任何已有标签时才新建，且整篇最多新建 1 个标签。
- tags 总数 2~5 个，名词性、精炼，不要「记录」「备忘」这类空词。"""

EMPTY_TAG_BLOCK = """
本知识库目前还没有标签，请为这条笔记建立 2~4 个精炼的名词性标签。
以后同类笔记会复用这些标签，所以命名要通用、不要带具体日期或细节。"""


# 一次性整理已有标签时用：让 LLM 给出语义分组，代码再做严格校验与兜底。
MERGE_SYSTEM_PROMPT = """你是一个标签体系整理员，服务于家庭私有语音知识库。
输入是这个知识库目前已有的全部标签，里面有很多同义或同主题的重复写法。
你的任务是把**确实属于同一主题**的标签归成一组，给出统一的规范名。

必须遵守的规则：
1. 只输出一个 JSON 对象，不要解释、不要 Markdown 代码块，格式为：
   {"groups": [{"canonical": "统一标签名", "members": ["标签A", "标签B"]}]}
2. members 里的每个词都必须是输入清单里**原样出现**的标签；每个标签最多
   出现在一个组里；没有合并必要的标签不要写进任何组。
3. canonical 只能是某个 member 的原文，或某个 member 里**实际出现的片段**
   （例如把「ASL手语」「手语 AI」统一成「手语」）。不要生造新词，
   不要用「数据工程」「系统管理」「出行」这种凭空概括出来的名字，
   更不要用「数据」「系统」「管理」「设计」这类会吞掉别的主题的词。
4. 同一组里的标签必须**每两个都长得像**：包含关系或共享同一个词根。
   「ASL手语 / 手语 AI / 手语识别」共享「手语」，可以合并；
   「系统测试 / 版本测试 / 测试」共享「测试」，可以合并。
5. **不同维度绝对不要合并**：「蓝牙耳机」（物件）和「硬件维修」（动作）、
   「停车」和「导航」、「数据库优化」（软件索引）和「无障碍数据集」（AI 语料）
   都不是同义词，哪怕它们出现在同一篇笔记里。
6. 只合并语义确实相同或高度重叠的标签，宁可少合并，不可把不同主题搅在一起。
7. 每组至少 2 个成员，最多 4 个。"""

MERGE_USER_TEMPLATE = """现有标签（后面的数字是使用次数）：
{tags}

请输出分组 JSON。"""


CORRECT_SYSTEM_PROMPT = """你是中文语音识别结果的校对员，服务一个家庭私有语音备忘系统。
输入是一段语音转写，里面**一定**存在同音字错误，尤其是人名、地名、品牌、节日、型号，
以及动词搭配（听到 / 停到、近可能 / 尽可能、在 / 再）。

你的任务是把这些明显的错别字改正，其它一律不动。

必须遵守的规则：
1. 只输出一个 JSON 对象，不要解释、不要 Markdown 代码块，格式为 {"text": "校对后的全文"}。
2. **不要改写句子、不要调整语序、不要润色、不要删减或补充任何内容。**
   你只是在同一个句子上换掉几个错字。
3. 重点找：读音相同或相近、但在这个上下文里明显不成词、或者和上下文矛盾的字。
   例：「近可能往里走」→「尽可能往里走」；
       「听到棉花糖家」在通篇讲停车时 → 「停到棉花糖家」；
       「万圣洁」→「万圣节」。
4. 拿不准的地方**保持原样**。宁可少改，不可改错。
5. 参考候选里的词绝大多数是噪音，只有在上下文明确指向它时才采用。
6. 数字、英文、型号保持原样；口语重复（"人又多，人又多"）保持原样。
7. 输出长度必须和原文基本一致；如果改完差别很大，说明你改错了，请原样输出。"""

CORRECT_USER_TEMPLATE = """本家庭常见专名（仅供比对，不一定出现在这段录音里）：
{terms}

词库里与可疑片段同音/近音的候选（噪音居多，仅供参考）：
{hints}

--- 转写正文开始 ---
{body}
--- 转写正文结束 ---

请按要求输出 JSON。"""


@dataclass
class LlmFix:
    """LLM 校正结果。`applied=False` 表示输出没通过安全校验，已原样退回。"""

    text: str
    corrections: list[dict[str, str]]
    applied: bool
    reason: str = ""


class OllamaClient:
    def __init__(self, cfg: Config) -> None:
        self._cfg = cfg
        self._session = requests.Session()

    # ------------------------------------------------------------- 可用性

    def health(self) -> bool:
        try:
            response = self._session.get(f"{self._cfg.ollama_url}/api/tags", timeout=5)
            return response.status_code == 200
        except requests.RequestException:
            return False

    def has_model(self) -> bool:
        try:
            response = self._session.get(f"{self._cfg.ollama_url}/api/tags", timeout=5)
            if response.status_code != 200:
                return False
            payload = response.json()
            names = {model.get("name", "") for model in payload.get("models", [])}
            target = self._cfg.ollama_model
            # Ollama 的 name 可能带 :latest 后缀，做一次宽松匹配
            return target in names or any(n.split(":")[0] == target.split(":")[0] for n in names)
        except (requests.RequestException, ValueError):
            return False

    # ------------------------------------------------------------- 提炼

    def extract(
        self,
        *,
        body: str,
        author: str,
        created_at: str,
        kind: str,
        existing_tags: Iterable[str] = (),
    ) -> dict[str, Any]:
        if not body.strip():
            return _empty_result()

        known = [str(t).strip() for t in existing_tags if str(t).strip()][:40]
        tag_block = (
            TAG_BLOCK_TEMPLATE.format(known="、".join(known))
            if known
            else EMPTY_TAG_BLOCK
        )

        payload = {
            "model": self._cfg.ollama_model,
            "stream": False,
            "format": "json",
            "think": False,
            "options": {
                "temperature": 0.2,
                "top_p": 0.9,
                "num_ctx": self._cfg.ollama_num_ctx,
                "num_predict": 1024,
            },
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {
                    "role": "user",
                    "content": USER_TEMPLATE.format(
                        author=author,
                        created_at=created_at,
                        kind=kind,
                        tag_block=tag_block,
                        body=body,
                    ),
                },
            ],
        }

        try:
            response = self._session.post(
                f"{self._cfg.ollama_url}/api/chat",
                json=payload,
                timeout=self._cfg.ollama_timeout,
            )
        except requests.RequestException as error:
            raise ExtractionError(f"无法连接 Ollama（{self._cfg.ollama_url}）：{error}") from error

        if response.status_code == 404:
            raise ExtractionError(
                f"Ollama 里没有模型 {self._cfg.ollama_model}，"
                f"请先执行：ollama pull {self._cfg.ollama_model}"
            )
        if response.status_code != 200:
            raise ExtractionError(
                f"Ollama 返回 {response.status_code}：{response.text[:300]}"
            )

        try:
            data = response.json()
        except ValueError as error:
            raise ExtractionError("Ollama 返回的不是 JSON") from error

        content = (data.get("message") or {}).get("content", "")
        parsed = _parse_json_block(content)
        if parsed is None:
            raise ExtractionError(f"模型输出无法解析为 JSON：{content[:300]}")

        return normalize_result(parsed)

    # ------------------------------------------------------------- 标签整理

    def plan_tag_merge(
        self, tags: list[str], counts: dict[str, int] | None = None
    ) -> list[dict[str, Any]]:
        """让本地 LLM 给现有标签做语义分组。

        只在 `--normalize-tags` 这种一次性整理时调用一次，不进日常流水线。
        输出**不信任**：调用方（tag_cleanup.py）会逐字段校验，任何越界的
        分组直接丢弃，退回纯确定性归并。
        """
        if len(tags) < 2:
            return []
        lines = [
            f"- {tag}（{counts.get(tag, 1) if counts else 1} 次）" for tag in tags[:120]
        ]
        payload = {
            "model": self._cfg.ollama_model,
            "stream": False,
            "format": "json",
            "think": False,
            "options": {
                "temperature": 0.1,
                "top_p": 0.9,
                "num_ctx": self._cfg.ollama_num_ctx,
                "num_predict": 1024,
            },
            "messages": [
                {"role": "system", "content": MERGE_SYSTEM_PROMPT},
                {
                    "role": "user",
                    "content": MERGE_USER_TEMPLATE.format(tags="\n".join(lines)),
                },
            ],
        }
        try:
            response = self._session.post(
                f"{self._cfg.ollama_url}/api/chat",
                json=payload,
                timeout=min(self._cfg.ollama_timeout, 180.0),
            )
        except requests.RequestException as error:
            LOGGER.warning("标签分组跳过（连不上 Ollama）：%s", error)
            return []
        if response.status_code != 200:
            LOGGER.warning("标签分组跳过：Ollama 返回 %s", response.status_code)
            return []
        try:
            data = response.json()
        except ValueError:
            return []
        parsed = _parse_json_block((data.get("message") or {}).get("content", ""))
        if not parsed:
            return []
        groups = parsed.get("groups")
        return groups if isinstance(groups, list) else []

    # ------------------------------------------------------------- 二次校正

    def correct_transcript(
        self,
        text: str,
        *,
        terms: Iterable[str] = (),
        hints: Iterable[dict[str, Any]] = (),
    ) -> LlmFix:
        """让本地 LLM 修上下文相关的同音错字。

        词典层只能改「完全同音的已知专名」，改不了「听到棉花糖家 → 停到
        棉花糖家」这种需要看上下文的错误。这一层补上，但**输出必须过安全校验**：
        长度、相似度、改动量任何一项越界就整体退回原文，绝不把 LLM 的
        自由发挥写进用户记录。
        """
        body = text.strip()
        if not body:
            return LlmFix(text, [], False, "空文本")

        term_list = [str(t).strip() for t in terms if str(t).strip()][:30]
        hint_lines: list[str] = []
        for hint in list(hints)[:8]:
            fragment = str(hint.get("fragment", "")).strip()
            candidates = hint.get("candidates") or []
            if fragment and candidates:
                joined = "、".join(str(c) for c in candidates[:3])
                hint_lines.append(f"- {fragment} → {joined}")

        payload = {
            "model": self._cfg.ollama_model,
            "stream": False,
            "format": "json",
            "think": False,
            "options": {
                "temperature": 0.0,
                "top_p": 0.9,
                "num_ctx": self._cfg.ollama_num_ctx,
                "num_predict": min(2048, max(512, len(body) * 2)),
            },
            "messages": [
                {"role": "system", "content": CORRECT_SYSTEM_PROMPT},
                {
                    "role": "user",
                    "content": CORRECT_USER_TEMPLATE.format(
                        terms="、".join(term_list) or "（无）",
                        hints="\n".join(hint_lines) or "（无）",
                        body=body,
                    ),
                },
            ],
        }

        try:
            response = self._session.post(
                f"{self._cfg.ollama_url}/api/chat",
                json=payload,
                timeout=min(self._cfg.ollama_timeout, 180.0),
            )
        except requests.RequestException as error:
            return LlmFix(text, [], False, f"连接 Ollama 失败：{error}")

        if response.status_code != 200:
            return LlmFix(text, [], False, f"Ollama 返回 {response.status_code}")

        try:
            data = response.json()
        except ValueError:
            return LlmFix(text, [], False, "Ollama 返回的不是 JSON")

        content = (data.get("message") or {}).get("content", "")
        parsed = _parse_json_block(content)
        if not parsed:
            return LlmFix(text, [], False, "校正输出无法解析")

        corrected = parsed.get("text")
        if not isinstance(corrected, str):
            return LlmFix(text, [], False, "校正输出缺少 text 字段")
        corrected = corrected.strip()
        if not corrected:
            return LlmFix(text, [], False, "校正输出为空")

        reason = _unsafe_reason(body, corrected)
        if reason:
            return LlmFix(text, [], False, reason)
        if corrected == body:
            return LlmFix(text, [], True, "无需修改")

        return LlmFix(corrected, _diff_corrections(body, corrected), True)


def _unsafe_reason(original: str, corrected: str) -> str:
    """LLM 输出是否越界。返回空串表示安全。

    LLM 校正最大的风险不是改错一个字，而是顺手"润色"甚至补内容。
    三个硬指标一起卡：长度、相似度、改动字符数。
    """
    import difflib

    if not 0.9 <= len(corrected) / max(1, len(original)) <= 1.1:
        return "长度偏差过大"
    similarity = difflib.SequenceMatcher(
        None, original, corrected, autojunk=False
    ).ratio()
    if similarity < 0.85:
        return f"相似度过低（{similarity:.2f}）"

    changed = sum(
        max(i2 - i1, j2 - j1)
        for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(
            None, original, corrected, autojunk=False
        ).get_opcodes()
        if tag != "equal"
    )
    if changed > max(4, int(len(original) * 0.15)):
        return f"改动过多（{changed} 字）"
    return ""


_PUNCTUATION = frozenset("，。、；：？！“”‘’（）《》—…·,.;:?!\"'()[]{}<>/\\|~`-_\n\r\t ")


def _is_punctuation_only(text: str) -> bool:
    return all(ch in _PUNCTUATION for ch in text)


def _diff_corrections(
    original: str, corrected: str, limit: int = 8
) -> list[dict[str, str]]:
    import difflib

    items: list[dict[str, str]] = []
    matcher = difflib.SequenceMatcher(None, original, corrected, autojunk=False)
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            continue
        source = original[i1:i2]
        target = corrected[j1:j2]
        # 把两端都是标点的字符剥掉，让记录只呈现真正改动的字：
        # ",近" → "，尽" 记成 "近" → "尽" 才看得懂（注意半角/全角不算相等）。
        while (
            source
            and target
            and source[0] in _PUNCTUATION
            and target[0] in _PUNCTUATION
        ):
            source, target = source[1:], target[1:]
        while (
            source
            and target
            and source[-1] in _PUNCTUATION
            and target[-1] in _PUNCTUATION
        ):
            source, target = source[:-1], target[:-1]
        if not source and not target:
            continue
        if source == target:
            continue
        # 半角→全角这类纯标点差异不写进改动记录：手机上看得见效果，
        # 但把它列成"校正"只会淹没真正的错字修正。
        if _is_punctuation_only(source) and _is_punctuation_only(target):
            continue
        items.append({"from": source, "to": target, "source": "llm"})
        if len(items) >= limit:
            break
    return items


# ---------------------------------------------------------------- 解析与归一化

_FENCE = re.compile(r"^\s*```(?:json)?\s*|\s*```\s*$", re.MULTILINE)


def _parse_json_block(content: str) -> dict[str, Any] | None:
    """从模型输出里抠出 JSON。

    即使开了 format=json，个别版本仍会包一层代码块或前后加一句废话，
    这里做三级兜底：直接解析 → 去围栏 → 截取第一个 { 到最后一个 }。
    """
    text = (content or "").strip()
    if not text:
        return None

    for candidate in (
        text,
        _FENCE.sub("", text).strip(),
        _slice_braces(text),
    ):
        if not candidate:
            continue
        try:
            parsed = json.loads(candidate)
        except json.JSONDecodeError:
            continue
        if isinstance(parsed, dict):
            return parsed
    return None


def _slice_braces(text: str) -> str:
    start = text.find("{")
    end = text.rfind("}")
    if start == -1 or end == -1 or end <= start:
        return ""
    return text[start : end + 1]


def _as_str_list(value: Any, limit: int) -> list[str]:
    """把各种奇形怪状的输入归一化成去重后的字符串列表。"""
    items: list[Any]
    if value is None:
        return []
    if isinstance(value, str):
        # 模型有时把数组写成 "a, b, c" 或 "a、b、c"
        items = re.split(r"[,，;；、\n]", value)
    elif isinstance(value, (list, tuple, set)):
        items = list(value)
    else:
        return []

    seen: set[str] = set()
    result: list[str] = []
    for item in items:
        if isinstance(item, dict):
            item = item.get("task") or item.get("name") or item.get("text") or ""
        text = str(item).strip().strip("-•*·").strip()
        if not text or len(text) > 120:
            continue
        if text in seen:
            continue
        seen.add(text)
        result.append(text)
        if len(result) >= limit:
            break
    return result


def _as_todos(value: Any, limit: int = 12) -> list[dict[str, str]]:
    if value is None:
        return []
    if isinstance(value, str):
        value = [value]
    if not isinstance(value, (list, tuple)):
        return []

    todos: list[dict[str, str]] = []
    seen: set[str] = set()
    for item in value:
        if isinstance(item, dict):
            task = str(
                item.get("task") or item.get("title") or item.get("content") or ""
            ).strip()
            status = str(item.get("status") or "pending").strip().lower()
            if status not in {"pending", "completed"}:
                status = "completed" if status in {"done", "finished", "已完成"} else "pending"
        else:
            task = str(item).strip()
            status = "pending"
        if not task or len(task) > 120 or task in seen:
            continue
        seen.add(task)
        todos.append({"task": task, "status": status})
        if len(todos) >= limit:
            break
    return todos


def normalize_result(raw: dict[str, Any]) -> dict[str, Any]:
    summary = str(raw.get("summary") or "").strip()
    if len(summary) > 200:
        summary = summary[:200].rstrip() + "…"
    return {
        "summary": summary,
        "knowledge_points": _as_str_list(raw.get("knowledge_points"), limit=12),
        "todos": _as_todos(raw.get("todos")),
        "tags": _as_str_list(raw.get("tags"), limit=6),
        "aliases": _as_str_list(raw.get("aliases"), limit=10),
    }


def _empty_result() -> dict[str, Any]:
    return {
        "summary": "",
        "knowledge_points": [],
        "todos": [],
        "tags": [],
        "aliases": [],
    }
