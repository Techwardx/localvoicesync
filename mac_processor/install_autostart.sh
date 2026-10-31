#!/usr/bin/env bash
#
# 把 Syncthing 和 Mac 处理服务注册成开机自启（LaunchAgent）。
#
#   ./install_autostart.sh          安装并立即启动
#   ./install_autostart.sh --status 只看状态
#   ./install_autostart.sh --remove 卸载
#
# 为什么必须做这一步：
#   这两样东西现在都是"手工在终端里敲起来的进程"。电脑一重启、
#   或者终端一关，它们就没了 —— 而手机端完全看不出来：
#   状态灯照样可能因为别的判断显示在线，只是再也没有总结回传。
#   这是最容易被误判成"App 有 bug"的一种故障。
#
# ⚠️ 必须在**真正的终端**里跑。在受限沙箱（比如某些 IDE 的集成终端）
#    里 `launchctl bootstrap` 会报 "Input/output error"。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS="$HOME/Library/LaunchAgents"
LOGS="$HOME/Library/Logs"
SYNCTHING_BIN="$HOME/bin/syncthing"
VENV_PY="$SCRIPT_DIR/.venv/bin/python"

SYNCTHING_LABEL="com.localvoicesync.syncthing"
PROCESSOR_LABEL="com.localvoicesync.processor"
SYNCTHING_PLIST="$AGENTS/$SYNCTHING_LABEL.plist"
PROCESSOR_PLIST="$AGENTS/$PROCESSOR_LABEL.plist"

uid="$(id -u)"

status() {
  echo "== LaunchAgent 状态 =="
  for label in "$SYNCTHING_LABEL" "$PROCESSOR_LABEL"; do
    if launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
      state="$(launchctl print "gui/$uid/$label" 2>/dev/null | awk '/^\tstate = /{print $3; exit}')"
      pid="$(launchctl print "gui/$uid/$label" 2>/dev/null | awk '/^\tpid = /{print $3; exit}')"
      echo "  $label: 已加载（state=${state:-?}${pid:+, pid=$pid}）"
    else
      echo "  $label: 未加载"
    fi
  done
  echo
  echo "== 进程 =="
  pgrep -fl "syncthing serve" || echo "  syncthing: 没在跑"
  pgrep -fl "mac_processor/main.py" || pgrep -fl "main.py" || echo "  processor: 没在跑"
  echo
  echo "== 日志 =="
  echo "  tail -f $LOGS/localvoicesync-syncthing.log"
  echo "  tail -f $LOGS/localvoicesync-processor.log"
}

write_plists() {
  mkdir -p "$AGENTS" "$LOGS"

  cat > "$SYNCTHING_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$SYNCTHING_LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>$SYNCTHING_BIN</string>
        <string>serve</string>
        <string>--no-browser</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>

    <key>ProcessType</key>
    <string>Background</string>

    <key>StandardOutPath</key>
    <string>$LOGS/localvoicesync-syncthing.log</string>
    <key>StandardErrorPath</key>
    <string>$LOGS/localvoicesync-syncthing.log</string>
</dict>
</plist>
PLIST

  cat > "$PROCESSOR_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PROCESSOR_LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>$VENV_PY</string>
        <string>main.py</string>
    </array>

    <key>WorkingDirectory</key>
    <string>$SCRIPT_DIR</string>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>

    <key>ProcessType</key>
    <string>Background</string>

    <key>StandardOutPath</key>
    <string>$LOGS/localvoicesync-processor.log</string>
    <key>StandardErrorPath</key>
    <string>$LOGS/localvoicesync-processor.log</string>
</dict>
</plist>
PLIST
}

load_one() {
  local label="$1" plist="$2"
  launchctl bootout "gui/$uid/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$uid" "$plist"
  launchctl enable "gui/$uid/$label" 2>/dev/null || true
  launchctl kickstart -k "gui/$uid/$label" 2>/dev/null || true
}

case "${1:-install}" in
  --status|status)
    status
    ;;
  --remove|remove)
    for label in "$SYNCTHING_LABEL" "$PROCESSOR_LABEL"; do
      launchctl bootout "gui/$uid/$label" 2>/dev/null || true
    done
    rm -f "$SYNCTHING_PLIST" "$PROCESSOR_PLIST"
    echo "已卸载开机自启（进程可能还在跑，用 pkill 收尾）。"
    ;;
  install|--install|"")
    if [ ! -x "$SYNCTHING_BIN" ]; then
      echo "找不到 $SYNCTHING_BIN —— 请先安装 Syncthing 或改这个脚本里的路径。" >&2
      exit 1
    fi
    if [ ! -x "$VENV_PY" ]; then
      echo "找不到 $VENV_PY —— 先跑一次 ./run.sh --check 建好虚拟环境。" >&2
      exit 1
    fi

    write_plists
    echo "已写入："
    echo "  $SYNCTHING_PLIST"
    echo "  $PROCESSOR_PLIST"
    echo

    # 手工启动的同类进程要先让位，否则 8384 端口会被占住。
    pkill -f "syncthing serve" 2>/dev/null || true
    pkill -f "mac_processor/main.py" 2>/dev/null || true
    sleep 1

    load_one "$SYNCTHING_LABEL" "$SYNCTHING_PLIST"
    load_one "$PROCESSOR_LABEL" "$PROCESSOR_PLIST"
    sleep 2
    status
    ;;
  *)
    echo "用法：$0 [install|--status|--remove]" >&2
    exit 2
    ;;
esac
