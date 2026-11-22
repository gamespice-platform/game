#!/usr/bin/env bash
# The visual judge loop's self-test: one regression per defect fixed in the judge, the gate and the post tool
# (vjudge-solid, vjudge-evidence-anchor-1). A stub judge (stub_judge.py) stands in for claude -p and writes test
# transcripts under VISUAL_JUDGE_TRANSCRIPTS; a stub nightly (stub_nightly.sh) stands in for the nightly CLI.
# Needs ffmpeg, flock, timeout; no GPU and no Claude account. Run from anywhere:
#   bash tests/visual_judge/selftest.sh        exit 0 when every case holds
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
judge=$repo/addons/gs_game/tools/gs_game_visual_judge.sh
gate=$repo/addons/gs_game/tools/gs_game_visual_verdict.py
post=$repo/addons/gs_game/tools/gs_game_visual_qa_post.sh
t=$(mktemp -d /tmp/vjudge-selftest.XXXXXX)
trap 'rm -rf "$t"' EXIT
export VISUAL_JUDGE_TRANSCRIPTS=$t/transcripts VISUAL_JUDGE_CLAUDE="python3 $here/stub_judge.py"
export NIGHTLY=$here/stub_nightly.sh STUB_NIGHTLY_DIR=$t/nightly VISUAL_JUDGE_PEAKS=2 VISUAL_JUDGE_STRIP=8
mkdir -p "$VISUAL_JUDGE_TRANSCRIPTS"
fails=0 n=0
ok() { n=$((n + 1)); echo "ok $n - $1"; }
bad() { n=$((n + 1)); fails=$((fails + 1)); echo "FAIL $n - $1"; [[ -z ${2:-} ]] || sed 's/^/    /' <<< "$2" | tail -8; }
# expect RC NAME [GREP] -- CMD...: CMD exits RC (and its output matches GREP), and never prints a Python traceback.
expect() {
  local want=$1 name=$2 pat=$3; shift 4
  local o rc
  o=$("$@" 2>&1); rc=$?
  if [[ $rc != "$want" ]]; then bad "$name (exit $rc, want $want)" "$o"
  elif [[ -n $pat ]] && ! grep -qiE -- "$pat" <<< "$o"; then bad "$name (no /$pat/)" "$o"
  elif grep -q Traceback <<< "$o"; then bad "$name (traceback)" "$o"
  else ok "$name"; fi
}
mkclip() { mkdir -p "$(dirname "$1")"; ffmpeg -v error -y -f lavfi -i "testsrc=size=240x80:rate=30:duration=${2:-1}" -pix_fmt yuv420p "$1"; }
gpu_log() { echo "gpu.sh: the laptop (staging) takes this frame" > "$1/capture.log"; }
c=$t/clips
mkclip "$c/rifle/fire.mp4" 1; mkclip "$c/rifle/reload.mp4" 2; mkclip "$c/pistol/fire.mp4" 1.5
gpu_log "$c"
run() { bash "$judge" --clips "$c" "$@"; }

# 1. three clean fresh passes: exit 0, the audit says sound, the gate posts the very clip judged and no other.
expect 0 "clean run is production ready after 3 passes" "PRODUCTION READY" -- run --out "$t/o1"
expect 0 "audit of a clean run is sound" "sound: PRODUCTION READY" -- python3 "$gate" --audit "$t/o1/verdict.json"
expect 0 "gate posts the judged clip as good" "^OK	good" -- python3 "$gate" "$t/o1/verdict.json" rifle fire --mp4 "$c/rifle/fire.mp4"
expect 1 "gate refuses another mp4 on that verdict (--mp4)" "not the clip the judge saw" -- python3 "$gate" "$t/o1/verdict.json" rifle fire --mp4 "$c/rifle/reload.mp4"
expect 0 "every pack has a distinct session and its variant" "" -- python3 -c '
import json,sys
s=[json.load(open(sys.argv[1]+"/pass%d/rifle/fire/evidence.json"%k)) for k in (1,2,3)]
assert len({e["judge_session"] for e in s})==3 and [e["variant"] for e in s]==[0,1,2] and all(e["renderer"] for e in s)' "$t/o1"

