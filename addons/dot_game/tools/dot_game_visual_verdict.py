#!/usr/bin/env python3
"""The post tools' gate on a judge verdict (dot_game_visual_judge.sh, docs/visual-judge-rubric.md).

  dot_game_visual_verdict.py VERDICT.json ITEM CLIP [--before] [--mp4 CLIP.mp4]
  dot_game_visual_verdict.py --audit VERDICT.json   every clip of the run; exit 0 only when all are production ready
  dot_game_visual_verdict.py --pack PACK_DIR        one judge pack's evidence (the judge runs it after each judge)

Prints one tab-separated line and exits 0 when the clip may be posted:
  OK <good|wrong> <look text: the verdict, the streak and every defect with its nightly key>
or prints why it may not and exits 1 (2 on a usage error).

Nothing in the run's verdict.json is trusted on its own. The answer is derived from the judge packs on disk,
<run dir>/pass<k>/<item>/<clip>/, each holding the judge's verdict.json, evidence.json and judge.jsonl:
- a pack is sound when its verdict is the file the judge wrote, every image is the one the judge Read, the capture
  log named a GPU (never llvmpipe), and the judge's own Claude transcript (in the judge account's CLAUDE_CONFIG_DIR,
  owned by the user the judge ran as, not by the author who owns the pack) shows the same Reads, the same Write
  of verdict.json and the pack as its working directory. A hand-written, edited or copied pack fails;
- a clip is "good" only when passes 1..N (N >= 3) all hold a sound pack for it from the same round, on variants
  0..N-1, each by a different judge session, each with production_ready true and zero defects;
- a clip that is not ready is "wrong", and may be posted only when every defect of its last pack carries a nightly
  key that exists and whose notes name that pack's judge session (dot_game_visual_judge.sh --give-up files them);
- --before (a fix's before variant, broken by definition) needs a sound last pack, not filed keys;
- --mp4 must be the very file the last pack judged (sha256), so a different clip cannot ride on a verdict.

VISUAL_JUDGE_TRANSCRIPTS (colon-separated globs of Claude projects dirs, default /home/christian/.claude*/projects)
is for the self-test only: with it set, the transcript owner check is skipped and every OK says "test transcripts".
The post tools unset it. Anyone with root can still forge all of this; the gate stops an author, not root.
"""
import glob
import hashlib
import json
import os
import pwd
import re
import subprocess
import sys

MIN_PASSES = 3
SOFTWARE = re.compile(r"llvmpipe|softpipe|lavapipe|swiftshader|software rasterizer", re.I)
SID = re.compile(r"^[0-9a-fA-F-]{8,64}$")
DEFAULT_ROOTS = "/home/christian/.claude*/projects"
NIGHTLY = os.environ.get("NIGHTLY", "/home/core/stack/nightly/bin/nightly")


def sha(path: str) -> str:
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def load(path: str):
    """A JSON object from path, or None."""
    try:
        with open(path, errors="replace") as f:
            j = json.load(f)
        return j if isinstance(j, dict) else None
    except (OSError, ValueError):
        return None


def test_roots() -> bool:
    return bool(os.environ.get("VISUAL_JUDGE_TRANSCRIPTS"))


def transcript(sid: str):
    """(path, owner uid, text) of the judge session's Claude transcript, or (None, None, why)."""
    if not SID.match(sid or ""):
        return None, None, "judge session id %r is not a Claude session id" % sid
    roots = (os.environ.get("VISUAL_JUDGE_TRANSCRIPTS") or DEFAULT_ROOTS).split(":")
    for root in roots:
        for p in glob.glob(os.path.join(root, "*", sid + ".jsonl")):
            try:
                with open(p, errors="replace") as f:
                    return p, os.stat(p).st_uid, f.read()
            except OSError:
                pass
    if test_roots():
        return None, None, "no transcript %s.jsonl under %s" % (sid, ":".join(roots))
    # The judge account's config dir is not readable by the author: read it as the user that owns it.
    owners = sorted({os.stat(r).st_uid for root in roots for r in glob.glob(root.rsplit("/", 1)[0]) if os.path.exists(r)})
    for uid in owners:
        try:
            user = pwd.getpwuid(uid).pw_name
        except KeyError:
            continue
        if user == pwd.getpwuid(os.getuid()).pw_name:
            continue
        code = ("import glob,os,sys\nfor r in sys.argv[2:]:\n for p in glob.glob(os.path.join(r,'*',sys.argv[1]+'.jsonl')):\n"
                "  sys.stdout.write('%s\\t%d\\n' % (p, os.stat(p).st_uid)); sys.stdout.write(open(p, errors='replace').read()); sys.exit(0)\nsys.exit(1)")
        try:
            r = subprocess.run(["sudo", "-n", "-u", user, "python3", "-c", code, sid] + roots,
                               capture_output=True, text=True, timeout=60)
        except (OSError, subprocess.TimeoutExpired) as e:
            return None, None, "cannot read the judge transcript as %s: %s" % (user, e)
        if r.returncode == 0 and "\n" in r.stdout:
            head, text = r.stdout.split("\n", 1)
            p, uid_s = head.rsplit("\t", 1)
            return p, int(uid_s), text
    return None, None, "no Claude transcript %s.jsonl under %s (the judge must run in the judge account)" % (sid, ":".join(roots))


