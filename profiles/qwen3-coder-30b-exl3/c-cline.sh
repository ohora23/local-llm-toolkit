#!/usr/bin/env bash
# Profile C (Cline / 에이전트 모드) — 3.0bpw + Q4 KV + 32K ctx
# Cline은 파일 내용·터미널 출력을 컨텍스트로 먹어 문맥이 큼 → 16K로는 부족, 32K 확보.
# Q4 캐시로 32K KV 메모리를 보완. VRAM 빠듯하면 MAX_SEQ_LEN=24576 으로 낮춰 재실행.
#
# 복구(평소 Continue/일반용 16K로 되돌리기):  ./setup-exl3.sh a-safe
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../lib/exl3-common.sh"

REPO="${REPO:-ArtusDev/Qwen_Qwen3-Coder-30B-A3B-Instruct-EXL3}"
REVISION="${REVISION:-3.0bpw_H6}"
SUBDIR="${SUBDIR:-Qwen3-Coder-30B-A3B-EXL3-3.0bpw}"   # a-safe와 동일 모델 재사용(추가 다운로드 없음)
MAX_SEQ_LEN="${MAX_SEQ_LEN:-32768}"
CACHE_MODE="${CACHE_MODE:-Q4}"

preflight_exl3 || exit 1
ensure_tabby
download_exl3_model "$REPO" "$REVISION" "$SUBDIR"
write_tabby_config "$SUBDIR" "$MAX_SEQ_LEN" "$CACHE_MODE"

echo ""
echo "[done] Cline용 32K 컨텍스트 설정 완료. 서버 재기동: ./start-tabby-server.sh"
echo "[복구] 평소(16K/Q6)로 되돌리기:  ./setup-exl3.sh a-safe  → 서버 재기동"
echo "[tip]  OOM 시: MAX_SEQ_LEN=24576 ./setup-exl3.sh c-cline"
