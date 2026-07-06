#!/usr/bin/env bash
# 모델 토큰 처리 속도 측정 (--verbose 출력에서 eval rate 파싱)
# 사용: ./bench.sh <model-name>

set -euo pipefail
MODEL="${1:-qwen3-coder-30b-a3b-q4}"

PROMPT='Write a Python function that takes a list of integers and returns the two numbers that sum to a target value. Include type hints, docstring, and edge case handling.'

echo "[bench] Model: $MODEL"
echo "[bench] VRAM (사전):"
nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader 2>/dev/null || true
echo ""

ollama run "$MODEL" --verbose "$PROMPT"

echo ""
echo "[bench] VRAM (사후):"
nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader 2>/dev/null || true
