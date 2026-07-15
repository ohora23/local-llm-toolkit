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

# 코딩/에이전트용 강제 샘플링 프리셋(멱등 생성). 고컨텍스트에서 높은 temp가 3bpw 양자화와 겹쳐
# 툴콜 인자·출력이 깨지는 문제 방지(실측: temp≤0.4 안전, ≥0.7 붕괴). force로 클라이언트 값 무시.
SAMPLER_PRESET="${SAMPLER_PRESET:-coder}"
if [ -n "$SAMPLER_PRESET" ]; then
  mkdir -p "$TABBY_DIR/sampler_overrides"
  cat > "$TABBY_DIR/sampler_overrides/$SAMPLER_PRESET.yml" <<'YML'
# Ornith 코딩/에이전트 드라이버용 강제 샘플링. 고컨텍스트 툴콜 붕괴 방지(temp 클램프).
temperature:
  override: 0.2
  force: true
top_p:
  override: 0.9
  force: true
YML
  echo "[setup] sampler override: $SAMPLER_PRESET (temp 0.2 force)"
fi
write_tabby_config "$SUBDIR" "$MAX_SEQ_LEN" "$CACHE_MODE" "$SAMPLER_PRESET"

echo ""
echo "[done] Ornith 셋업 완료. 서버 기동:  ./start-tabby-server.sh"
echo "       벤치(데일리 드라이버 대비):   ./bench-exl3.sh"
