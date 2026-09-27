#!/usr/bin/env bash
# oc-run.sh — Claude Code -> opencode(로컬 hrvl Qwen3.6) 코드 노동 위임.
#   oc-run.sh [-C <dir>] [-c] "<task>"     -C 작업 디렉터리(기본 .), -c 직전 세션 이어가기
#   env: OC_TIMEOUT(전체 초, 기본 1800) OC_IDLE(진행 없음 허용 초, 기본 600) OC_TAIL(출력 꼬리 줄수, 기본 15) OC_MODEL
#   exit: 0 완료 · 2 디렉터리 없음 · 3 hrvl 분리/불통/명세 경로 문제 → Claude가 직접 수행 · 4 정지(OC_IDLE 동안 진행 없음) · 124 시간 초과
# --pure: 플러그인 없이 실행(플러그인 포함 시작 무응답 2/9 관찰). opencode는 hrvl 로컬 모델만 쓴다(Claude 연결 없음).
# 명세는 인라인 또는 저장소 안 파일로. Claude 임시 디렉터리(/tmp/claude-*) 경로는 opencode가 못 읽어 30분 정지로 이어졌다(2026-09-27).
set -uo pipefail
dir=.; cont=()
while [ $# -gt 1 ]; do
  case "$1" in -C) dir="$2"; shift 2;; -c|--continue) cont=(--continue); shift;; *) break;; esac
done
task="${1:?usage: oc-run.sh [-C dir] [-c] \"task\"}"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/llm"
HRVL="${HRVL_HOST:-hrvl-server.local}:${HRVL_PORT:-8080}"
[ -f "$STATE/hrvl-detached" ] && { echo "== hrvl is detached from this PC (llm hrvl connect) — do the task directly"; exit 3; }
curl -s -m 3 "http://$HRVL/v1/models" >/dev/null 2>&1 || { echo "== hrvl unreachable ($HRVL) — do the task directly"; exit 3; }
case "$task" in *"/tmp/claude-"*|*"/scratchpad/"*)
  echo "== task references a Claude scratchpad path; opencode cannot read it — inline the spec or put it in the repo"; exit 3;; esac
cd "$dir" || { echo "no such dir: $dir" >&2; exit 2; }
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
ts=$(date +%Y%m%d-%H%M%S); log="/tmp/oc-run.$ts.log"; elog="/tmp/oc-run.$ts.err"
model=(); [ -n "${OC_MODEL:-}" ] && model=(-m "$OC_MODEL")
# --print-logs: every agent step lands in $elog, so "no new bytes for OC_IDLE seconds" means a real stall
"$HOME/.opencode/bin/opencode" run --pure --print-logs --log-level INFO "${model[@]}" "${cont[@]}" "$task" >"$log" 2>"$elog" &
pid=$!; start=$(date +%s); last=$start; rc=0
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
exit "$rc"
