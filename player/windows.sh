#!/usr/bin/env bash
# Windows（WSL）用の再生窓アダプタ。契約は docs/player-contract.md
# 使い方: windows.sh workdir | start <作業フォルダ> | stop <作業フォルダ>
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PS=$(command -v powershell.exe || echo /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe)
TASKKILL=$(command -v taskkill.exe || echo /mnt/c/Windows/System32/taskkill.exe)

win_temp() {
  local t
  t=$("$PS" -NoProfile -Command '$env:TEMP' 2>/dev/null | tr -d '\r')
  if [ -z "$t" ]; then echo "powershell.exe が見つかりません" >&2; exit 1; fi
  printf '%s' "$t"
}

case "${1:-}" in
  workdir)
    # Windows 側から読める場所に置く必要があるため、Windows の一時フォルダを使う
    wslpath -u "$(win_temp)\\claude-speak"
    ;;
  start)
    work_dir_win=$(wslpath -w "${2:?作業フォルダ}")
    ps1_win="$(win_temp)\\claude-speak-player.ps1"
    # PowerShell 5 が UTF-8 を正しく読むよう BOM 付きで Windows 側へ置く
    { printf '\xEF\xBB\xBF'; cat "$SCRIPT_DIR/windows.ps1"; } > "$(wslpath -u "$ps1_win")"
    nohup "$PS" -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "$ps1_win" -Dir "$work_dir_win" >/dev/null 2>&1 &
    ;;
  stop)
    pid_file="${2:?作業フォルダ}/player.pid"
    if [ -f "$pid_file" ]; then
      player_pid=$(tr -d '\r\n ' < "$pid_file")
      [ -n "$player_pid" ] && "$TASKKILL" /F /PID "$player_pid" >/dev/null 2>&1
      rm -f "$pid_file"
    fi
    ;;
  *)
    echo "usage: $0 workdir | start <dir> | stop <dir>" >&2
    exit 2
    ;;
esac
