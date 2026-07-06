#!/usr/bin/env bash
# Profile A (MoE / 균형) — Qwen3-Coder-30B-A3B Q4_K_M, CPU 전용, 16K ctx
# 활성 expert 3B 라 CPU 메모리대역폭 병목에 강함 → 30B인데 CPU에서도 쓸 만함(추정 ~10-18 tok/s).
# 속도·메모리 균형 기본값(RAM ~18GB). 품질 우선이면 a-moe-q8(=Q8_0, ~32GB) 사용.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../lib/cpu-common.sh"

REPO="${REPO:-unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF}"
FILE="${FILE:-Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf}"
SUBDIR="${SUBDIR:-Qwen3-Coder-30B-A3B-Q4_K_M.gguf}"
ALIAS="${ALIAS:-qwen3-coder-30b-cpu}"
CTX="${CTX:-16384}"
EXTRA="${EXTRA:-}"

preflight_cpu || exit 1
resolve_gguf "$REPO" "$FILE" "$SUBDIR" || exit 1
write_cpu_config "$CPU_RESOLVED_GGUF" "$ALIAS" "$CTX" "$EXTRA"

echo ""
echo "[done] CPU 에이전트(MoE) 셋업 완료. 서버 기동:  ./start-cpu-server.sh"
echo "       속도 측정:                              ./bench-cpu.sh"
echo "       endpoint(OpenAI 호환):  http://$CPU_HOST:$CPU_PORT/v1   model: $ALIAS"
