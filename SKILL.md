---
name: speak
description: 直前の回答を Windows の音声合成（日本語）で読み上げる。「/speak」「読み上げて」「声で聞かせて」と言われたら使う。「/speak stop」「読み上げ止めて」で停止。
---

# 直前の回答の読み上げ

## 手順

1. 引数が `stop`（または「止めて」）なら、`~/.claude/skills/speak/speak.sh --stop` を実行して「停止しました」とだけ返す
2. それ以外は、この会話で自分が直前に出した回答の本文（ユーザーに見せた文章そのまま。コードブロックや表は含めてよい、スクリプト側で省く）を、スクラッチパッド配下の `speak-last.txt` に Write で書き出す
   - 対象は直前の 1 回答のみ。ツール呼び出しの中身や思考は含めない
   - 引数に「ゆっくり」「はやく」があれば速さを -3 / +3 にする（既定 0）
3. `~/.claude/skills/speak/speak.sh <ファイルパス> <速さ>` を実行する（バックグラウンドで再生が始まり、すぐ戻る）
4. 返答は「読み上げ中（約N文字）。止めるときは /speak stop」の 1 行のあとに空行を挟み、手順 2 で書き出した直前の回答の本文をそのまま ``` のコードブロックで添える（/speak の返答が最新の回答になり、元の回答がコピーしづらくなるため。コードブロックなら端末のコピー操作で選べる）。本文は一字も変えず、要約や言い換えをしない

## 前提

- 構成は speak.sh（整形・文分割）→ synth/edge.py（合成）→ player/<os>.sh（再生窓）。合成は Edge の音声合成（Python パッケージ edge-tts、声は ja-JP-NanamiNeural）。本文は Microsoft のサーバーへ送られるのでオフラインでは動かない。`~/.claude/skills/speak/.venv` に edge-tts を入れてある（無ければ `python3 -m venv .venv && .venv/bin/pip install edge-tts`）
- speak.sh が文単位に分けて synth/edge.py で順に合成し、Windows の一時フォルダ `%TEMP%\claude-speak\` に `000.mp3` と長さ `000.dur` を書き出す。生成済みの文から順に再生する（1文目が出るまで 2〜3 秒）
- 再生は player/windows.ps1 の枠なしダーク窓（画面右下、ドラッグで移動可）。読んでいる文・進捗バー・5秒戻る／再生一時停止／5秒進む・右上の × で停止。全部読み終わると自動で閉じる
- 声を変えるときは同じフォルダの `config.env` に `VOICE=...` を書く（git 管理外）（一覧は `.venv/bin/edge-tts --list-voices`）
- 誤読する語は `~/.claude/skills/speak/dict.txt` に「語<TAB>読み」で1行追加する（音声だけ置換、窓の表示は元の文のまま）。ユーザーから「○○を△△と読んで」と言われたらこのファイルに追記する
