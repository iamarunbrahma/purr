# Scores multilingual runs: python3 -I score_multi.py <tag> [tag...]
# WER for space-separated languages, CER for ja/zh/ko, plus a check that the
# output is in the spoken language (not English, not another script).
import json
import os
import re
import sys
import unicodedata
from transformers.models.whisper.english_normalizer import BasicTextNormalizer

B = os.path.dirname(os.path.abspath(__file__))
norm = BasicTextNormalizer()
CJK = {"ja", "zh", "ko"}
SCRIPT = {
    "ru": "CYRILLIC",
    "hi": "DEVANAGARI",
    "ar": "ARABIC",
    "ja": "CJK|HIRAGANA|KATAKANA",
    "zh": "CJK",
    "ko": "HANGUL",
}


def rows(p):
    with open(p) as f:
        head = f.readline().rstrip("\n").split("\t")
        for line in f:
            yield dict(zip(head, line.rstrip("\n").split("\t")))


def dist(a, b):
    d = list(range(len(b) + 1))
    for i in range(1, len(a) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(b) + 1):
            prev, d[j] = (
                d[j],
                min(d[j] + 1, d[j - 1] + 1, prev + (a[i - 1] != b[j - 1])),
            )
    return d[len(b)]


def units(text, lang):
    t = norm(text)
    return list(t.replace(" ", "")) if lang in CJK else t.split()


def right_language(hyp, lang):
    letters = [c for c in hyp if c.isalpha()]
    if not letters:
        return False
    if lang in SCRIPT:
        hit = sum(
            1 for c in letters if re.search(SCRIPT[lang], unicodedata.name(c, ""))
        )
        return hit / len(letters) > 0.6
    latin = sum(1 for c in letters if "LATIN" in unicodedata.name(c, ""))
    english = len(
        re.findall(
            r"\b(the|and|to|of|you|please|send|meeting|tomorrow|we)\b", hyp, re.I
        )
    )
    return latin / len(letters) > 0.9 and english < 2


man = {r["id"]: r for r in rows(f"{B}/bench/multi.tsv")}
for tag in sys.argv[1:]:
    runs = {r["id"]: r for r in rows(f"{B}/results/{tag}.tsv")}
    out, by_lang = {}, {}
    for cid, m in man.items():
        if cid not in runs:
            continue
        p = f"{B}/results/{tag}/{cid}.txt"
        hyp = open(p).read().strip() if os.path.exists(p) else ""
        lang = m["terms"]
        ref_u, hyp_u = units(m["ref"], lang), units(hyp, lang)
        err = dist(ref_u, hyp_u)
        ok = right_language(hyp, lang)
        f = float(runs[cid]["first"])
        out[cid] = {
            "lang": lang,
            "ref": m["ref"],
            "hyp": hyp,
            "err": err,
            "n": len(ref_u),
            "right_language": ok,
            "first": f if f >= 0 else None,
        }
        e = by_lang.setdefault(lang, [0, 0, 0, 0])
        e[0] += err
        e[1] += len(ref_u)
        e[2] += ok
        e[3] += 1
    json.dump(
        out, open(f"{B}/results/score-{tag}.json", "w"), indent=1, ensure_ascii=False
    )
    errs = sum(v[0] for v in by_lang.values())
    n = sum(v[1] for v in by_lang.values())
    rl = sum(v[2] for v in by_lang.values())
    clips = sum(v[3] for v in by_lang.values())
    print(
        f"== {tag}: overall error {errs / n:.1%} (WER/CER), right language {rl}/{clips}"
    )
    print(
        "   "
        + "  ".join(
            f"{l}:{e / k:.0%}{'' if r == c else '!'}"
            for l, (e, k, r, c) in by_lang.items()
        )
    )
