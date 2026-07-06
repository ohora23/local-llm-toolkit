#!/usr/bin/env bash
# ⭐ CPU 에이전트 디스패처 — llama.cpp CPU 전용 서버 (두 번째 에이전트)
#
# GPU(EXL3 5000)가 코더로 포화돼도, 놀고 있는 CPU+78GB RAM 으로 별도 에이전트를
# 포트 5001 에 띄운다(-ngl 0, VRAM 미사용). 프로파일은 profiles/cpu-agent/ 에
# 드롭하면 자동 인식.
#
# 사용:
#   ./setup-cpu.sh --list           # 프로파일 목록
#   ./setup-cpu.sh                  # 인터랙티브 선택
#   ./setup-cpu.sh a-moe            # Qwen3-Coder-30B-A3B Q4 (품질, ~중속)
#   ./setup-cpu.sh b-light          # Qwen3-4B Q4 (경량, 빠름)
#
# 동작: preflight → 모델 탐색/다운로드 → active.env 작성
#       (서버 기동은 별도: ./start-cpu-server.sh)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILE_DIR="$SCRIPT_DIR/profiles/cpu-agent"

list_profiles() {
  echo "사용 가능한 프로파일:"
  for f in "$PROFILE_DIR"/*.sh; do
    [ -e "$f" ] || continue
    local name desc
    name="$(basename "$f" .sh)"
    desc="$(sed -n '2s/^# *//p' "$f")"
    printf "  %-12s %s\n" "$name" "$desc"
  done
}

run_profile() {
  local p="$PROFILE_DIR/$1.sh"
  if [ ! -f "$p" ]; then
    echo "[err] 프로파일 없음: $1"
    list_profiles
    exit 1
  fi
  bash "$p"
}

case "${1:-}" in
  --list|-l) list_profiles; exit 0 ;;
  "")
    list_profiles
    echo ""
    mapfile -t opts < <(for f in "$PROFILE_DIR"/*.sh; do basename "$f" .sh; done)
    select choice in "${opts[@]}"; do
      [ -n "$choice" ] && { run_profile "$choice"; break; }
    done
    ;;
  *) run_profile "$1" ;;
esac
