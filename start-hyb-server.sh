#!/usr/bin/env bash
# Mistral-Small-4-119B (119B MoE / 활성 6B) 하이브리드 GPU+CPU 서버 — ik_llama.cpp, 포트 5002.
# 16GB VRAM(attention+일부 expert) + RAM(나머지 expert)으로 119B 구동.
# 사전: ik_llama.cpp CUDA 빌드 + 모델(./download-model.sh hyb) 완료.
#
# 튜닝(환경변수):
#   N_CPU_MOE  앞쪽 N레이어 expert를 CPU에. 31=VRAM~13G(기본, 안전). 낮추면 빠르나 OOM 위험, 높이면 느림·RAM↑.
#   CTX        컨텍스트(기본 8192). 키우면 VRAM↑.
#   추론 모드   기본 off. 켜려면 요청에 chat_template_kwargs:{"reasoning_effort":"high"} 전달.
set -euo pipefail
_SD="$(cd "$(dirname "$0")" && pwd)"; [ -f "$_SD/config.env" ] && . "$_SD/config.env"
IK="${IK_BIN_DIR:-${IK_DIR:-$HOME/0_AI/ik_llama.cpp}/build/bin}"
M="${HYB_MODEL:-${MODEL_STORE:-$HOME/b_Models}/Mistral-Small-4-119B-Q4_K_XL/UD-Q4_K_XL/Mistral-Small-4-119B-2603-UD-Q4_K_XL-00001-of-00003.gguf}"
NCM="${N_CPU_MOE:-31}"
CTX="${CTX:-8192}"
THREADS="${THREADS:-8}"
PORT="${PORT:-5002}"
export GGML_CUDA_NO_PINNED="${GGML_CUDA_NO_PINNED:-1}"   # 74G 모델 / RAM 여유 확보(핀 메모리 회피)

[ -x "$IK/llama-server" ] || { echo "[err] ik_llama.cpp llama-server 없음: $IK/llama-server"; exit 1; }
[ -f "$M" ] || { echo "[err] 모델 없음: $M  (먼저: ./download-model.sh hyb)"; exit 1; }

echo "[info] Mistral-Small-4 하이브리드(ik_llama.cpp) → http://127.0.0.1:$PORT/v1"
echo "       n-cpu-moe=$NCM  ctx=$CTX  threads=$THREADS  (VRAM~13G + RAM~60G)"
nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader 2>/dev/null || true
# 주의: GPU EXL3(:5000)·ko 와 VRAM·RAM 겹쳐 동시구동 불가(택1).
exec "$IK/llama-server" -m "$M" -ngl 999 --n-cpu-moe "$NCM" -t "$THREADS" -c "$CTX" \
  --host 127.0.0.1 --port "$PORT" --jinja -a mistral-small-4
