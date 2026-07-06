#!/usr/bin/env bash
# Profile A-Q8 (MoE / 품질) — Qwen3-Coder-30B-A3B Q8_0, CPU 전용, 16K ctx
# 같은 코더의 Q8(거의 무손실) 버전. 30~40GB RAM 예산용(모델 ~32GB).
# A3B 라 CPU에서도 동작은 하나 Q4 대비 토큰당 읽는 바이트가 2배 → 속도는 절반 수준(추정 ~6-10 tok/s).
# 품질 최우선 백그라운드 리뷰어/리팩토링 에이전트용.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../lib/cpu-common.sh"

REPO="${REPO:-unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF}"
FILE="${FILE:-Qwen3-Coder-30B-A3B-Instruct-Q8_0.gguf}"
SUBDIR="${SUBDIR:-Qwen3-Coder-30B-A3B-Q8_0.gguf}"
ALIAS="${ALIAS:-qwen3-coder-30b-cpu}"
CTX="${CTX:-16384}"
EXTRA="${EXTRA:-}"

preflight_cpu || exit 1
resolve_gguf "$REPO" "$FILE" "$SUBDIR" || exit 1
write_cpu_config "$CPU_RESOLVED_GGUF" "$ALIAS" "$CTX" "$EXTRA"

echo ""
echo "[done] CPU 에이전트(MoE Q8) 셋업 완료. 서버 기동:  ./start-cpu-server.sh"
echo "       속도 측정:                                 ./bench-cpu.sh"
echo "       endpoint(OpenAI 호환):  http://$CPU_HOST:$CPU_PORT/v1   model: $ALIAS"
