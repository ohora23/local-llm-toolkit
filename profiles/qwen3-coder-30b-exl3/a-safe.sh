#!/usr/bin/env bash
# Profile A (Safe / 듀얼모니터 상시) — 3.0bpw (~12.2GB) + Q6 KV + 16K ctx
# Ollama 'a-safe'(오프로드 13.5GB)와 같은 VRAM 영역, 단 GPU 100% 적재.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../lib/exl3-common.sh"

REPO="${REPO:-ArtusDev/Qwen_Qwen3-Coder-30B-A3B-Instruct-EXL3}"
REVISION="${REVISION:-3.0bpw_H6}"
SUBDIR="${SUBDIR:-Qwen3-Coder-30B-A3B-EXL3-3.0bpw}"
MAX_SEQ_LEN="${MAX_SEQ_LEN:-16384}"
CACHE_MODE="${CACHE_MODE:-Q6}"

preflight_exl3 || exit 1
ensure_tabby
download_exl3_model "$REPO" "$REVISION" "$SUBDIR"
write_tabby_config "$SUBDIR" "$MAX_SEQ_LEN" "$CACHE_MODE"

echo ""
echo "[done] 셋업 완료. 서버 기동:  ./start-tabby-server.sh"
echo "       벤치:                ./bench-exl3.sh"
