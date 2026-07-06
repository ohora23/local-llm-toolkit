#!/usr/bin/env bash
# Profile B (Light / 속도) — Qwen3-4B-Instruct-2507 Q4_K_M, CPU 전용, 32K ctx
# 빠른 보조/서브에이전트·간단 작업·요약용 (추정 ~20-35 tok/s). RAM ~3GB.
# dense 4B 라 가볍고 컨텍스트를 넉넉히(32K) 줘도 RAM 여유 충분.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../lib/cpu-common.sh"

REPO="${REPO:-unsloth/Qwen3-4B-Instruct-2507-GGUF}"
FILE="${FILE:-Qwen3-4B-Instruct-2507-Q4_K_M.gguf}"
SUBDIR="${SUBDIR:-Qwen3-4B-Instruct-2507-Q4_K_M.gguf}"
ALIAS="${ALIAS:-qwen3-4b-cpu}"
CTX="${CTX:-32768}"
EXTRA="${EXTRA:-}"

preflight_cpu || exit 1
resolve_gguf "$REPO" "$FILE" "$SUBDIR" || exit 1
write_cpu_config "$CPU_RESOLVED_GGUF" "$ALIAS" "$CTX" "$EXTRA"

echo ""
echo "[done] CPU 에이전트(Light) 셋업 완료. 서버 기동:  ./start-cpu-server.sh"
echo "       속도 측정:                                ./bench-cpu.sh"
echo "       endpoint(OpenAI 호환):  http://$CPU_HOST:$CPU_PORT/v1   model: $ALIAS"