# 2. forging: an edited verdict, a hand-made pack, a pack copied into another clip, a hand-set production_ready.
run --out "$t/f1" > /dev/null 2>&1; sed -i 's/"production_ready": true/"production_ready": false/' "$t/f1/pass3/rifle/fire/verdict.json"
expect 1 "an edited pack verdict is refused" "differs from what the judge wrote" -- python3 "$gate" "$t/f1/verdict.json" rifle fire
run --out "$t/f2" > /dev/null 2>&1; python3 - "$t/f2/pass2/rifle/fire/evidence.json" << 'PY'
import json, sys, uuid
p = sys.argv[1]; e = json.load(open(p)); e["judge_session"] = str(uuid.uuid4()); json.dump(e, open(p, "w"))
PY
sed -i "s/\"session_id\": \"[^\"]*\"/\"session_id\": \"$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["judge_session"])' "$t/f2/pass2/rifle/fire/evidence.json")\"/" "$t/f2/pass2/rifle/fire/judge.jsonl"
expect 1 "a pack with a made-up session (no transcript) is refused" "no transcript" -- python3 "$gate" --audit "$t/f2/verdict.json"
run --out "$t/f3" > /dev/null 2>&1; rm -rf "$t/f3/pass1/pistol/fire"; cp -r "$t/f3/pass1/rifle/fire" "$t/f3/pass1/pistol/fire"
expect 1 "a pack copied from another clip is refused" "not in this pack|judged rifle fire" -- python3 "$gate" "$t/f3/verdict.json" pistol fire
run --out "$t/f4" > /dev/null 2>&1; rm -rf "$t/f4/pass3"
python3 -c 'import json,sys; p=sys.argv[1]; j=json.load(open(p)); j["production_ready"]=True; json.dump(j,open(p,"w"))' "$t/f4/verdict.json"
expect 1 "a hand-set production_ready with only 2 passes is not ready" "NOT production ready" -- python3 "$gate" --audit "$t/f4/verdict.json"
expect 1 "the gate will not post it as good either" "clean passes and no defects" -- python3 "$gate" "$t/f4/verdict.json" rifle fire
run --out "$t/f5" > /dev/null 2>&1; rm -f "$t/f5/pass2/rifle/reload/still_00"*
expect 1 "a deleted pack image is refused" "changed since the judge saw it" -- python3 "$gate" "$t/f5/verdict.json" rifle reload
run --out "$t/f6" > /dev/null 2>&1; python3 -c 'import json,sys; p=sys.argv[1]; e=json.load(open(p)); e["renderer"]="llvmpipe (LLVM 15.0.6, 256 bits)"; json.dump(e,open(p,"w"))' "$t/f6/pass1/rifle/fire/evidence.json"
expect 1 "a pack recorded on llvmpipe is refused" "never llvmpipe" -- python3 "$gate" "$t/f6/verdict.json" rifle fire

# 3. judges that do not do the work.
expect 5 "a judge that skips an image is invalid" "never Read" -- env STUB_MODE=skipread bash "$judge" --clips "$c" --out "$t/o3" --only pistol
expect 5 "a transcript whose Write differs is invalid" "not the file the judge wrote|did not write this verdict" -- env STUB_MODE=badwrite bash "$judge" --clips "$c" --out "$t/o3" --only pistol
expect 0 "a refused second Write leaves the first as the judge's file" "" -- env STUB_MODE=errwrite bash "$judge" --clips "$c" --out "$t/o4" --only pistol
expect 5 "a judge with no transcript is invalid" "no transcript" -- env STUB_MODE=notranscript bash "$judge" --clips "$c" --out "$t/o3" --only pistol
expect 5 "odd verdict types are invalid, not a crash" "defects is not a list" -- env STUB_MODE=badtypes bash "$judge" --clips "$c" --out "$t/o3" --only pistol
expect 5 "a hung judge is killed at the timeout" "killed" -- env STUB_MODE=hang VISUAL_JUDGE_TIMEOUT=2 bash "$judge" --clips "$c" --out "$t/o3" --only pistol

