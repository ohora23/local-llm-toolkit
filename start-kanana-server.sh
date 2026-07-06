#!/usr/bin/env bash
# Kanana-2-30B-A3B-Instruct (한국어 네이티브, MoE A3B) GPU 서버 — llama.cpp, 포트 5003.
# EXL3 불가(deepseek_v3 arch) → GGUF(Q4_K_M)로 변환해 GPU 구동. 한국어 에이전트 최적.
# 사전: convert+quantize 완료 + kanana2 지원 llama.cpp 빌드.
#
# 튜닝(환경변수): N_CPU_MOE(앞 N레이어 expert를 CPU에; Q4 18GB라 16GB fit 위해 기본 18),
#                 CTX(기본 16384).
set -euo pipefail
_SD="$(cd "$(dirname "$0")" && pwd)"; [ -f "$_SD/config.env" ] && . "$_SD/config.env"
BIN="${LLAMA_CUDA_BIN:-${LLAMA_DIR:-$HOME/0_AI/llama.cpp}/build/bin/llama-server}"
M="${KANANA_MODEL:-${MODEL_STORE:-$HOME/b_Models}/kanana-2-30b-a3b-instruct-2601-Q4_K_M.gguf}"
NCM="${N_CPU_MOE:-18}"
CTX="${CTX:-16384}"
THREADS="${THREADS:-8}"
PORT="${PORT:-5003}"

[ -x "$BIN" ] || { echo "[err] llama.cpp llama-server 없음: $BIN"; exit 1; }
[ -f "$M" ] || { echo "[err] 모델 없음: $M"; exit 1; }

echo "[info] Kanana-2 (한국어, llama.cpp) → http://127.0.0.1:$PORT/v1"
echo "       n-cpu-moe=$NCM  ctx=$CTX  threads=$THREADS  (VRAM~14G)"
nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader 2>/dev/null || true
# 주의: GPU(EXL3)·hyb 와 VRAM 겹쳐 동시구동 불가(택1).
exec "$BIN" -m "$M" -ngl 99 --n-cpu-moe "$NCM" -t "$THREADS" -c "$CTX" \
  --host 127.0.0.1 --port "$PORT" --jinja -a kanana-2
