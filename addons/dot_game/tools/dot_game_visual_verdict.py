#!/usr/bin/env python3
"""The post tools' gate on a judge verdict (dot_game_visual_judge.sh, docs/visual-judge-rubric.md).

  dot_game_visual_verdict.py VERDICT.json ITEM CLIP [--before]
  dot_game_visual_verdict.py --audit VERDICT.json      (checks every clip's evidence and the streak; exit 0 = sound)

Prints one tab-separated line and exits 0 when the clip may be posted:
  OK <good|wrong> <look text: the verdict, the streak and every defect with its nightly key>
or prints why it may not and exits 1.

A clip is "good" only when the run's verdict is production_ready with at least 3 (passes_required) consecutive clean
fresh judge passes, and every pass's evidence holds: the judge's session id, a Read of every pack image, image
hashes that match the files, and a verdict.json identical to what the judge wrote. Anything hand-written or edited
fails here. A clip that is not ready may be posted as "wrong" only when every defect carries a filed nightly key.
--before (a fix's before variant, broken by definition) needs a verdict with sound evidence but not filed keys.
"""
import hashlib
import json
import os
import sys

MIN_PASSES = 3


def sha(path: str) -> str:
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


def check_pack(pack: str) -> list:
    """Why this pack's verdict is not backed by its judge (empty when it is)."""
    bad = []
    try:
        ev = json.load(open(os.path.join(pack, "evidence.json")))
    except (OSError, ValueError):
        return ["%s: no evidence.json (not judged by dot_game_visual_judge.sh)" % pack]
    if not ev.get("judge_session"):
        bad.append("%s: no judge session" % pack)
    try:
        if sha(os.path.join(pack, "verdict.json")) != ev.get("verdict_sha256"):
            bad.append("%s: verdict.json differs from what the judge wrote" % pack)
    except OSError:
        bad.append("%s: no verdict.json" % pack)
    images = ev.get("images") or {}
    if not images:
        bad.append("%s: no image hashes" % pack)
    reads = set(ev.get("reads") or [])
    for name, digest in images.items():
        p = os.path.join(pack, name)
        if not os.path.exists(p) or sha(p) != digest:
            bad.append("%s: %s changed since the judge saw it" % (pack, name))
        if name not in reads:
            bad.append("%s: the judge never read %s" % (pack, name))
    jl = os.path.join(pack, "judge.jsonl")
    if not os.path.exists(jl) or ev.get("judge_session") not in open(jl, errors="replace").read():
        bad.append("%s: judge.jsonl missing or not the judge's session" % pack)
    return bad


def audit(verdict: dict) -> list:
    """Why the run's production_ready claim does not hold (empty when it does)."""
    bad = []
    need = max(MIN_PASSES, int(verdict.get("passes_required") or 0))
    streak = verdict.get("streak") or []
    clean = 0
    variants = set()
    for s in streak:
        if not s.get("clean") or not s.get("clips"):
            break
        for c in s["clips"]:
            bad += check_pack(c.get("pack", ""))
            try:
                v = json.load(open(os.path.join(c.get("pack", ""), "verdict.json")))
                if v.get("production_ready") is not True or v.get("defects"):
                    bad.append("%s: pass %s is marked clean but its verdict is not" % (c.get("pack"), s.get("pass")))
            except (OSError, ValueError):
                bad.append("%s: unreadable verdict" % c.get("pack"))
        variants.add(s.get("variant"))
        clean += 1
    if clean < need:
        bad.append("only %d of %d consecutive clean fresh judge passes" % (clean, need))
    if len(variants) < min(clean, need):
        bad.append("the clean passes reuse a variant (each pass must see new phases, motion and angles)")
    sessions = [c.get("judge_session") for s in streak[:clean] for c in s.get("clips", [])]
    if len(sessions) != len(set(sessions)):
        bad.append("a judge session is reused across passes (each pass must be a fresh judge)")
    return bad


def main() -> int:
    if sys.argv[1:2] == ["--audit"]:
        verdict = json.load(open(sys.argv[2]))
        bad = audit(verdict) if verdict.get("production_ready") else []
        for it in verdict.get("items", []):
            bad += check_pack(it.get("pack", ""))
        print("\n".join(bad) if bad else "sound: %s" % sys.argv[2])
        return 1 if bad else 0
    path, item, clip = sys.argv[1:4]
    before = "--before" in sys.argv[4:]
    try:
        verdict = json.load(open(path))
    except (OSError, ValueError) as e:
        print("no judge verdict (%s): run addons/dot_game/tools/dot_game_visual_judge.sh first" % e)
        return 1
    rows = [v for v in verdict.get("items", []) if v.get("item") == item and v.get("clip") == clip]
    if not rows:
        print("%s has no verdict for %s %s: judge that clip first" % (path, item, clip))
        return 1
    v = rows[0]
    bad = check_pack(v.get("pack", ""))
    if bad:
        print("verdict for %s %s is not backed by a fresh judge: %s" % (item, clip, "; ".join(bad[:4])))
        return 1
    defects = v.get("defects", [])
    ready = verdict.get("production_ready") is True
    if ready:
        bad = audit(verdict)
        if bad:
            print("%s %s claims production_ready but the streak does not hold: %s" % (item, clip, "; ".join(bad[:4])))
            return 1
    unfiled = [d for d in defects if not d.get("nightly")]
    if not ready and unfiled and not before:
        print("%s %s is not production ready and %d defects have no nightly item: fix them and judge again, or run the judge with --give-up to file them"
              % (item, clip, len(unfiled)))
        return 1
    head = "JUDGE (round %s, fresh %s, %s/%s clean passes): %s. %s" % (
        verdict.get("round", "?"), verdict.get("judge_model", "?"), verdict.get("passes_clean", 0),
        verdict.get("passes_required", MIN_PASSES), "PRODUCTION READY" if ready else "NOT production ready",
        str(v.get("justification", "")).strip())
    parts = [head]
    for d in defects:
        parts.append("[%s %s %s%s] %s" % (d.get("id", "-"), d.get("severity", "?"), d.get("category", "?"),
                                          (" " + d["nightly"]) if d.get("nightly") else "", d.get("what", "")))
    look = " | ".join(parts).replace("\t", " ").replace("\n", " ")
    print("OK\t%s\t%s" % ("good" if ready else "wrong", look[:3000]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
