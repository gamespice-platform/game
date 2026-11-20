#!/usr/bin/env python3
"""A stand-in for `claude -p` in the visual judge self-test (VISUAL_JUDGE_CLAUDE="python3 stub_judge.py").

Runs in the pack dir like the real judge: Reads every image, Writes verdict.json, prints stream-json on stdout and
writes the session's transcript under $VISUAL_JUDGE_TRANSCRIPTS/<project>/<session>.jsonl, the way Claude does.
STUB_MODE: clean (default), defect (one minor defect when the pack path contains $STUB_DEFECT, else clean),
skipread (never Reads the first image), badwrite (the transcript records other content than the file),
badtypes (defects is a string), hang (sleeps forever), notranscript (writes no transcript).
"""
import hashlib
import json
import os
import sys
import time
import uuid

mode = os.environ.get("STUB_MODE", "clean")
if mode == "hang":
    time.sleep(3600)
cwd = os.getcwd()
sid = str(uuid.uuid4())
imgs = sorted(f for f in os.listdir(cwd) if f.endswith((".jpg", ".png")))
defect = mode == "defect" and os.environ.get("STUB_DEFECT", "") in cwd
frames = [{"file": f, "camera": "all", "findings": "hands stay on the grip, the magazine seats, nothing pops"} for f in imgs]
verdict = {"looked_at": imgs, "frames": frames, "categories_clean": {}, "production_ready": not defect,
           "justification": "Every category was checked frame by frame across all three cameras for this clip."}
verdict["defects"] = [{"id": "D1", "category": "hands", "severity": "minor", "camera": "first person", "frames": ["still_02"],
                       "what": "the left hand floats a few pixels off the handguard", "fix_hint": "move the IK target", "nightly": ""}] if defect else []
if mode == "badtypes":
    verdict["defects"] = "none"
content = json.dumps(verdict, indent=2)
entries = [{"type": "tool_use", "name": "Read", "input": {"file_path": os.path.join(cwd, f)}} for f in imgs[(1 if mode == "skipread" else 0):]]
entries.append({"type": "tool_use", "name": "Write", "input": {"file_path": os.path.join(cwd, "verdict.json"),
                                                               "content": content + (" " if mode == "badwrite" else "")}})
with open(os.path.join(cwd, "verdict.json"), "w") as f:
    f.write(content)
lines = [{"type": "system", "subtype": "init", "session_id": sid, "cwd": cwd}]
lines += [{"type": "assistant", "session_id": sid, "message": {"content": [e]}} for e in entries]
lines.append({"type": "result", "session_id": sid, "result": "done"})
for l in lines:
    print(json.dumps(l))
root = os.environ.get("VISUAL_JUDGE_TRANSCRIPTS", "").split(":")[0]
if root and mode != "notranscript":
    proj = os.path.join(root, cwd.replace("/", "-"))
    os.makedirs(proj, exist_ok=True)
    with open(os.path.join(proj, sid + ".jsonl"), "w") as f:
        for e in entries:
            f.write(json.dumps({"type": "assistant", "cwd": cwd, "sessionId": sid, "message": {"content": [e]}}) + "\n")
sys.exit(0)
