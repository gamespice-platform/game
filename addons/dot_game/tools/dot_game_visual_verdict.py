#!/usr/bin/env python3
"""The post tools' gate on a judge verdict (dot_game_visual_judge.sh, docs/visual-judge-rubric.md).

  dot_game_visual_verdict.py VERDICT.json ITEM CLIP [--before]

Prints one tab-separated line and exits 0 when the clip may be posted:
  OK <good|wrong> <look text: the verdict and every defect with its nightly key>
or prints why it may not and exits 1. A clip may be posted when its fresh verdict says production_ready true, or
when every blocker/major defect it has carries a filed nightly key (the explicit open-defects list). --before (a
fix's before variant, the broken state by definition) needs a verdict but not filed keys. A clip with no verdict is
never posted.
"""
import json
import sys


def main() -> int:
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
    defects = v.get("defects", [])
    unfiled = [d for d in defects if d.get("severity") in ("blocker", "major") and not d.get("nightly")]
    ready = v.get("production_ready") is True
    if not ready and unfiled and not before:
        print("%s %s is not production ready and %d blocker/major defects have no nightly item: fix them and judge again, or run the judge with --give-up to file them"
              % (item, clip, len(unfiled)))
        return 1
    head = "JUDGE (round %s, fresh %s): %s. %s" % (verdict.get("round", "?"), verdict.get("judge_model", "?"),
                                                   "PRODUCTION READY" if ready else "NOT production ready",
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
