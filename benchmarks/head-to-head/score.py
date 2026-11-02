# Scores benchmark runs: python3 -I score.py <tag> [tag...]
# Reads bench/manifest.tsv, results/<tag>.tsv and results/<tag>/<id>.txt.
# Prints a summary per tag and writes results/score-<tag>.json.
import json
import os
import re
import statistics
import sys
from transformers.models.whisper.english_normalizer import EnglishTextNormalizer

B = os.path.dirname(os.path.abspath(__file__))
norm = EnglishTextNormalizer({})  # no British->American map; refs are American already
VOCAB = open(f"{B}/bench/words.txt").read().split()  # the 62 custom words


def rows(path):
    with open(path) as f:
        head = f.readline().rstrip("\n").split("\t")
        for line in f:
            yield dict(zip(head, line.rstrip("\n").split("\t")))


manifest = {r["id"]: r for r in rows(f"{B}/bench/manifest.tsv")}


def edits(ref, hyp):
    """Word-level edit distance split into (sub, del, ins)."""
    n, m = len(ref), len(hyp)
    d = [[(0, 0, 0, 0)] * (m + 1) for _ in range(n + 1)]  # (cost, s, d, i)
    for i in range(1, n + 1):
        d[i][0] = (i, 0, i, 0)
    for j in range(1, m + 1):
        d[0][j] = (j, 0, 0, j)
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            if ref[i - 1] == hyp[j - 1]:
                d[i][j] = d[i - 1][j - 1]
                continue
            c, s, dl, ins = d[i - 1][j - 1]
            sub = (c + 1, s + 1, dl, ins)
            c, s, dl, ins = d[i - 1][j]
            dele = (c + 1, s, dl + 1, ins)
            c, s, dl, ins = d[i][j - 1]
            insr = (c + 1, s, dl, ins + 1)
            d[i][j] = min(sub, dele, insr)
    return d[n][m][1:]


def words(t):
    return norm(t).split()


def has_word(text, w, case=True):
    return (
        re.search(
            r"(?<![\w-])" + re.escape(w) + r"(?![\w-])", text, 0 if case else re.I
        )
        is not None
    )


def wer_of(items):
    s = dl = ins = n = 0
    for ref, hyp in items:
        a, b, c = edits(words(ref), words(hyp))
        s += a
        dl += b
        ins += c
        n += len(words(ref))
    return {
        "wer": (s + dl + ins) / n if n else None,
        "sub": s,
        "del": dl,
        "ins": ins,
        "ref_words": n,
    }


def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(p * (len(xs) - 1))))] if xs else None


ASR_EDGE = {f"e{i:02d}" for i in range(3, 15)}  # plain speech under hard conditions
SILENT = {"e01", "e02"}


def score(tag):
    out = {"tag": tag, "blocks": {}, "clips": {}}
    runs = {
        r["id"]: r for r in rows(f"{B}/results/{tag}.tsv")
    }  # last run of an id wins
    by_block = {}
    for cid, r in runs.items():
        m = manifest[cid]
        p = f"{B}/results/{tag}/{cid}.txt"
        hyp = open(p).read().strip() if os.path.exists(p) else ""
        first = float(r["first"])
        clip = {
            "block": m["block"],
            "dur": float(r["dur"]),
            "first": first if first >= 0 else None,
            "final": float(r["final"]) if first >= 0 else None,
            "hyp": hyp,
            "ref": m["ref"],
            "note": m["note"],
        }
        if m["ref"]:
            e = edits(words(m["ref"]), words(hyp))
            n = len(words(m["ref"]))
            clip["wer"] = sum(e) / n if n else None
        if m["block"] == "names":
            terms = [t for t in m["terms"].split(",") if t]
            clip["terms"] = {
                t: has_word(hyp, t) for t in terms
            }  # exact spelling and case
            clip["terms_loose"] = {t: has_word(hyp, t, case=False) for t in terms}
        if m["block"] == "lookalike":
            clip["swaps"] = [
                w for w in VOCAB if has_word(hyp, w) and not has_word(m["ref"], w)
            ]
        out["clips"][cid] = clip
        by_block.setdefault(m["block"], []).append(cid)

    for block, ids in by_block.items():
        ids.sort()
        b: dict = {"n": len(ids)}
        lat = [
            out["clips"][i]["first"]
            for i in ids
            if out["clips"][i]["first"] is not None
        ]
        b["empty"] = sum(1 for i in ids if not out["clips"][i]["hyp"])
        b["lat_median"] = statistics.median(lat) if lat else None
        b["lat_p90"] = pct(lat, 0.9)
        scored = [
            i for i in ids if manifest[i]["ref"] and (block != "edge" or i in ASR_EDGE)
        ]
        b.update(wer_of([(manifest[i]["ref"], out["clips"][i]["hyp"]) for i in scored]))
        if block == "names":
            hits = [ok for i in ids for ok in out["clips"][i]["terms"].values()]
            b["term_recall"] = sum(hits) / len(hits)
            b["terms"] = len(hits)
            loose = [ok for i in ids for ok in out["clips"][i]["terms_loose"].values()]
            b["term_recall_loose"] = sum(loose) / len(loose)
        if block == "lookalike":
            b["false_swaps"] = sum(1 for i in ids if out["clips"][i]["swaps"])
        if block == "edge":
            b["silence_text"] = {
                i: out["clips"][i]["hyp"] for i in sorted(SILENT & set(ids))
            }
        out["blocks"][block] = b
    json.dump(
        out, open(f"{B}/results/score-{tag}.json", "w"), indent=1, ensure_ascii=False
    )
    return out


def fmt(x, p=1, pc=False):
    if x is None:
        return "-"
    return f"{x * 100:.{p}f}%" if pc else f"{x:.{p}f}"


for tag in sys.argv[1:]:
    o = score(tag)
    print(f"== {tag}")
    for block in ["normal", "names", "lookalike", "edge", "long"]:
        b = o["blocks"].get(block)
        if not b:
            continue
        extra = ""
        if "term_recall" in b:
            extra += f" recall={fmt(b['term_recall'], pc=True)} (any case {fmt(b['term_recall_loose'], pc=True)}) of {b['terms']}"
        if "false_swaps" in b:
            extra += f" swaps={b['false_swaps']}/{b['n']}"
        if "silence_text" in b:
            extra += " silence=" + ",".join(
                f"{k}:{len(v)}ch" for k, v in b["silence_text"].items()
            )
        print(
            f"{block:9} n={b['n']:2} WER={fmt(b['wer'], 2, True)} (S{b['sub']} D{b['del']} I{b['ins']} /{b['ref_words']})"
            f" lat med={fmt(b['lat_median'], 2)} p90={fmt(b['lat_p90'], 2)} empty={b['empty']}{extra}"
        )
