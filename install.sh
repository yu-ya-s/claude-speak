#!/usr/bin/env bash
# claude-speak の導入：edge-tts 用の仮想環境を作り、WSL と PowerShell が使えるか確認する
set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if ! command -v powershell.exe >/dev/null 2>&1 && [ ! -x /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe ]; then
  echo "powershell.exe が見つかりません。このスキルは WSL（Windows 上）専用です。" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 が必要です。" >&2
  exit 1
fi

cd "$SCRIPT_DIR"
if [ ! -x .venv/bin/python ]; then
  python3 -m venv .venv
fi
.venv/bin/pip install -q --upgrade edge-tts
chmod +x speak.sh

echo "導入完了。Claude Code で /speak と打つと直前の回答を読み上げます。"
echo "声の一覧: $SCRIPT_DIR/.venv/bin/edge-tts --list-voices | grep ja-JP"
