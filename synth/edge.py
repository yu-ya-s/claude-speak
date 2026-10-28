#!/usr/bin/env python3
"""chunks.txt の各行を Edge の音声合成（edge-tts）で順に合成し、NNN.mp3 と NNN.dur を書き出す。
使い方: synth.py <作業フォルダ> <声の名前> <速さ -10..10>"""
import asyncio
import os
import re
import sys

import edge_tts

# 誤読する語の読み替え辞書（1行「語<TAB>読み」。長い語から順に、英数字の語は単語単位で適用）
# dict.txt は公開用、dict.local.txt は人名など公開しない語を書く（git 管理外）
SKILL_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DICT_PATHS = [os.path.join(SKILL_DIR, "dict.txt"), os.path.join(SKILL_DIR, "dict.local.txt")]


def load_dict():
    """辞書を読み、長い語から順に並べて返す（短い語が長い語の一部を先に壊さないように）。
    英数字だけの語は単語の途中（adapter の apt など）に一致しないよう境界付きの正規表現にする"""
    pairs = []
    for dict_path in DICT_PATHS:
        if not os.path.exists(dict_path):
            continue
        with open(dict_path, encoding="utf-8") as f:
            for line in f:
                line = line.rstrip("\n")
                if not line.strip() or line.startswith("#") or "\t" not in line:
                    continue
                word, reading = line.split("\t", 1)
                if re.fullmatch(r"[\x21-\x7e]+", word):
                    pattern = re.compile(r"(?<![A-Za-z0-9])" + re.escape(word) + r"(?![A-Za-z0-9])")
                else:
                    pattern = re.compile(re.escape(word))
                pairs.append((word, reading, pattern))
    pairs.sort(key=lambda pair: len(pair[0]), reverse=True)
    return pairs


def apply_dict(sentence, pairs):
    for _word, reading, pattern in pairs:
        sentence = pattern.sub(reading, sentence)
    # 辞書に無い識別子のアンダースコアは空白にして単語ごとに読ませる（辞書の後でないと語が壊れる）
    sentence = re.sub(r"_+", " ", sentence)
    # 期間の「1日」は「いちにち」。日付の「10月1日」（ついたち）や「11日」は除く
    sentence = re.sub(r"(?<![月\d])1日", "いちにち", sentence)
    # 頻度の「月5回」は「つき」。日付の「10月5日」や「毎月5日」「今月5件」は除く
    sentence = re.sub(r"(?<![\d毎今先来翌前かカヶケ箇])月(?=\d)", "つき", sentence)
    return sentence


async def synth_one(sentence, voice, rate, mp3_path, dur_path):
    communicate = edge_tts.Communicate(sentence, voice, rate=rate)
    last_end = 0
    # 再生側が書きかけを掴まないよう、完成後にリネームする
    with open(mp3_path + ".tmp", "wb") as f:
        async for chunk in communicate.stream():
            if chunk["type"] == "audio":
                f.write(chunk["data"])
            elif chunk["type"] in ("WordBoundary", "SentenceBoundary"):
                last_end = max(last_end, chunk["offset"] + chunk["duration"])
    # 実時間はファイルからでは取りにくいので、単語境界の末尾（100ns 単位）＋末尾の間を使う
    with open(dur_path, "w") as f:
        f.write("%.3f" % (last_end / 10_000_000 + 0.1))
    os.replace(mp3_path + ".tmp", mp3_path)


async def main():
    work_dir, voice, rate = sys.argv[1], sys.argv[2], int(sys.argv[3])
    rate_text = "%+d%%" % (rate * 10)
    with open(os.path.join(work_dir, "chunks.txt"), encoding="utf-8") as f:
        sentences = [line.rstrip("\n") for line in f if line.strip()]
    pairs = load_dict()
    try:
        for i, sentence in enumerate(sentences):
            base = os.path.join(work_dir, "%03d" % i)
            await synth_one(apply_dict(sentence, pairs), voice, rate_text, base + ".mp3", base + ".dur")
    except Exception as e:
        with open(os.path.join(work_dir, "synth.log"), "a", encoding="utf-8") as f:
            f.write("synth error: %r\n" % (e,))
    finally:
        # 失敗しても done を置き、再生側が待ち続けないようにする
        open(os.path.join(work_dir, "done"), "w").close()


if __name__ == "__main__":
    asyncio.run(main())
