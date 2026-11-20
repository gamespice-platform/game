#!/usr/bin/env bash
# A stand-in nightly CLI for the visual judge self-test: items are files under $STUB_NIGHTLY_DIR, calls are logged.
set -u
d=${STUB_NIGHTLY_DIR:?}
mkdir -p "$d"
echo "$*" >> "$d/calls.log"
cmd=$1; shift
case $cmd in
  show) [[ -f $d/$1 ]] && cat "$d/$1" ;;
  add)
    key= body=
    while (($#)); do case $1 in --key) key=$2; shift 2 ;; --body) body=$2; shift 2 ;; *) shift ;; esac; done
    printf '[%s]\nstatus: queue\n\n%s\n' "$key" "$body" > "$d/$key" ;;
  note) key=$1; shift; while [[ ${1:-} == --* ]]; do shift 2; done; printf '\nnote: %s\n' "$*" >> "$d/$key" ;;
  set) key=$1; [[ ${2:-} == --status ]] && sed -i "s/^status: .*/status: $3/" "$d/$key" ;;
  review) exit 0 ;;
  *) exit 1 ;;
esac
