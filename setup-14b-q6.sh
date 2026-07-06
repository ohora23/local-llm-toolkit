#!/usr/bin/env bash
# Qwen3-14B Q6_K (bartowski imatrix) 전용 Ollama 셋업
# - 14B dense, 전 레이어 GPU 상주
# - RTX 5080 16GB + flash attention + KV q8 기준
#
# 사용법: ./setup-14b-q6.sh
#   긴 컨텍스트가 필요하면:
#     NUM_CTX=32768 ./setup-14b-q6.sh    # VRAM 15GB, 듀얼모니터 빠듯
#     NUM_CTX=16384 ./setup-14b-q6.sh    # 기본, 권장

set -euo pipefail

BASE_REPO="hf.co/bartowski/Qwen_Qwen3-14B-GGUF:Q6_K"
NAME="qwen3-14b-q6"

# Qwen3-14B layer 48
: "${NUM_GPU:=48}"
: "${NUM_CTX:=16384}"

if ! pgrep -x ollama >/dev/null; then
  echo "[err] ollama 데몬 미실행."
  exit 1
fi

ENV_DUMP=$(systemctl show ollama -p Environment --value 2>/dev/null | tr ' ' '\n')
if ! echo "$ENV_DUMP" | grep -q '^OLLAMA_FLASH_ATTENTION=1$'; then
  echo "[warn] OLLAMA_FLASH_ATTENTION 미적용. apply-systemd-override.sh 먼저 권장."
fi

MODELFILE="$(mktemp)"
trap 'rm -f "$MODELFILE"' EXIT

cat > "$MODELFILE" <<EOF
FROM $BASE_REPO

PARAMETER num_gpu $NUM_GPU
PARAMETER num_ctx $NUM_CTX
PARAMETER num_batch 512
PARAMETER num_thread 8

PARAMETER temperature 0.2
PARAMETER top_p 0.9
PARAMETER repeat_penalty 1.05

PARAMETER stop "<|im_end|>"
PARAMETER stop "<|endoftext|>"
EOF

echo "[setup] Base:    $BASE_REPO"
echo "[setup] GPU:     $NUM_GPU/48 layers, ctx $NUM_CTX"

ollama create "$NAME" -f "$MODELFILE" 2>&1 | tail -3

echo ""
echo "[setup] 실행: ollama run $NAME"
