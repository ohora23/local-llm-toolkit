#!/usr/bin/env bash
# Qwen3-Coder-30B-A3B Q4_K_M 셋업 디스패처
#
# 구조:
#   profiles/30b-moe-q4/*.sh    실제 옵션 스크립트 (자동 탐색)
#   lib/register-ollama.sh      공통 라이브러리
#
# 새 옵션 추가:
#   profiles/30b-moe-q4/c-extreme.sh 같은 파일만 드롭하면 자동 인식
#
# 사용:
#   ./setup-30b-moe-q4.sh                  # 인터랙티브 메뉴
#   ./setup-30b-moe-q4.sh a-safe           # 옵션 직접 지정
#   ./setup-30b-moe-q4.sh --list           # 옵션 목록만 표시
#   NUM_GPU=30 ./setup-30b-moe-q4.sh a-safe   # 파라미터 오버라이드

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILE_DIR="$SCRIPT_DIR/profiles/30b-moe-q4"

if [[ ! -d "$PROFILE_DIR" ]]; then
  echo "[err] 프로파일 디렉토리 없음: $PROFILE_DIR"
  exit 1
fi

# 옵션 자동 탐색 (파일명 알파벳순)
mapfile -t OPTIONS < <(
  find "$PROFILE_DIR" -maxdepth 1 -name '*.sh' -type f -printf '%f\n' \
    | sed 's/\.sh$//' | sort
)

if [[ ${#OPTIONS[@]} -eq 0 ]]; then
  echo "[err] $PROFILE_DIR 에 *.sh 옵션이 없습니다."
  exit 1
fi

# 옵션별 설명을 파일 헤더에서 추출
show_options() {
  echo "Available options:"
  for opt in "${OPTIONS[@]}"; do
    local file="$PROFILE_DIR/$opt.sh"
    local desc
    desc=$(grep -m1 '^# Profile:' "$file" 2>/dev/null | sed 's/^# Profile: *//' || true)
    printf "  %-15s %s\n" "$opt" "${desc:-(설명 없음)}"
  done
}

# --list / -l
if [[ "${1:-}" == "--list" ]] || [[ "${1:-}" == "-l" ]]; then
  show_options
  exit 0
fi

CHOICE="${1:-}"

# 인터랙티브 메뉴
if [[ -z "$CHOICE" ]]; then
  echo "=== Qwen3-Coder-30B-A3B Q4_K_M setup ==="
  show_options
  echo ""
  PS3="번호 선택 (또는 q로 취소): "
  select opt in "${OPTIONS[@]}"; do
    case "$REPLY" in
      q|Q) echo "취소."; exit 0 ;;
      *)
        if [[ -n "${opt:-}" ]]; then
          CHOICE="$opt"
          break
        fi
        echo "잘못된 선택. 다시 시도하세요."
        ;;
    esac
  done
fi

PROFILE_FILE="$PROFILE_DIR/$CHOICE.sh"
if [[ ! -f "$PROFILE_FILE" ]]; then
  echo "[err] '$CHOICE' 옵션이 없습니다."
  echo ""
  show_options
  exit 1
fi

echo ""
exec "$PROFILE_FILE"
