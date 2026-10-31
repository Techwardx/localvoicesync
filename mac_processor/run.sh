#!/usr/bin/env bash
#
# 启动 Mac 端处理服务。
#
#   ./run.sh            常驻监听
#   ./run.sh --check    环境自检
#   ./run.sh --once     处理完积压就退出
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

VENV="$SCRIPT_DIR/.venv"

if [ ! -x "$VENV/bin/python" ]; then
  echo "未找到虚拟环境，正在创建…"
  PYTHON_BIN="${PYTHON_BIN:-python3.12}"
  if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    PYTHON_BIN=python3
  fi
  "$PYTHON_BIN" -m venv "$VENV"
  "$VENV/bin/pip" install --upgrade pip >/dev/null
  "$VENV/bin/pip" install -r requirements.txt
fi

exec "$VENV/bin/python" main.py "$@"
