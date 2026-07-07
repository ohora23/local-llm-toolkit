#!/usr/bin/env bash
# 엔드포인트별 기본 모델을 (없을 때만) 다운로드. `llm up <ep>` 가 자동 호출하고,
# 직접 실행도 가능. 이미 있으면 즉시 no-op.
#   ./download-model.sh <gpu|cpu|hyb|ko>
# 모델/리포 override(선택): EXL3_PROFILE, CPU_PROFILE, KO_REPO, HYB_REPO, MODEL_STORE (config.env).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"; [ -f "$ROOT/config.env" ] && . "$ROOT/config.env"
STORE="${MODEL_STORE:-$HOME/b_Models}"
HF="${HF_BIN:-$ROOT/exl3/tabbyAPI/.venv/bin/hf}"; [ -x "$HF" ] || HF="$(command -v hf || command -v huggingface-cli || echo hf)"

case "${1:-}" in
  gpu)
    [ -n "$(ls -d "$ROOT"/exl3/models/*/ 2>/dev/null)" ] && { echo "[ok] gpu(EXL3) 모델 이미 있음"; exit 0; }
    echo "[dl] gpu EXL3 → setup-exl3.sh ${EXL3_PROFILE:-a-safe}"
    exec "$ROOT/setup-exl3.sh" "${EXL3_PROFILE:-a-safe}" ;;
  cpu)
    [ -n "$(ls "$ROOT"/cpu/models/*.gguf 2>/dev/null)" ] && { echo "[ok] cpu(GGUF) 모델 이미 있음"; exit 0; }
    echo "[dl] cpu GGUF → setup-cpu.sh ${CPU_PROFILE:-a-moe}"
    exec "$ROOT/setup-cpu.sh" "${CPU_PROFILE:-a-moe}" ;;
  ko)
    M="$STORE/kanana-2-30b-a3b-instruct-2601-Q4_K_M.gguf"
    [ -f "$M" ] && { echo "[ok] ko(Kanana-2) 이미 있음"; exit 0; }
    echo "[dl] ko Kanana-2 GGUF (~18.6G) → $STORE"
    exec "$HF" download "${KO_REPO:-ohora23/Kanana-2-30B-A3B-Instruct-GGUF}" \
      --include "kanana-2-30b-a3b-instruct-2601-Q4_K_M.gguf" --local-dir "$STORE" ;;
  hyb)
    D="$STORE/Mistral-Small-4-119B-Q4_K_XL"
    [ -f "$D/UD-Q4_K_XL/Mistral-Small-4-119B-2603-UD-Q4_K_XL-00001-of-00003.gguf" ] && { echo "[ok] hyb(Mistral-Small-4) 이미 있음"; exit 0; }
    echo "[dl] hyb Mistral-Small-4-119B Q4_K_XL (~74G, 시간 소요) → $D"
    exec "$HF" download "${HYB_REPO:-unsloth/Mistral-Small-4-119B-2603-GGUF}" \
      --include "UD-Q4_K_XL/*" --local-dir "$D" ;;
  *) echo "사용: $0 <gpu|cpu|hyb|ko>"; exit 1 ;;
esac
