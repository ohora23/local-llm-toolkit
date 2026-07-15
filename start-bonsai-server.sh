#!/usr/bin/env bash
# Bonsai-27B (Ternary, 1.71bpw) serving — llama.cpp PrismML fork, RTX 5080 (sm_120).
# Preserved alternative: extreme-low-bit Qwen3.6-27B, huge context (262K on 16GB) + vision.
# Daily driver stays Ornith (EXL3/TabbyAPI :5000); this is a swap-in for long-context/vision jobs.
#
# One-time setup (fetches ~9GB model + fork binaries; both gitignored under bonsai-eval/):
#   git clone --depth 1 https://github.com/PrismML-Eng/Bonsai-demo.git bonsai-eval/Bonsai-demo
#   cd bonsai-eval/Bonsai-demo && bash scripts/download_binaries.sh   # prebuilt CUDA 12.8 fork (has sm_120)
#   hf download prism-ml/Ternary-Bonsai-27B-gguf \
#       Ternary-Bonsai-27B-Q2_0.gguf Ternary-Bonsai-27B-dspark-Q4_1.gguf \
#       --local-dir models/ternary-gguf/27B
#
# Measured (RTX 5080 16GB): 82 t/s plain, 148 t/s w/ SPECULATIVE=1 (code, temp0, ~0.7 accept);
# 128K=10.5GB / 262K=13.4GB VRAM with KV4=1; coding thinking-ON 6/6 (~38s/problem, slow).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
[ -f "$ROOT/config.env" ] && . "$ROOT/config.env"

DEMO="${BONSAI_DEMO_DIR:-$ROOT/bonsai-eval/Bonsai-demo}"
BIN_DIR="${BONSAI_BIN_DIR:-$DEMO/bin/cuda}"
MODEL="${BONSAI_MODEL:-$DEMO/models/ternary-gguf/27B/Ternary-Bonsai-27B-Q2_0.gguf}"
DRAFTER="${BONSAI_DRAFTER:-$DEMO/models/ternary-gguf/27B/Ternary-Bonsai-27B-dspark-Q4_1.gguf}"
PORT="${BONSAI_PORT:-5005}"
CTX="${BONSAI_CTX:-131072}"          # 262144 도 16GB에 fit (KV4=1 필요)
SPECULATIVE="${SPECULATIVE:-0}"      # 1 = dspark 드래프터로 ~1.8x (코드/temp0에서 최적)
KV4="${KV4:-0}"                      # 1 = 4-bit KV (--cache-type q4_0); 초장문(>128K)에 필요

for f in "$BIN_DIR/llama-server" "$MODEL"; do
  [ -f "$f" ] || { echo "[err] 없음: $f  (헤더의 one-time setup 참고)"; exit 1; }
done
export LD_LIBRARY_PATH="$BIN_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

ARGS=(-m "$MODEL" -ngl 99 -fa on -c "$CTX" --host 127.0.0.1 --port "$PORT")
[ "$KV4" = 1 ] && ARGS+=(--cache-type-k q4_0 --cache-type-v q4_0)
if [ "$SPECULATIVE" = 1 ]; then
  [ -f "$DRAFTER" ] || { echo "[err] 드래프터 없음: $DRAFTER"; exit 1; }
  ARGS+=(-md "$DRAFTER" --spec-type draft-dspark --spec-draft-n-max 4 -ngld 999 -np 1)
fi

echo "[bonsai] $(basename "$MODEL")  ctx=$CTX  port=$PORT  speculative=$SPECULATIVE  kv4=$KV4"
echo "[bonsai] OpenAI 호환: http://127.0.0.1:$PORT/v1   (Ornith와 GPU 배타 — 먼저 데일리 내리기)"
exec "$BIN_DIR/llama-server" "${ARGS[@]}"
