#!/usr/bin/env bash
# Profile: Qwen3-Coder-30B-A3B Q4_K_M — Option B (Aggressive / 최대 속도)
# - 38/62 layers on GPU, 24 on CPU
# - VRAM ~15.5GB 사용 (여유 ~300MB) — 빠듯
# - 속도: ~61 tok/s
# - 추천 사용: 단발성 코딩 세션, 끝나면 즉시 ollama stop
# - 주의: 브라우저 GPU 가속 OFF (chrome://flags) 권장

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../lib/register-ollama.sh
source "$SCRIPT_DIR/../../lib/register-ollama.sh"

BASE_REPO="hf.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:Q4_K_M"
NAME="${NAME:-qwen3-coder-30b-a3b-q4-fast}"
NUM_GPU="${NUM_GPU:-38}"
NUM_CTX="${NUM_CTX:-16384}"

echo "[profile] Option B — Aggressive (속도 우선, VRAM 빠듯)"
echo "[warn]    브라우저 GPU 가속 OFF / 세션 종료 시 'ollama stop $NAME' 권장"

preflight_ollama || exit 1
register_ollama_model "$BASE_REPO" "$NAME" "$NUM_GPU" "$NUM_CTX"

echo ""
echo "실행: ollama run $NAME"
echo "세션 종료: ollama stop $NAME"
