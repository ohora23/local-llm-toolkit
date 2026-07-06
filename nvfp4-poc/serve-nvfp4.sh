#!/usr/bin/env bash
# NVFP4 PoC — vLLM 서빙 (RTX 5080 sm_120, FP4 텐서코어 GEMM).
# ★ nvcc 13.0(torch cu130 매칭) + venv/bin(ninja) + CUDA_HOME=cu13 필요. FP4 커널은 최초 JIT 컴파일(수 분).
set -euo pipefail
POC="$(cd "$(dirname "$0")" && pwd)"
CU13="$POC/.venv/lib/python3.12/site-packages/nvidia/cu13"
export CUDA_HOME="$CU13"
export PATH="$POC/.venv/bin:$CU13/bin:$PATH"
# FP4 커널 링크: cu13/lib(libcudart.so 심링크 필요)를 링커/런타임 경로에 추가
export LIBRARY_PATH="$CU13/lib:${LIBRARY_PATH:-}"
export LD_LIBRARY_PATH="$CU13/lib:${LD_LIBRARY_PATH:-}"
# ★ FP4 커널 ninja 컴파일 병렬도 제한. 무제한(=16코어)이면 cicc 각 ~5GB×16 > 78GB RAM → OOM killer가 컴파일러 죽임(무음 사망).
export MAX_JOBS="${MAX_JOBS:-4}"     # 4×~5GB ≈ 20GB peak, 안전
export NVCC_THREADS="${NVCC_THREADS:-1}"
MODEL="${MODEL:-$POC/models/Llama-3.1-8B-Instruct-NVFP4}"
exec "$POC/.venv/bin/vllm" serve "$MODEL" \
  --served-model-name llama-nvfp4 --port 5006 \
  --max-model-len 8192 --gpu-memory-utilization 0.85
