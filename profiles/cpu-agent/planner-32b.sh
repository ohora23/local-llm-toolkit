#!/usr/bin/env bash
# Profile PLANNER — Qwen3-32B (dense, thinking), CPU 전용, high-level reasoning 용.
# 설계 D: CPU=강한 dense reasoner(planner) + GPU=Qwen3-Coder-30B(fast worker) 병렬.
# dense 32B 라 MoE(active 3B)보다 추론 깊이↑. speculative decoding으로 CPU 속도 개선.
# RAM ~23GB(Q5_K_M)+draft 0.65GB → GPU worker(VRAM)와 공존 여유. ctx 16384(CPU prefill 비용 제한).
#
# ★speculative decoding (2026-07-06 실측): dense 타겟이라 이득 성립 → 2.30 → 3.97 tok/s (1.73×, acceptance 52.9%).
#   draft = Qwen3-0.6B-Q8_0 (vocab 151936 = 32B 타겟 일치). ⚠️MoE 프로파일(a-moe 등)엔 넣지 말 것 — 역효과(코더 115→53 검증됨).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../lib/cpu-common.sh"

REPO="${REPO:-unsloth/Qwen3-32B-GGUF}"
FILE="${FILE:-Qwen3-32B-Q5_K_M.gguf}"
SUBDIR="${SUBDIR:-Qwen3-32B-Q5_K_M.gguf}"
ALIAS="${ALIAS:-qwen3-32b}"
CTX="${CTX:-16384}"
EXTRA="${EXTRA:-}"
# draft 모델 (speculative). 비활성화하려면 DRAFT_FILE="" 로 셋업.
DRAFT_REPO="${DRAFT_REPO:-unsloth/Qwen3-0.6B-GGUF}"
DRAFT_FILE="${DRAFT_FILE:-Qwen3-0.6B-Q8_0.gguf}"

preflight_cpu || exit 1

# draft 먼저 resolve(다운로드) → 경로 확보 (CPU_RESOLVED_GGUF 를 잠시 씀)
if [ -n "$DRAFT_FILE" ]; then
  resolve_gguf "$DRAFT_REPO" "$DRAFT_FILE" "$DRAFT_FILE" || exit 1
  DRAFT_PATH="$CPU_RESOLVED_GGUF"
  # 검증된 speculative 플래그. n-max/p-min 은 tuning 여지.
  EXTRA="-md $DRAFT_PATH --spec-draft-n-max 16 --spec-draft-p-min 0.5 $EXTRA"
  echo "[setup] speculative draft: $(basename "$DRAFT_PATH")"
fi

resolve_gguf "$REPO" "$FILE" "$SUBDIR" || exit 1
write_cpu_config "$CPU_RESOLVED_GGUF" "$ALIAS" "$CTX" "$EXTRA"

echo ""
echo "[done] CPU planner(Qwen3-32B dense) 셋업 완료. 서버 기동:  ./start-cpu-server.sh  (또는 llm up cpu)"
echo "       endpoint(OpenAI 호환):  http://$CPU_HOST:$CPU_PORT/v1   model: $ALIAS"
