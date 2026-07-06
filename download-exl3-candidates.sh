#!/usr/bin/env bash
# 16GB EXL3 후보 2종 다운로드 (Devstral-24B 코딩특화 / Qwen3.6-27B 최신 dense).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
[ -f "$ROOT/config.env" ] && . "$ROOT/config.env"
HF="${HF_BIN:-$ROOT/exl3/tabbyAPI/.venv/bin/hf}"
DEST="$ROOT/exl3/models"
LOG="$ROOT/logs/exl3-candidates-download.log"
# repo :: 로컬폴더명
MODELS=(
  "ArtusDev/mistralai_Devstral-Small-2505_EXL3_4.0bpw_H6::Devstral-Small-2505-EXL3-4.0bpw"
  "UnstableLlama/Qwen3.6-27B-exl3-3.08bpw::Qwen3.6-27B-EXL3-3.08bpw"
)
echo "[start] $(date '+%F %T')" | tee "$LOG"
for m in "${MODELS[@]}"; do
  repo="${m%%::*}"; dir="${m##*::}"
  if [ -f "$DEST/$dir/config.json" ]; then echo "[skip] $dir 존재" | tee -a "$LOG"; continue; fi
  echo "[dl] $repo → $dir" | tee -a "$LOG"
  "$HF" download "$repo" --local-dir "$DEST/$dir" >>"$LOG" 2>&1 \
    && echo "[ok] $dir ($(du -sh "$DEST/$dir"|cut -f1))" | tee -a "$LOG" \
    || echo "[ERR] $dir" | tee -a "$LOG"
done
echo "[done] $(date '+%F %T')" | tee -a "$LOG"