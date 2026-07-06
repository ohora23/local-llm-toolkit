#!/usr/bin/env bash
# Profile: Qwen3-Coder-30B-A3B Q4_K_M — Option A (Safe / 듀얼모니터 안정)
# - 32/62 layers on GPU, 30 on CPU
# - VRAM ~13.5GB 사용 → 듀얼모니터 + 브라우저 여유
# - 속도: 45~55 tok/s (MoE active expert만 GPU 왕복)
# - 추천 사용: 일상 코딩, 백그라운드로 계속 띄워두고 작업

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../lib/register-ollama.sh
source "$SCRIPT_DIR/../../lib/register-ollama.sh"

BASE_REPO="hf.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:Q4_K_M"
NAME="${NAME:-qwen3-coder-30b-a3b-q4-safe}"
NUM_GPU="${NUM_GPU:-32}"
NUM_CTX="${NUM_CTX:-16384}"

echo "[profile] Option A — Safe (듀얼모니터 안정 운영)"

preflight_ollama || exit 1
register_ollama_model "$BASE_REPO" "$NAME" "$NUM_GPU" "$NUM_CTX"

echo ""
echo "실행: ollama run $NAME"
echo "VRAM 모니터: nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader"