def transcript_facts(text: str):
    """The cwd, the absolute paths Read and the sha256 of each Write of verdict.json in a transcript."""
    cwd, reads, writes = None, set(), []
    for line in text.splitlines():
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if not isinstance(e, dict):
            continue
        cwd = cwd or e.get("cwd")
        msg = e.get("message") if e.get("type") == "assistant" else None
        for c in (msg or {}).get("content") or [] if isinstance(msg, dict) else []:
            if not isinstance(c, dict) or c.get("type") != "tool_use" or not isinstance(c.get("input"), dict):
                continue
            path = str(c["input"].get("file_path", ""))
            if c.get("name") == "Read":
                reads.add(os.path.realpath(path))
            elif c.get("name") == "Write" and os.path.basename(path) == "verdict.json":
                writes.append((os.path.realpath(path), hashlib.sha256(str(c["input"].get("content", "")).encode()).hexdigest()))
    return cwd, reads, writes


def check_pack(pack: str) -> list:
    """Why this pack's verdict is not backed by its judge (empty when it is)."""
    pack = os.path.realpath(pack or "")
    ev = load(os.path.join(pack, "evidence.json"))
    if ev is None:
        return ["%s: no readable evidence.json (not judged by dot_game_visual_judge.sh)" % pack]
    bad = []
    sid = str(ev.get("judge_session") or "")
    if not sid:
        bad.append("%s: no judge session" % pack)
    try:
        have = sha(os.path.join(pack, "verdict.json"))
        if have != ev.get("verdict_sha256"):
            bad.append("%s: verdict.json differs from what the judge wrote" % pack)
    except OSError:
        have = None
        bad.append("%s: no verdict.json" % pack)
    if load(os.path.join(pack, "verdict.json")) is None:
        bad.append("%s: verdict.json is not a JSON object" % pack)
    images = ev.get("images") if isinstance(ev.get("images"), dict) else {}
    if not images:
        bad.append("%s: no image hashes" % pack)
    reads = set(str(r) for r in ev.get("reads") or [] if isinstance(r, str))
    for name, digest in images.items():
        p = os.path.join(pack, name)
        try:
            same = sha(p) == digest
        except OSError:
            same = False
        if not same:
            bad.append("%s: %s changed since the judge saw it" % (pack, name))
        if name not in reads:
            bad.append("%s: the judge never read %s" % (pack, name))
    try:
        with open(os.path.join(pack, "judge.jsonl"), errors="replace") as f:
            if not sid or sid not in f.read():
                bad.append("%s: judge.jsonl is not the judge's session" % pack)
    except OSError:
        bad.append("%s: no judge.jsonl" % pack)
    renderer = str(ev.get("renderer") or "")
    if not renderer or SOFTWARE.search(renderer):
        bad.append("%s: no GPU renderer on record (%r): the capture must name a GPU, never llvmpipe" % (pack, renderer))
    for k in ("item", "clip", "mp4_sha256"):
        if not ev.get(k):
            bad.append("%s: evidence has no %s" % (pack, k))
    if bad or not sid:
        return bad
    # The anchor: the judge's own Claude transcript, which the pack's author cannot write.
    path, uid, text = transcript(sid)
    if path is None:
        return ["%s: %s" % (pack, text)]
    if not test_roots() and uid == os.stat(os.path.join(pack, "evidence.json")).st_uid:
        bad.append("%s: the judge transcript %s belongs to the pack's author (run the judge in the judge account)" % (pack, path))
    cwd, treads, writes = transcript_facts(text)
    if os.path.realpath(cwd or "/nonexistent") != pack:
        bad.append("%s: the judge transcript ran in %s, not in this pack" % (pack, cwd))
    if not writes or writes[-1] != (os.path.join(pack, "verdict.json"), have):
        bad.append("%s: the judge transcript did not write this verdict.json" % pack)
    unread = sorted(n for n in images if os.path.join(pack, n) not in treads)
    if unread:
        bad.append("%s: the judge transcript never Read %s" % (pack, ", ".join(unread[:5])))
    return bad


