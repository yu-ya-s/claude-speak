#!/usr/bin/env bash
# 直前の回答テキストを文ごとに合成し、操作バー付きの窓で読み上げる。
# 使い方: speak.sh <テキストファイル> [速さ -10..10]   /   speak.sh --stop
#
# 構成: 本体（整形と文分割）→ synth/<SYNTH>.py（合成）→ player/<PLAYER>.sh（再生窓）
# OS ごとに違うのは player だけ。契約は docs/player-contract.md を参照
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PIDFILE=/tmp/claude-speak.pid

# 既定の設定（環境変数か、同じフォルダの config.env で上書きできる。config.env は git 管理外）
SYNTH=${SYNTH:-edge}
VOICE=${VOICE:-ja-JP-NanamiNeural}
PLAYER=${PLAYER:-}
if [ -f "$SCRIPT_DIR/config.env" ]; then . "$SCRIPT_DIR/config.env"; fi

# OS から再生窓の実装を選ぶ
if [ -z "$PLAYER" ]; then
  case "$(uname -s)" in
    Darwin) PLAYER=mac ;;
    Linux) if grep -qi microsoft /proc/version 2>/dev/null; then PLAYER=windows; else PLAYER=linux; fi ;;
    *) PLAYER=unknown ;;
  esac
fi
PLAYER_SH="$SCRIPT_DIR/player/$PLAYER.sh"
if [ ! -x "$PLAYER_SH" ]; then
  echo "この環境（$PLAYER）用の再生窓がありません。player/$PLAYER.sh を docs/player-contract.md の契約に沿って実装してください。" >&2
  exit 1
fi
WORK_DIR=$("$PLAYER_SH" workdir)

if [ "${1:-}" = "--stop" ]; then
  if [ -f "$PIDFILE" ]; then
    xargs -r kill 2>/dev/null < "$PIDFILE"
    rm -f "$PIDFILE"
  fi
  "$PLAYER_SH" stop "$WORK_DIR"
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

# 窓の見出しに出す作業ディレクトリ名（どのセッションの回答か分かるように）
printf '%s' "$(basename "$PWD")" > "$WORK_DIR/label.txt"

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
s = re.sub(r'\bi-[0-9a-f]{8,}\b', 'インスタンス', s)                  # EC2 のインスタンス ID
s = re.sub(r'\b(?=[0-9a-f]*[a-f])(?=[0-9a-f]*\d)[0-9a-f]{7,40}\b', 'コミット', s)  # コミットハッシュ
s = re.sub(r'(?<![\d/])(\d{4})/(1[0-2]|0?[1-9])/(3[01]|[12]\d|0?[1-9])(?![\d/])', r'\1年\2月\3日', s)  # 2026/10/22
s = re.sub(r'(?<![\d/])(1[0-2]|0?[1-9])/(3[01]|[12]\d|0?[1-9])(?![\d/])', r'\1月\2日', s)  # 10/20 → 10月20日
s = s.replace('→', ' から ')                                          # 矢印
s = re.sub(r'[ \t]+', ' ', s)
s = re.sub(r'\n{2,}', '\n', s).strip()

# 「。！？」と改行で文に分割（句点は文末に残す）
sentences = []
for line in s.split('\n'):
    sentences += re.findall(r'[^。！？!?]+[。！？!?]*|[。！？!?]+', line)

# 長い文は 120 文字程度で分割。切る位置は読点 → 中黒 → 空白の順で探し、単語の途中では切らない
max_len = 120
chunks = []
for sentence in sentences:
    sentence = sentence.strip()
    while len(sentence) > max_len:
        cut = -1
        for sep in ('、', '・', ' '):
            cut = sentence.rfind(sep, 1, max_len)
            if cut > 0:
                break
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
nohup "$SCRIPT_DIR/.venv/bin/python" "$SCRIPT_DIR/synth/$SYNTH.py" "$WORK_DIR" "$VOICE" "$SPEED" >/dev/null 2>&1 &
echo $! > "$PIDFILE"

"$PLAYER_SH" start "$WORK_DIR"
echo "speaking ($CHARS chars, $SENTENCES sentences, rate $RATE)"
