#!/usr/bin/env python3
"""chunks.txt の各行を Edge の音声合成（edge-tts）で順に合成し、NNN.mp3 と NNN.dur を書き出す。
使い方: synth.py <作業フォルダ> <声の名前> <速さ -10..10>"""
import asyncio
import os
import sys

import edge_tts

# 誤読する語の読み替え辞書（dict.txt：1行「語<TAB>読み」。上の行から順に適用）
DICT_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "dict.txt")


def load_dict():
    pairs = []
    if not os.path.exists(DICT_PATH):
        return pairs
    with open(DICT_PATH, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.strip() or line.startswith("#") or "\t" not in line:
                continue
            word, reading = line.split("\t", 1)
            pairs.append((word, reading))
    return pairs


def apply_dict(sentence, pairs):
    for word, reading in pairs:
        sentence = sentence.replace(word, reading)
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
