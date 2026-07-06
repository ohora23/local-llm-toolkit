#!/usr/bin/env bash
# Mistral 비교용 3종 GGUF 다운로드 (Q4_K_M, b_Models 로). 백그라운드 실행용.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
[ -f "$ROOT/config.env" ] && . "$ROOT/config.env"
HF="${HF_BIN:-$ROOT/exl3/tabbyAPI/.venv/bin/hf}"
DEST="${MODEL_STORE:-$HOME/b_Models}"
LOG="$ROOT/logs/mistral-download.log"

# repo :: filename  (unsloth Q4_K_M)
MODELS=(
  "unsloth/Devstral-Small-2507-GGUF::Devstral-Small-2507-Q4_K_M.gguf"
  "unsloth/Magistral-Small-2509-GGUF::Magistral-Small-2509-Q4_K_M.gguf"
  "unsloth/Mistral-Small-3.2-24B-Instruct-2506-GGUF::Mistral-Small-3.2-24B-Instruct-2506-Q4_K_M.gguf"
)

echo "[start] $(date '+%F %T') Mistral 3종 다운로드 → $DEST" | tee "$LOG"
for m in "${MODELS[@]}"; do
  repo="${m%%::*}"; file="${m##*::}"
  if [ -f "$DEST/$file" ]; then
    echo "[skip] 이미 존재: $file" | tee -a "$LOG"; continue
  fi
  echo "[dl] $repo :: $file" | tee -a "$LOG"
  "$HF" download "$repo" "$file" --local-dir "$DEST" >>"$LOG" 2>&1 \
    && echo "[ok] $file ($(du -h "$DEST/$file" 2>/dev/null | cut -f1))" | tee -a "$LOG" \
    || echo "[ERR] $file 다운로드 실패" | tee -a "$LOG"
done
echo "[done] $(date '+%F %T')" | tee -a "$LOG"