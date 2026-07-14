#!/usr/bin/env bash
# Profile E (Ornith-1.0-35B) — 로컬 변환 EXL3 3.0bpw, Qwen3.5-35B-A3B 기반 agentic-coding reasoning MoE.
# 데일리 드라이버(Qwen3-Coder-30B) A/B 벤치용. 먼저 ./convert-ornith-exl3.sh 로 변환되어 있어야 함.
# 기본 32K/Q4 (reasoning <think> 토큰 여유). 원복/조정은 env override.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../lib/exl3-common.sh"

# 로컬 변환물이라 REPO/REVISION은 형식상만(dest에 config.json 있으면 다운로드 스킵)
REPO="${REPO:-local/ornith}"
REVISION="${REVISION:-main}"
SUBDIR="${SUBDIR:-Ornith-1.0-35B-EXL3-3.0bpw}"
MAX_SEQ_LEN="${MAX_SEQ_LEN:-131072}"   # 128K — 하이브리드 어텐션이라 16GB에 fit(224K까지 가능)
CACHE_MODE="${CACHE_MODE:-Q4}"

preflight_exl3 || exit 1
ensure_tabby

# 변환물 존재 확인(없으면 안내)
if [ ! -f "$SCRIPT_DIR/../../exl3/models/$SUBDIR/config.json" ]; then
  echo "[err] $SUBDIR 없음 — 먼저 변환하세요:  ./convert-ornith-exl3.sh"
  exit 1
fi
download_exl3_model "$REPO" "$REVISION" "$SUBDIR"   # config.json 있으면 즉시 스킵
write_tabby_config "$SUBDIR" "$MAX_SEQ_LEN" "$CACHE_MODE"

echo ""
echo "[done] Ornith 셋업 완료. 서버 기동:  ./start-tabby-server.sh"
echo "       벤치(데일리 드라이버 대비):   ./bench-exl3.sh"
