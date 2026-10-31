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
from typing import Any

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

--- 转写正文开始 ---
{body}
--- 转写正文结束 ---

请按要求输出 JSON。"""


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

    def extract(self, *, body: str, author: str, created_at: str, kind: str) -> dict[str, Any]:
        if not body.strip():
            return _empty_result()

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
                        author=author, created_at=created_at, kind=kind, body=body
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
