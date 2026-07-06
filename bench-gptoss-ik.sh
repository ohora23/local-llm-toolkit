#!/usr/bin/env bash
# gpt-oss-120B (MXFP4) 하이브리드 GPU+CPU 벤치 — ik_llama.cpp
# RTX 5080 16GB + Ryzen 9800X3D(AVX-512) + 78GB RAM.
# --n-cpu-moe N = 앞쪽 N개 레이어의 expert 를 CPU(RAM)에, 나머지는 GPU(VRAM).
#   N 작을수록 GPU에 더 많이 → 빠르지만 VRAM↑. VRAM 한도 내 최소 N 이 최적.
set -uo pipefail
_SD="$(cd "$(dirname "$0")" && pwd)"; [ -f "$_SD/config.env" ] && . "$_SD/config.env"
IK="${IK_BIN_DIR:-${IK_DIR:-$HOME/0_AI/ik_llama.cpp}/build/bin}"
MODEL="${MODEL:-${MODEL_STORE:-$HOME/b_Models}/gpt-oss-120b-GGUF/gpt-oss-120b-mxfp4-00001-of-00003.gguf}"
THREADS="${THREADS:-8}"
PP="${PP:-512}"   # prompt(prefill) 토큰
TG="${TG:-128}"   # 생성 토큰
SWEEP="${SWEEP:-36 32 30 28 26 24}"  # --n-cpu-moe 후보(큰 값=CPU 많이=안전)

[ -f "$MODEL" ] || { echo "[err] 모델 없음: $MODEL"; exit 1; }
echo "[info] model: $(basename "$MODEL")  threads=$THREADS  pp=$PP tg=$TG"
echo "[info] GPU 베이스라인 VRAM:"; nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader

for N in $SWEEP; do
  echo; echo "===== --n-cpu-moe $N ====="
  # llama-bench: pp(prefill)·tg(gen) tok/s. OOM 이면 스킵.
  "$IK/llama-bench" -m "$MODEL" -ngl 999 --n-cpu-moe "$N" -fmoe 1 \
    -t "$THREADS" -p "$PP" -n "$TG" -r 2 2>&1 \
    | grep -E "model|pp|tg|n_cpu_moe|error|CUDA|out of memory" | tail -8 \
    || echo "[warn] N=$N 실패(OOM 가능) — 더 큰 N 사용"
done
echo
echo "[done] 가장 빠른(tg tok/s 최고) N 이 VRAM 한도 내 최적. 그 N으로 llama-server 기동 권장."