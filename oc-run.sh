#!/usr/bin/env bash
# oc-run.sh — Claude Code -> opencode(로컬 hrvl Qwen3.6) 코드 노동 위임.
#   oc-run.sh [-C <dir>] [-c] "<task>"     -C 작업 디렉터리(기본 .), -c 직전 세션 이어가기
#   env: OC_TIMEOUT(전체 초, 기본 1800) OC_IDLE(진행 없음 허용 초, 기본 600) OC_TAIL(출력 꼬리 줄수, 기본 15) OC_MODEL
#   exit: 0 완료 · 2 디렉터리 없음 · 3 hrvl 분리/불통/명세 경로 문제 → Claude가 직접 수행 · 4 정지(OC_IDLE 동안 진행 없음) · 124 시간 초과
#   every exit (2 and 3 included) appends one JSON line to ~/.local/state/llm/oc-runs.jsonl; logs live in
#   ~/.local/state/llm/oc-run-logs/ (older than 30 days are deleted at the next run)
#   oc-run.sh [-C <dir>] --verdict <ok|rework|fail> "reason" [<log path>|last]
#       record the review of a run (rc=0 is not success: a run can end 0 with the goal missed) as a
#       {"kind":"verdict"} line in the same jsonl; default target = the latest run started in dir. No hrvl, no task.
#   oc-run.sh --stats [days]    runs of the last N days (default 14): rc, verdict (ok/rework/fail/none), mean secs
# --pure: 플러그인 없이 실행(플러그인 포함 시작 무응답 2/9 관찰). opencode는 hrvl 로컬 모델만 쓴다(Claude 연결 없음).
# 명세는 인라인 또는 저장소 안 파일로. Claude 임시 디렉터리(/tmp/claude-*) 경로는 opencode가 못 읽어 30분 정지로 이어졌다(2026-09-27).
set -uo pipefail
dir=.; cont=(); continued=false
while [ $# -gt 1 ]; do
  case "$1" in -C) dir="$2"; shift 2;; -c|--continue) cont=(--continue); continued=true; shift;; *) break;; esac
done
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/llm"; LOGS="$STATE/oc-run-logs"; mkdir -p "$LOGS"
case "${1:-}" in
--verdict|--stats)
  # bookkeeping only: no hrvl check, no opencode. --verdict needs a dir to pick the latest run from.
  [ "$1" = --verdict ] && { cd "$dir" || { echo "no such dir: $dir" >&2; exit 2; }; }
  MODE="$1" V="${2:-}" REASON="${3:-}" TARGET="${4:-last}" DIR="$(pwd)" python3 - "$STATE/oc-runs.jsonl" <<'PY'
import os, sys, json, datetime
e = os.environ; path = sys.argv[1]
now = datetime.datetime.now().astimezone()
rows = []
if os.path.exists(path):
    for line in open(path):
        try: rows.append(json.loads(line))
        except ValueError: pass
if e["MODE"] == "--verdict":
    v = e["V"]
    if v not in ("ok", "rework", "fail"):
        sys.exit("verdict must be ok, rework or fail (got %r)" % v)
    if not e["REASON"]:
        sys.exit('a reason is required: --verdict %s "why"' % v)
    runs = [r for r in rows if "kind" not in r and r.get("log")]
    if e["TARGET"] != "last": runs = [r for r in runs if r["log"] == e["TARGET"]]
    else: runs = [r for r in runs if r.get("dir") == e["DIR"]]
    if not runs: sys.exit("no run found (dir %s, target %s)" % (e["DIR"], e["TARGET"]))
    run = runs[-1]
    rec = {"ts": now.isoformat(timespec="seconds"), "kind": "verdict", "log": run["log"],
           "dir": run["dir"], "verdict": v, "reason": e["REASON"]}
    open(path, "a").write(json.dumps(rec, ensure_ascii=False) + "\n")
    print("verdict %s recorded for run %s (%s)" % (v, run["ts"], run["log"]))
else:
    days = int(e["V"] or 14)
    since = now - datetime.timedelta(days=days)
    def ts(r): return datetime.datetime.fromisoformat(r["ts"])
    runs = [r for r in rows if "kind" not in r and ts(r) >= since]
    asks = [r for r in rows if r.get("kind") == "ask" and ts(r) >= since]
    verdict = {}  # log -> latest verdict
    for r in rows:
        if r.get("kind") == "verdict": verdict[r["log"]] = r["verdict"]
    print("oc-run stats, last %d days: %d runs, %d asks" % (days, len(runs), len(asks)))
    if runs:
        rc = {}
        for r in runs: rc[r["rc"]] = rc.get(r["rc"], 0) + 1
        print("  rc:      " + "  ".join("%s=%d" % kv for kv in sorted(rc.items())))
        vd = {"ok": 0, "rework": 0, "fail": 0, "none": 0}
        for r in runs: vd[verdict.get(r.get("log"), "none")] += 1
        print("  verdict: " + "  ".join("%s=%d" % kv for kv in vd.items()))
        print("  secs:    mean %.0f  (max %d)" % (sum(r["secs"] for r in runs) / len(runs), max(r["secs"] for r in runs)))
    if asks:
        print("  ask:     mean %.0f s, %.0f chars" % (sum(r["secs"] for r in asks) / len(asks), sum(r["prompt_chars"] for r in asks) / len(asks)))
