#!/usr/bin/env bash
# ⭐ EXL3 디스패처 — ExLlamaV3 + TabbyAPI 로 Qwen3-Coder-30B-A3B 를 GPU 풀적재
#
# Ollama(부분 CPU 오프로드, 47~61 tok/s) 대비, 오프로드 제거가 목적.
# 프로파일은 profiles/qwen3-coder-30b-exl3/ 에 드롭하면 자동 인식.
#
# 사용:
#   ./setup-exl3.sh --list            # 프로파일 목록
#   ./setup-exl3.sh                   # 인터랙티브 선택
#   ./setup-exl3.sh a-safe            # 직접 지정 (3.0bpw, 듀얼모니터 상시)
#   ./setup-exl3.sh b-quality         # 3.5bpw, 전용 세션 (브라우저 닫고)
#
# 동작: preflight → tabbyAPI/venv 설치 → 모델 다운로드 → config.yml 작성
#       (서버 기동은 별도: ./start-tabby-server.sh)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILE_DIR="$SCRIPT_DIR/profiles/qwen3-coder-30b-exl3"

list_profiles() {
  echo "사용 가능한 프로파일:"
  for f in "$PROFILE_DIR"/*.sh; do
    [ -e "$f" ] || continue
    local name desc
    name="$(basename "$f" .sh)"
    # 2번째 줄(# Profile: ...) 에서 설명 추출
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