# 4. a defect: exit 1, refused until filed; --give-up files one stable key per category naming the session; refiling reuses it.
expect 1 "a defective clip is not ready" "NOT production ready" -- env STUB_MODE=defect STUB_DEFECT=/rifle/fire bash "$judge" --clips "$c" --out "$t/o4"
expect 1 "an unfiled defect is refused" "not filed" -- python3 "$gate" "$t/o4/verdict.json" rifle fire
expect 3 "--give-up files the defect" "filed vj-game-hands" -- env STUB_MODE=defect STUB_DEFECT=/rifle/fire bash "$judge" --clips "$c" --out "$t/o4" --give-up
expect 0 "a filed defect posts as wrong" "^OK	wrong.*vj-game-hands" -- python3 "$gate" "$t/o4/verdict.json" rifle fire
expect 1 "a clean clip of a failed round is not good" "clean passes and no defects" -- python3 "$gate" "$t/o4/verdict.json" pistol fire
sed -i 's/^status: .*/status: done/' "$STUB_NIGHTLY_DIR/vj-game-hands"
expect 3 "a done defect item is reopened, same key" "filed vj-game-hands" -- env STUB_MODE=defect STUB_DEFECT=/rifle/fire bash "$judge" --clips "$c" --out "$t/o4" --give-up
expect 0 "the reopened item is queued again" "" -- grep -q '^status: queue' "$STUB_NIGHTLY_DIR/vj-game-hands"
cp "$t/o4/verdict.json" "$t/o4/verdict.keep"; python3 -c '
import json,sys; p=sys.argv[1]; j=json.load(open(p))
for it in j["items"]:
    for d in it.get("defects") or []: d["nightly"]="vj-made-up"
json.dump(j,open(p,"w"))' "$t/o4/verdict.json"
expect 1 "a made-up nightly key is refused" "does not exist or does not name" -- python3 "$gate" "$t/o4/verdict.json" rifle fire
mv "$t/o4/verdict.keep" "$t/o4/verdict.json"
expect 1 "a filing failure is reported and fails the run, not hidden" "could not be filed" -- env STUB_MODE=defect STUB_DEFECT=/rifle/fire NIGHTLY=/bin/false bash "$judge" --clips "$c" --out "$t/o5" --give-up

# 5. a later round never inherits an earlier round's passes (stale verdict and packs are cleared).
expect 0 "clean run first" "" -- run --out "$t/o6"
expect 1 "then a failing round" "" -- env STUB_MODE=defect STUB_DEFECT=/rifle/fire bash "$judge" --clips "$c" --out "$t/o6"
expect 0 "its old pass2/pass3 are gone" "" -- test ! -e "$t/o6/pass2"
expect 1 "and the gate does not call the other clips good" "clean passes and no defects" -- python3 "$gate" "$t/o6/verdict.json" pistol fire

