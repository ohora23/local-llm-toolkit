#!/usr/bin/env bash
# Profile B (Quality / 전용 세션) — 3.5bpw (~14.1GB) + Q6 KV + 16K ctx
# 최고 품질. VRAM 빠듯(여유 ~1.5GB) → 브라우저 닫고 단발 집중 세션 권장.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../lib/exl3-common.sh"

REPO="${REPO:-ArtusDev/Qwen_Qwen3-Coder-30B-A3B-Instruct-EXL3}"
REVISION="${REVISION:-3.5bpw_H6}"
SUBDIR="${SUBDIR:-Qwen3-Coder-30B-A3B-EXL3-3.5bpw}"
MAX_SEQ_LEN="${MAX_SEQ_LEN:-16384}"
CACHE_MODE="${CACHE_MODE:-Q6}"

preflight_exl3 || exit 1
ensure_tabby
download_exl3_model "$REPO" "$REVISION" "$SUBDIR"
write_tabby_config "$SUBDIR" "$MAX_SEQ_LEN" "$CACHE_MODE"

echo ""
echo "[done] 셋업 완료. 서버 기동:  ./start-tabby-server.sh"
echo "       벤치:                ./bench-exl3.sh"
echo "[tip]  VRAM 빠듯 — OOM 시 CACHE_MODE=Q4 또는 MAX_SEQ_LEN=8192 로 재실행."
