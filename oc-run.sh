#!/usr/bin/env bash
# oc-run.sh — Claude Code -> opencode(로컬 hrvl Qwen3.6) 코드 노동 위임.
#   oc-run.sh [-C <dir>] [-c] "<task>"     -C 작업 디렉터리(기본 .), -c 직전 세션 이어가기
#   env: OC_TIMEOUT(초, 기본 1800) OC_TAIL(출력 꼬리 줄수, 기본 15) OC_MODEL(provider/model 강제)
# --pure: 플러그인(Orca 상태 훅) 없이 실행. 플러그인 포함 실행에서 시작 단계 무응답이 9회 중 2회 관찰됨.
# opencode는 hrvl 로컬 모델만 쓴다(Claude 연결 없음). 긴 작업은 Claude Code에서 run_in_background로.
set -uo pipefail
dir=.; cont=()
while [ $# -gt 1 ]; do
  case "$1" in -C) dir="$2"; shift 2;; -c|--continue) cont=(--continue); shift;; *) break;; esac
done
task="${1:?usage: oc-run.sh [-C dir] [-c] \"task\"}"
cd "$dir" || { echo "no such dir: $dir" >&2; exit 2; }
log="/tmp/oc-run.$(date +%Y%m%d-%H%M%S).log"
model=(); [ -n "${OC_MODEL:-}" ] && model=(-m "$OC_MODEL")
timeout "${OC_TIMEOUT:-1800}" "$HOME/.opencode/bin/opencode" run --pure "${model[@]}" "${cont[@]}" "$task" >"$log" 2>&1; rc=$?
echo "== opencode exit=$rc  dir=$(pwd)  log=$log"
tail -n "${OC_TAIL:-15}" "$log"
echo "== git diff --stat"; git diff --stat 2>/dev/null
git status --short 2>/dev/null | grep '^??' | grep -v -e __pycache__ -e '\.log$' | head
exit $rc
