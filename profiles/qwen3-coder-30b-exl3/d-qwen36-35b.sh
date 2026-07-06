#!/usr/bin/env bash
# Profile D — Qwen3.6-35B-A3B (MoE, 활성 3B) EXL3 2.08bpw. 신형 코더 대안.
# 검증(2026-07-06): 코딩 eval 정확성 = 현재 Qwen3-Coder-30B와 동급(쉬운6/6=6/6, 어려운5/6=5/6),
#   ~127 tok/s(현재 115보다↑), VRAM 9.8GB(현재 12보다↓, 6GB 여유).
# ★ thinking-off가 chat_template.jinja에 baked-in(기본 off) → 어느 클라이언트든 간결 코드.
#   사고 켜려면 요청에 chat_template_kwargs:{enable_thinking:true}.
# ★ tool_format=qwen3_coder(공통) 그대로 에이전트 툴콜 정상(2026-07-06 검증): Qwen3.6도 Qwen3-Coder와
#   동일한 <tool_call><function=name> XML 형식 → 파싱됨. 멀티스텝 에이전트 루프(21툴콜, 정답도출) 통과.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../lib/exl3-common.sh"

SUBDIR="${SUBDIR:-Qwen3.6-35B-A3B-EXL3-2.08bpw}"
MAX_SEQ_LEN="${MAX_SEQ_LEN:-16384}"
CACHE_MODE="${CACHE_MODE:-Q6}"

preflight_exl3 || exit 1
ensure_tabby
if [ ! -f "$MODELS_DIR/$SUBDIR/config.json" ]; then
  echo "[err] 모델 없음: $MODELS_DIR/$SUBDIR"
  echo "      받기: exl3/tabbyAPI/.venv/bin/hf download UnstableLlama/Qwen3.6-35B-A3B-exl3-2.08bpw --local-dir $MODELS_DIR/$SUBDIR"
  echo "      + chat_template.jinja 의 enable_thinking 기본값 off 패치(현재 적용됨)"
  exit 1
fi
write_tabby_config "$SUBDIR" "$MAX_SEQ_LEN" "$CACHE_MODE"

echo ""
echo "[done] Qwen3.6-35B-A3B(2.08bpw, thinking-off 기본) 셋업. 서버 기동: ./start-tabby-server.sh (또는 llm up gpu)"
echo "       현재 코더로 복귀: ./setup-exl3.sh a-safe"
