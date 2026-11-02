# Builds the dictation clips for the Purr / Wispr Flow / Superwhisper
# benchmark: 16 kHz mono WAVs in bench/clips plus bench/manifest.tsv (id, block,
# file, ref, terms, note), and the Voice Edit commands in edit/.
# usage: python3 -I build.py <LibriSpeech dir holding test-clean and test-other>
import csv
import json
import os
import random
import subprocess
import sys
import wave
import numpy as np

B = os.path.dirname(os.path.abspath(__file__))
OUT = f"{B}/bench"
CL = f"{OUT}/clips"
os.makedirs(CL, exist_ok=True)
LS = sys.argv[1]
rows = []


def run(*a):
    subprocess.run(a, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def to_wav(src, dst, extra=()):
    run(
        "ffmpeg",
        "-y",
        "-i",
        src,
        *extra,
        "-ar",
        "16000",
        "-ac",
        "1",
        "-sample_fmt",
        "s16",
        dst,
    )


def read(p):
    with wave.open(p) as w:
        return (
            np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(
                np.float32
            )
            / 32768
        )


def write(p, x):
    x = np.clip(x, -1, 1)
    with wave.open(p, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes((x * 32767).astype(np.int16).tobytes())


def rms(x):
    return float(np.sqrt(np.mean(x**2)) + 1e-9)


def say(text, dst, voice="Samantha", rate=None):
    aiff = dst[:-4] + ".aiff"
    run("say", "-v", voice, *(["-r", str(rate)] if rate else []), "-o", aiff, text)
    to_wav(aiff, dst)
    os.remove(aiff)


def add(id, block, path, ref, terms="", note=""):
    rows.append(
        dict(
            id=id,
            block=block,
            file=os.path.basename(path),
            ref=ref,
            terms=terms,
            note=note,
        )
    )


# LibriSpeech utterances with durations and transcripts.
def utterances(subset):
    out = []
    for spk in sorted(os.listdir(f"{LS}/{subset}")):
        for ch in sorted(os.listdir(f"{LS}/{subset}/{spk}")):
            d = f"{LS}/{subset}/{spk}/{ch}"
            for line in open(f"{d}/{spk}-{ch}.trans.txt"):
                uid, text = line.strip().split(" ", 1)
                out.append(
                    dict(
                        uid=uid,
                        spk=spk,
                        ch=ch,
                        path=f"{d}/{uid}.flac",
                        text=text.lower(),
                    )
                )
    return out


def dur(p):
    r = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "csv=p=0",
            p,
        ],
        capture_output=True,
        text=True,
    )
    return float(r.stdout.strip())


rng = random.Random(7)
picked = {}
for subset, n in (("test-clean", 13), ("test-other", 12)):
    us = utterances(subset)
    rng.shuffle(us)
    seen = set()
    k = 0
    for u in us:
        if u["spk"] in seen or len(u["text"].split()) < 10:
            continue
        d = dur(u["path"])
        if not 4.5 <= d <= 9:
            continue
        seen.add(u["spk"])
        k += 1
        dst = f"{CL}/n{len(rows) + 1:02d}-{subset}.wav"
        to_wav(u["path"], dst)
        add(
            f"n{len(rows) + 1:02d}",
            "normal",
            dst,
            u["text"],
            note=f"{subset} {u['uid']} {d:.1f}s",
        )
        picked[u["uid"]] = u
        if k == n:
            break

# Names and jargon: 54 sentences using the 62 words in words.txt (p01-p54), and
# 16 sentences with a sound-alike everyday phrase instead (n01-n16).
for line in open(f"{OUT}/names.tsv"):
    lid, terms, text = line.rstrip("\n").split("\t")
    dst = f"{CL}/v-{lid}.wav"
    say(text, dst)
    add(f"v-{lid}", "names" if lid.startswith("p") else "lookalike", dst, text, terms)

# Edge cases.
clean = [u for u in utterances("test-clean") if u["uid"] not in picked]
rng.shuffle(clean)


def libri(i, min_d=5, max_d=9):
    for u in clean[i * 40 :]:
        if min_d <= dur(u["path"]) <= max_d and len(u["text"].split()) >= 10:
            return u
    raise SystemExit(f"no test-clean utterance of {min_d}-{max_d} s left")


E = []
write(f"{CL}/e01.wav", np.zeros(16000 * 3))
add("e01", "edge", f"{CL}/e01.wav", "", note="3 s of silence, key held")
write(f"{CL}/e02.wav", np.zeros(16000 * 1))
add("e02", "edge", f"{CL}/e02.wav", "", note="1 s tap, no speech")
for i, (t, n) in enumerate(
    [("Yes.", "one word"), ("Okay, sounds good.", "short reply"), ("No.", "one word")],
    3,
):
    p = f"{CL}/e{i:02d}.wav"
    say(t, p)
    add(f"e{i:02d}", "edge", p, t, note=n)
for i, db in ((6, -28), (7, -34)):
    u = libri(i)
    p = f"{CL}/e{i:02d}.wav"
    to_wav(u["path"], p, ("-af", f"volume={db}dB"))
    add(f"e{i:02d}", "edge", p, u["text"], note=f"quiet speech ({db} dB)")
u = libri(8)
p = f"{CL}/e08.wav"
to_wav(u["path"], p)
x = read(p)
bab = np.zeros_like(x)
for j in range(3):
    o = libri(20 + j, 6, 30)
    tmp = f"{CL}/tmp.wav"
    to_wav(o["path"], tmp)
    y = read(tmp)
    os.remove(tmp)
    y = np.resize(y, len(x))
    bab += y / rms(y)
