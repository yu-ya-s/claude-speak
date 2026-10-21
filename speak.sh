#!/usr/bin/env bash
# 直前の回答テキストを Edge の音声合成（七海）で合成し、操作バー付きの窓で読み上げる。
# 使い方: speak.sh <テキストファイル> [速さ -10..10]   /   speak.sh --stop
set -u
PS=$(command -v powershell.exe || echo /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe)
TASKKILL=$(command -v taskkill.exe || echo /mnt/c/Windows/System32/taskkill.exe)
PIDFILE=/tmp/claude-speak.pid
VOICE=ja-JP-NanamiNeural
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Windows 側の一時フォルダ（WSL パスと Windows パスの両方を持つ）
WIN_TEMP=$("$PS" -NoProfile -Command '$env:TEMP' 2>/dev/null | tr -d '\r')
if [ -z "$WIN_TEMP" ]; then echo "powershell.exe が見つかりません（WSL 専用）" >&2; exit 1; fi
WORK_DIR_WIN="$WIN_TEMP\\claude-speak"
WORK_DIR=$(wslpath -u "$WORK_DIR_WIN")

if [ "${1:-}" = "--stop" ]; then
  if [ -f "$PIDFILE" ]; then
    xargs -r kill 2>/dev/null < "$PIDFILE"
    rm -f "$PIDFILE"
  fi
  # 窓（player.ps1）の powershell だけを止める
  if [ -f "$WORK_DIR/player.pid" ]; then
    player_pid=$(tr -d '\r\n ' < "$WORK_DIR/player.pid")
    [ -n "$player_pid" ] && "$TASKKILL" /F /PID "$player_pid" >/dev/null 2>&1
    rm -f "$WORK_DIR/player.pid"
  fi
  echo "stopped"
  exit 0
fi

SRC="${1:?テキストファイルを指定}"
RATE="${2:-0}"

# 以前の読み上げを止めてから開始
"$0" --stop >/dev/null 2>&1

# 作業フォルダを空にして使う
mkdir -p "$WORK_DIR"
find "$WORK_DIR" -mindepth 1 -delete

# Markdown を話し言葉向けに整形し、文に分割して chunks.txt に書く
SUMMARY=$(python3 - "$SRC" "$WORK_DIR/chunks.txt" <<'PYEOF'
import re, sys
s = open(sys.argv[1], encoding='utf-8').read()
s = re.sub(r'```.*?```', '（コードは省略）', s, flags=re.S)       # コードブロック
s = re.sub(r'^\s*\|.*\|\s*$', '', s, flags=re.M)                     # 表
s = re.sub(r'^\s*[-*]{3,}\s*$', '', s, flags=re.M)                   # 区切り線
s = re.sub(r'`([^`]*)`', r'\1', s)                                   # インラインコード
s = re.sub(r'\[([^\]]+)\]\([^)]+\)', r'\1', s)                       # リンク
s = re.sub(r'https?://\S+', 'リンク', s)                             # 生URL
s = re.sub(r'^\s{0,3}#{1,6}\s*', '', s, flags=re.M)                  # 見出し
s = re.sub(r'^\s*[-*+]\s+', '', s, flags=re.M)                       # 箇条書き
s = re.sub(r'^\s*\d+\.\s+', '', s, flags=re.M)                       # 番号付き
s = re.sub(r'\*\*([^*]+)\*\*', r'\1', s)                             # 太字
s = re.sub(r'[ \t]+', ' ', s)
s = re.sub(r'\n{2,}', '\n', s).strip()

# 「。！？」と改行で文に分割（句点は文末に残す）
sentences = []
for line in s.split('\n'):
    sentences += re.findall(r'[^。！？!?]+[。！？!?]*|[。！？!?]+', line)

# 長い文は 80 文字程度で読点の位置で分割
max_len = 80
chunks = []
for sentence in sentences:
    sentence = sentence.strip()
    while len(sentence) > max_len:
        cut = sentence.rfind('、', 0, max_len)
        if cut <= 0:
            cut = max_len - 1
        chunks.append(sentence[:cut + 1])
        sentence = sentence[cut + 1:].strip()
    chunks.append(sentence)
chunks = [c for c in chunks if re.search(r'[^\s。！？!?、]', c)]

with open(sys.argv[2], 'w', encoding='utf-8', newline='\n') as f:
    f.write('\n'.join(chunks) + '\n')
print(len(s), len(chunks))
PYEOF
)
CHARS=${SUMMARY% *}
SENTENCES=${SUMMARY#* }
if [ "$SENTENCES" -eq 0 ]; then echo "nothing to speak"; exit 0; fi

SPEED=$(python3 -c "print(max(-10,min(10,int('$RATE'))))")

# 合成を先に走らせ、窓は生成済みチャンクから順に再生する
nohup "$SCRIPT_DIR/.venv/bin/python" "$SCRIPT_DIR/synth.py" "$WORK_DIR" "$VOICE" "$SPEED" >/dev/null 2>&1 &
echo $! > "$PIDFILE"

PS1_WIN="$WIN_TEMP\\claude-speak-player.ps1"
{ printf '\xEF\xBB\xBF'; cat "$SCRIPT_DIR/player.ps1"; } > "$(wslpath -u "$PS1_WIN")"
nohup "$PS" -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "$PS1_WIN" -Dir "$WORK_DIR_WIN" >/dev/null 2>&1 &
echo $! >> "$PIDFILE"
echo "speaking ($CHARS chars, $SENTENCES sentences, rate $RATE)"