def clean(v) -> bool:
    return isinstance(v, dict) and v.get("production_ready") is True and not v.get("defects")


def clip_state(run: str, item: str, clip: str) -> dict:
    """Everything the gate needs about one clip, derived from its packs."""
    packs = []
    k = 1
    while os.path.isdir(os.path.join(run, "pass%d" % k, item, clip)):
        packs.append(os.path.realpath(os.path.join(run, "pass%d" % k, item, clip)))
        k += 1
    st = {"item": item, "clip": clip, "packs": packs, "bad": [], "ready": False, "passes_clean": 0, "need": MIN_PASSES,
          "last": packs[-1] if packs else None, "verdict": None, "evidence": None}
    if not packs:
        st["bad"].append("no judge pack for %s %s under %s/pass1: judge that clip first" % (item, clip, run))
        return st
    evs, sessions, rounds = [], set(), set()
    for i, p in enumerate(packs):
        bad = check_pack(p)
        st["bad"] += bad
        ev = load(os.path.join(p, "evidence.json")) or {}
        v = load(os.path.join(p, "verdict.json"))
        evs.append(ev)
        if ev.get("item") != item or ev.get("clip") != clip:
            st["bad"].append("%s: judged %s %s, not %s %s" % (p, ev.get("item"), ev.get("clip"), item, clip))
        if str(ev.get("variant")) != str(i):
            st["bad"].append("%s: pass %d ran variant %s (each pass must see variant pass-1)" % (p, i + 1, ev.get("variant")))
        sessions.add(ev.get("judge_session"))
        rounds.add(ev.get("round"))
        if i == len(packs) - 1:
            st["verdict"], st["evidence"] = v, ev
        if not bad and clean(v) and st["passes_clean"] == i:
            st["passes_clean"] = i + 1
    try:
        st["need"] = max(MIN_PASSES, int(evs[0].get("passes_required") or 0))
    except (TypeError, ValueError):
        pass
    if len(rounds) != 1:
        st["bad"].append("%s %s: the packs come from different rounds %s (a round clears its packs first)" % (item, clip, sorted(map(str, rounds))))
    if len(sessions) != len(packs):
        st["bad"].append("%s %s: a judge session is reused across passes (each pass must be a fresh judge)" % (item, clip))
    st["ready"] = not st["bad"] and st["passes_clean"] == len(packs) >= st["need"]
    return st


def nightly(*args):
    cmd = [NIGHTLY] if pwd.getpwuid(os.getuid()).pw_name == "core" or os.environ.get("NIGHTLY") else ["sudo", "-n", "-u", "core", NIGHTLY]
    try:
        return subprocess.run(cmd + list(args), capture_output=True, text=True, timeout=90)
    except (OSError, subprocess.TimeoutExpired) as e:
        return subprocess.CompletedProcess(cmd, 1, "", str(e))


def unfiled(run_verdict: dict, st: dict) -> list:
    """The last pack's defects with no nightly key that names that pack's judge session."""
    defects = (st["verdict"] or {}).get("defects") or []
    rows = [it for it in run_verdict.get("items") or [] if isinstance(it, dict)
            and it.get("item") == st["item"] and it.get("clip") == st["clip"] and os.path.realpath(str(it.get("pack", ""))) == st["last"]]
    keyed = (rows[0].get("defects") if rows else None) or []
    sid = str((st["evidence"] or {}).get("judge_session"))
    out, seen = [], {}
    for i, d in enumerate(defects):
        key = keyed[i].get("nightly") if i < len(keyed) and isinstance(keyed[i], dict) else None
        if not key or not isinstance(key, str):
            out.append("defect %d (%s) has no nightly key" % (i + 1, (d or {}).get("category", "?") if isinstance(d, dict) else "?"))
            continue
        if key not in seen:
            r = nightly("show", key)
            seen[key] = r.returncode == 0 and sid in r.stdout
        if not seen[key]:
            out.append("nightly %s does not exist or does not name judge session %s" % (key, sid))
    return out