bab *= rms(x) / rms(bab) / (10 ** (5 / 20))
write(p, (x + bab) * 0.7)
add("e08", "edge", p, u["text"], note="babble of 3 talkers, 5 dB SNR")
u = libri(9)
p = f"{CL}/e09.wav"
to_wav(u["path"], p)
x = read(p)
pink = np.cumsum(np.random.default_rng(1).standard_normal(len(x)))
pink -= np.convolve(pink, np.ones(400) / 400, "same")
pink *= rms(x) / rms(pink) / (10 ** (5 / 20))
write(p, (x + pink) * 0.7)
add("e09", "edge", p, u["text"], note="noise, 5 dB SNR")
said = [
    (
        "e10",
        "The quarterly numbers came in higher than expected, so we are moving the launch up by two weeks.",
        "Samantha",
        290,
        "fast speech",
    ),
    (
        "e11",
        "I think we should [[slnc 3000]] move the meeting to Thursday afternoon.",
        "Samantha",
        None,
        "3 s pause mid-sentence",
    ),
    (
        "e12",
        "Please book a cab to the airport for six thirty tomorrow morning.",
        "Rishi",
        None,
        "Indian English voice",
    ),
    (
        "e13",
        "The new pricing page goes live after the board approves it.",
        "Moira",
        None,
        "Irish English voice",
    ),
    (
        "e14",
        "Can you check whether the invoice was paid last Tuesday?",
        "Karen",
        None,
        "Australian English voice",
    ),
    (
        "e15",
        "Send twenty five dollars to john dot smith at gmail dot com by March third at four thirty p m.",
        "Samantha",
        None,
        "money, email, date, time",
    ),
    (
        "e16",
        "Revenue grew seventeen point five percent to three point two million dollars in Q3.",
        "Samantha",
        None,
        "percent, decimals",
    ),
    (
        "e17",
        "Call me at five five five, zero one four two on June twelfth, twenty twenty six.",
        "Samantha",
        None,
        "phone number, date",
    ),
    (
        "e18",
        "Hi Sarah comma new line thanks for the update period",
        "Samantha",
        None,
        "spoken punctuation",
    ),
    (
        "e19",
        "So um I think we should uh we should probably move the the launch to next week.",
        "Samantha",
        None,
        "fillers and repeats",
    ),
    (
        "e20",
        "Let's meet on Tuesday, no wait, Wednesday at ten.",
        "Samantha",
        None,
        "self-correction",
    ),
    (
        "e21",
        "This damn printer jammed again, what the hell.",
        "Samantha",
        None,
        "mild swearing",
    ),
    (
        "e22",
        "Run npm install dash dash save dev typescript, then open the readme dot md file.",
        "Samantha",
        None,
        "command line",
    ),
    ("e23", "कल सुबह दस बजे मीटिंग है।", "Lekha", None, "Hindi"),
    ("e24", "Mañana tenemos una reunión a las diez.", "Paulina", None, "Spanish"),
]
for id, text, voice, rate, note in said:
    p = f"{CL}/{id}.wav"
    say(text, p, voice, rate)
    add(id, "edge", p, text.replace("[[slnc 3000]] ", ""), note=note)


# Long dictation: consecutive utterances of one test-clean chapter.
def chapter_run(target_s, tag):
    by_ch = {}
    for u in utterances("test-clean"):
        by_ch.setdefault((u["spk"], u["ch"]), []).append(u)
    for key in sorted(by_ch, key=lambda k: -len(by_ch[k])):
        us = sorted(by_ch[key], key=lambda u: u["uid"])
        parts = []
        texts = []
        total = 0
        for u in us:
            if u["uid"] in picked:
                continue
            tmp = f"{CL}/tmp-{len(parts)}.wav"
            to_wav(u["path"], tmp)
            parts.append(read(tmp))
            os.remove(tmp)
            texts.append(u["text"])
            total += len(parts[-1]) / 16000 + 0.4
            if total >= target_s:
                break
        if total >= target_s:
            gap = np.zeros(int(16000 * 0.4))
            x = np.concatenate([np.concatenate([p, gap]) for p in parts])
            p = f"{CL}/{tag}.wav"
            write(p, x)
            for u in us:
                picked[u["uid"]] = u
            return p, " ".join(texts), total
    raise SystemExit(f"no test-clean chapter reaches {target_s} s")


l1 = chapter_run(90, "l01")
add("l01", "long", l1[0], l1[1], note=f"{l1[2]:.0f} s, one speaker")
l2 = chapter_run(300, "l02")
add("l02", "long", l2[0], l2[1], note=f"{l2[2]:.0f} s, one speaker (local apps only)")

with open(f"{OUT}/manifest.tsv", "w", newline="") as f:
    w = csv.DictWriter(
        f,
        fieldnames=["id", "block", "file", "ref", "terms", "note"],
        delimiter="\t",
        quoting=csv.QUOTE_MINIMAL,
    )
    w.writeheader()
    w.writerows(rows)

# Voice Edit commands, read by Samantha with 300 ms of silence on each side.
for r in csv.DictReader(open(f"{B}/edit/cases.tsv"), delimiter="\t"):
    dst = f"{B}/edit/{r['id']}.wav"
    aiff = dst[:-4] + ".aiff"
    run("say", "-v", "Samantha", "-o", aiff, r["command"])
    to_wav(aiff, dst, ("-af", "adelay=300|300,apad=pad_dur=0.3"))
    os.remove(aiff)

blocks = {}
for r in rows:
    blocks.setdefault(r["block"], [0, 0])
    blocks[r["block"]][0] += 1
    blocks[r["block"]][1] += len(r["ref"].split())
print(json.dumps(blocks))