# 6. clips and GPU proof.
expect 4 "a requested item with no clip exits 4" "--only shotgun" -- run --out "$t/o7" --only rifle,shotgun
expect 4 "a requested clip name with no clip exits 4" "--anims inspect" -- run --out "$t/o7" --anims fire,inspect
mkdir -p "$t/c2/rifle"; head -c 4096 /dev/urandom > "$t/c2/rifle/fire.mp4"; gpu_log "$t/c2"
expect 4 "an unpackable clip exits 4 (never skipped)" "could not build the judge pack|no frames" -- bash "$judge" --clips "$t/c2" --out "$t/o8"
mkdir -p "$t/c3"; cp -r "$c/rifle" "$t/c3/"
expect 4 "no capture log exits 4" "no capture log" -- bash "$judge" --clips "$t/c3" --out "$t/o9"
echo "Vulkan 1.3 - Forward+ - Using Device #0: Mesa - llvmpipe (LLVM 15.0.6, 256 bits)" > "$t/c3/capture.log"
expect 4 "an llvmpipe log exits 4" "software" -- bash "$judge" --clips "$t/c3" --out "$t/o9"
echo "godot: starting" > "$t/c3/capture.log"
expect 4 "a log with no GPU line exits 4" "no GPU line" -- bash "$judge" --clips "$t/c3" --out "$t/o9"
echo "Vulkan 1.3.255 - Forward+ - Using Device #0: NVIDIA - NVIDIA GeForce RTX 3060" > "$t/c3/capture.log"
expect 0 "Godot's Using Device line for a GPU is proof" "PRODUCTION READY" -- bash "$judge" --clips "$t/c3" --out "$t/o9"
expect 4 "a capture that writes no new clip exits 4 (stale clip)" "stale clip" -- run --out "$t/o10" --only pistol --capture "echo 'gpu.sh: the laptop (staging) takes this frame'"
expect 0 "a capture that rewrites the clip is judged" "PRODUCTION READY" -- run --out "$t/o10" --only pistol --capture "echo 'gpu.sh: the laptop (staging) takes this frame'; ffmpeg -v error -y -f lavfi -i testsrc=size=240x80:rate=30:duration=1 -pix_fmt yuv420p $c/pistol/fire.mp4"

# 7. one run per --out (the lock).
(flock 9; sleep 5) 9> "$t/o1/.lock" &
sleep 1
expect 2 "a second run on the same --out is refused" "holds .*lock" -- run --out "$t/o1"
wait

# 8. the gate and audit never crash on garbage.
mkdir -p "$t/g"; echo '{"items": [1, {"item": null}], "production_ready": "yes"' > "$t/g/verdict.json"
expect 1 "audit of garbled JSON says not ready" "UNSOUND" -- python3 "$gate" --audit "$t/g/verdict.json"
echo '[]' > "$t/g/verdict.json"
expect 1 "audit of a non-object says not ready" "UNSOUND" -- python3 "$gate" --audit "$t/g/verdict.json"
echo '{"items": [{"item": "a", "clip": "b"}]}' > "$t/g/verdict.json"; mkdir -p "$t/g/pass1/a/b"; echo '{"judge_session": null, "images": 3}' > "$t/g/pass1/a/b/evidence.json"
expect 1 "audit of a pack with a null session says not ready" "UNSOUND" -- python3 "$gate" --audit "$t/g/verdict.json"
expect 2 "the gate's usage" "" -- python3 "$gate" only-one-arg

# 9. the post tool: the report's metric column no longer clobbers the verdict path, and it never trusts test transcripts.
g=$t/game; mkdir -p "$g/addons/gs_game/tools" "$g/screenshots/visual_qa"
cp "$repo/addons/gs_game/tools/"gs_game_visual_{qa_post.sh,verdict.py} "$g/addons/gs_game/tools/"
cp -r "$c/rifle" "$g/screenshots/visual_qa/"; cp -r "$t/o1" "$g/screenshots/visual_qa/judge"
printf 'fps: 30\n| item | clip | verdict | why |\n| rifle | fire | PASS | ok |\n' > "$g/screenshots/visual_qa/report.md"
expect 1 "the post tool refuses test transcripts (production lookup)" "refusing rifle fire.*Claude transcript" -- bash "$g/addons/gs_game/tools/gs_game_visual_qa_post.sh" test-key
o=$(bash "$g/addons/gs_game/tools/gs_game_visual_qa_post.sh" test-key 2>&1)
grep -q "verdict at PASS" <<< "$o" && bad "the post tool passed the metric as the verdict path" "$o" || ok "the post tool keeps the verdict path"

echo "$((n - fails))/$n passed"
((fails == 0))