def look_text(run_verdict: dict, st: dict, ready: bool) -> str:
    v = st["verdict"] or {}
    head = "JUDGE (round %s, fresh %s, %d/%d clean passes): %s. %s" % (
        (st["evidence"] or {}).get("round", "?"), (st["evidence"] or {}).get("judge_model", "?"), st["passes_clean"], st["need"],
        "PRODUCTION READY" if ready else "NOT production ready", str(v.get("justification", "")).strip())
    parts = [head]
    rows = [it for it in run_verdict.get("items") or [] if isinstance(it, dict) and it.get("item") == st["item"] and it.get("clip") == st["clip"]]
    keyed = (rows[0].get("defects") if rows else None) or []
    for i, d in enumerate(v.get("defects") or []):
        d = d if isinstance(d, dict) else {"what": str(d)}
        key = keyed[i].get("nightly") if i < len(keyed) and isinstance(keyed[i], dict) else ""
        parts.append("[%s %s %s%s] %s" % (d.get("id", "-"), d.get("severity", "?"), d.get("category", "?"), (" " + str(key)) if key else "", d.get("what", "")))
    if test_roots():
        parts.append("(test transcripts: not a real verdict)")
    return " | ".join(parts).replace("\t", " ").replace("\n", " ")


def audit(path: str) -> int:
    run = os.path.dirname(os.path.realpath(path))
    verdict = load(path)
    if verdict is None:
        print("UNSOUND: %s is missing or not a JSON object" % path)
        return 1
    clips = [(str(it.get("item")), str(it.get("clip"))) for it in verdict.get("items") or [] if isinstance(it, dict)]
    if not clips:
        print("UNSOUND: %s lists no clips" % path)
        return 1
    ready_all, lines = True, []
    for item, clip in sorted(set(clips)):
        st = clip_state(run, item, clip)
        if st["bad"]:
            ready_all = False
            lines.append("UNSOUND %s %s: %s" % (item, clip, "; ".join(st["bad"][:4])))
        elif not st["ready"]:
            ready_all = False
            lines.append("NOT READY %s %s: %d/%d consecutive clean passes, %d defects in the last" % (
                item, clip, st["passes_clean"], st["need"], len((st["verdict"] or {}).get("defects") or [])))
        else:
            lines.append("ready %s %s: %d clean passes" % (item, clip, st["passes_clean"]))
    if verdict.get("production_ready") is True and not ready_all:
        lines.append("verdict.json claims production_ready but its packs do not hold it up")
    print("\n".join(lines))
    print(("sound: PRODUCTION READY (%d clips)%s" % (len(set(clips)), " (test transcripts: not a real verdict)" if test_roots() else ""))
          if ready_all else "NOT production ready: %s" % path)
    return 0 if ready_all else 1


def main(argv) -> int:
    if argv[:1] == ["--audit"] and len(argv) == 2:
        return audit(argv[1])
    if argv[:1] == ["--pack"] and len(argv) == 2:
        bad = check_pack(argv[1])
        print("\n".join(bad) if bad else "sound pack: %s" % argv[1])
        return 1 if bad else 0
    pos, before, mp4 = [], False, None
    i = 0
    while i < len(argv):
        if argv[i] == "--before":
            before = True
        elif argv[i] == "--mp4" and i + 1 < len(argv):
            mp4 = argv[i + 1]
            i += 1
        else:
            pos.append(argv[i])
        i += 1
    if len(pos) != 3:
        print(__doc__.strip().split("\n\n")[0])
        return 2
    path, item, clip = pos
    verdict = load(path)
    if verdict is None:
        print("no judge verdict at %s: run addons/dot_game/tools/dot_game_visual_judge.sh first" % path)
        return 1
    st = clip_state(os.path.dirname(os.path.realpath(path)), item, clip)
    if st["bad"]:
        print("verdict for %s %s is not backed by fresh judges: %s" % (item, clip, "; ".join(st["bad"][:4])))
        return 1
    if mp4 is not None:
        try:
            same = sha(mp4) == st["evidence"].get("mp4_sha256")
        except OSError:
            same = False
        if not same:
            print("%s is not the clip the judge saw for %s %s (sha256 differs): judge the clip you post" % (mp4, item, clip))
            return 1
    ready = st["ready"]
    if not ready and not before:
        if not (st["verdict"] or {}).get("defects"):
            print("%s %s has %d/%d clean passes and no defects on record: run the judge until it exits 0" % (item, clip, st["passes_clean"], st["need"]))
            return 1
        missing = unfiled(verdict, st)
        if missing:
            print("%s %s is not production ready and its defects are not filed (%s): fix them and judge again, or run the judge with --give-up"
                  % (item, clip, "; ".join(missing[:3])))
            return 1
    print("OK\t%s\t%s" % ("good" if ready else "wrong", look_text(verdict, st, ready)[:3000]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
