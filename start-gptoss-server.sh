#!/usr/bin/env bash
# gpt-oss-120B (MXFP4 59GiB) 하이브리드 GPU+CPU 서버 — ik_llama.cpp, 포트 5002.
# 16GB VRAM(attention+일부 expert) + 78GB RAM(나머지 expert) 으로 117B 모델 구동.
# 사전: ik_llama.cpp CUDA 빌드 + 모델 다운로드 완료.
#
# 튜닝(환경변수):
#   N_CPU_MOE  앞쪽 N개 레이어 expert를 CPU에. 30=최속(VRAM~13.7G·여유2G),
#              31~32=여유↑(27~28tok/s). 28이하=OOM. (기본 30)
#   CTX        컨텍스트(기본 8192). 키우면 VRAM↑.
set -euo pipefail
_SD="$(cd "$(dirname "$0")" && pwd)"; [ -f "$_SD/config.env" ] && . "$_SD/config.env"
IK="${IK_BIN_DIR:-${IK_DIR:-$HOME/0_AI/ik_llama.cpp}/build/bin}"
M="${GPTOSS_MODEL:-${MODEL_STORE:-$HOME/b_Models}/gpt-oss-120b-GGUF/gpt-oss-120b-mxfp4-00001-of-00003.gguf}"
NCM="${N_CPU_MOE:-32}"
CTX="${CTX:-32768}"
THREADS="${THREADS:-8}"
PORT="${PORT:-5002}"

[ -x "$IK/llama-server" ] || { echo "[err] ik_llama.cpp llama-server 없음: $IK/llama-server"; exit 1; }
[ -f "$M" ] || { echo "[err] 모델 없음: $M"; exit 1; }

echo "[info] gpt-oss-120B 하이브리드(ik_llama.cpp) → http://127.0.0.1:$PORT/v1"
echo "       n-cpu-moe=$NCM  ctx=$CTX  threads=$THREADS  (VRAM~13.7G + RAM~49G)"
echo "[info] 기동 전 VRAM:"; nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader 2>/dev/null || true
# 주의: GPU EXL3(:5000)와 VRAM(~14G)·하이브리드와 RAM이 겹쳐 동시구동 불가(택1).
exec "$IK/llama-server" -m "$M" -ngl 999 --n-cpu-moe "$NCM" -t "$THREADS" -c "$CTX" \
  --host 127.0.0.1 --port "$PORT" --jinja -a gpt-oss-120b