PY
  exit $? ;;
esac
task="${1:?usage: oc-run.sh [-C dir] [-c] \"task\"}"
find "$LOGS" -type f -mtime +30 -delete 2>/dev/null
start=$(date +%s); ts=$(date +%Y%m%d-%H%M%S); log="$LOGS/oc-run.$ts.log"; elog="$LOGS/oc-run.$ts.err"
absdir=""
finish() {  # finish <rc>: one JSON line per run, on every exit path, then exit
  local rc=$1 changed=0
  [ -n "$absdir" ] && git rev-parse --is-inside-work-tree >/dev/null 2>&1 &&
    changed=$(( $(git diff --name-only | wc -l) + $(git status --short | grep '^??' | grep -vc -e __pycache__ -e '\.log$') ))
  RC=$rc SECS=$(( $(date +%s) - start )) DIR="${absdir:-$dir}" TASK="$task" CHANGED=$changed \
  LOG="$([ -e "$log" ] && echo "$log")" CONT=$continued python3 -c '
import os, json, datetime
e = os.environ
print(json.dumps({"ts": datetime.datetime.now().astimezone().isoformat(timespec="seconds"), "dir": e["DIR"],
  "task": e["TASK"][:200], "rc": int(e["RC"]), "secs": int(e["SECS"]), "files_changed": int(e["CHANGED"]),
  "log": e["LOG"] or None, "continued": e["CONT"] == "true"}, ensure_ascii=False))' >>"$STATE/oc-runs.jsonl"
  exit "$rc"
}
HRVL="${HRVL_HOST:-hrvl-server.local}:${HRVL_PORT:-8080}"
[ -f "$STATE/hrvl-detached" ] && { echo "== hrvl is detached from this PC (llm hrvl connect) — do the task directly"; finish 3; }
curl -s -m 3 "http://$HRVL/v1/models" >/dev/null 2>&1 || { echo "== hrvl unreachable ($HRVL) — do the task directly"; finish 3; }
case "$task" in *"/tmp/claude-"*|*"/scratchpad/"*)
  echo "== task references a Claude scratchpad path; opencode cannot read it — inline the spec or put it in the repo"; finish 3;; esac
cd "$dir" || { echo "no such dir: $dir" >&2; finish 2; }
absdir=$(pwd)
# match opencode's context limit to the live slot size (hrvl main = 128K/slot, local = 64K/slot);
# the static opencode.json keeps 60000 as the safe fallback for the interactive TUI
slot_ctx=$(curl -s -m 3 "http://$HRVL/slots" | python3 -c 'import sys,json
try: d=json.load(sys.stdin); print(d[0].get("n_ctx",0))
except Exception: print(0)' 2>/dev/null)
if [ "${slot_ctx:-0}" -ge 32768 ]; then
  limit=$(( slot_ctx - 8192 - 1024 ))
  export OPENCODE_CONFIG_CONTENT="{\"provider\":{\"hrvl\":{\"models\":{\"Qwen3.6-35B-A3B-UD-Q4_K_M.gguf\":{\"limit\":{\"context\":$limit,\"output\":8192}}}}}}"
  echo "== hrvl slot ${slot_ctx} tokens -> opencode context limit $limit"
fi
model=(); [ -n "${OC_MODEL:-}" ] && model=(-m "$OC_MODEL")
# --print-logs: every agent step lands in $elog, so "no new bytes for OC_IDLE seconds" means a real stall
"$HOME/.opencode/bin/opencode" run --pure --print-logs --log-level INFO "${model[@]}" "${cont[@]}" "$task" >"$log" 2>"$elog" &
pid=$!; last=$(date +%s); rc=0
while kill -0 "$pid" 2>/dev/null; do
  sleep 5; now=$(date +%s)
  for f in "$log" "$elog"; do m=$(stat -c %Y "$f" 2>/dev/null || echo 0); [ "$m" -gt "$last" ] && last=$m; done
  if (( now - start > ${OC_TIMEOUT:-1800} )); then kill "$pid" 2>/dev/null; rc=124; break; fi
  if (( now - last > ${OC_IDLE:-600} )); then kill "$pid" 2>/dev/null; rc=4; break; fi
done
if [ "$rc" = 0 ]; then wait "$pid"; rc=$?; fi
echo "== opencode exit=$rc  dir=$(pwd)  log=$log  ($(( $(date +%s) - start ))s)"
[ "$rc" = 4 ] && echo "== stalled: no progress for ${OC_IDLE:-600}s (hrvl slots busy? unreadable spec?) — retry with inline spec or do it directly"
[ "$rc" = 124 ] && echo "== timeout after ${OC_TIMEOUT:-1800}s"
tail -n "${OC_TAIL:-15}" "$log"
echo "== git diff --stat"; git diff --stat 2>/dev/null
git status --short 2>/dev/null | grep '^??' | grep -v -e __pycache__ -e '\.log$' | head
finish "$rc"
