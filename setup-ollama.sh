#!/usr/bin/env bash
# Ollama 코딩용 로컬 LLM 셋업 (16GB VRAM, 듀얼 모니터 가정)
# - flash attention + KV cache 양자화로 메모리 절감
# - 모델 크기/GPU layer 수 프리셋 제공
# - 사용법: ./setup-ollama.sh [profile]
#   profile: 14b-q6 | 14b-q6-long | 14b-q8 | 30b-moe-q4 | 30b-moe-q6 | 32b-q4 | r1-32b-q4
#   기본값: 30b-moe-q4

set -euo pipefail

PROFILE="${1:-30b-moe-q4}"

# ---- 전역 안정화 환경 변수 -----------------------------------------------
# 이 변수들은 ollama serve 가 읽으므로, 서비스 재시작 필요
export OLLAMA_FLASH_ATTENTION=1
export OLLAMA_KV_CACHE_TYPE=q8_0          # FP16 대비 KV cache 절반
export OLLAMA_NUM_PARALLEL=1              # 단일 사용자: 메모리 절약
export OLLAMA_MAX_LOADED_MODELS=1         # 모델 스와핑 방지
export OLLAMA_KEEP_ALIVE=30m

echo "[setup] OLLAMA_FLASH_ATTENTION=$OLLAMA_FLASH_ATTENTION"
echo "[setup] OLLAMA_KV_CACHE_TYPE=$OLLAMA_KV_CACHE_TYPE"

# ---- 프로파일 정의 -------------------------------------------------------
# Qwen3-14B: 48 layers
# Qwen3-Coder-30B-A3B (MoE): 62 layers (active 3B)
# Qwen3-32B: 64 layers
# DeepSeek-R1-Distill-Qwen-32B: 64 layers
case "$PROFILE" in
  14b-q6)
    BASE_REPO="hf.co/bartowski/Qwen_Qwen3-14B-GGUF:Q6_K"
    NUM_GPU=48
    NUM_CTX=16384     # 32K도 가능하나 듀얼모니터 환경에서 VRAM 빠듯 (15.2GB/16GB)
    NAME="qwen3-14b-q6"
    ;;
  14b-q6-long)
    # 32K 컨텍스트 — 듀얼모니터/브라우저 GPU 가속 OFF 권장
    BASE_REPO="hf.co/bartowski/Qwen_Qwen3-14B-GGUF:Q6_K"
    NUM_GPU=48
    NUM_CTX=32768
    NAME="qwen3-14b-q6-32k"
    ;;
  14b-q8)
    BASE_REPO="hf.co/bartowski/Qwen_Qwen3-14B-GGUF:Q8_0"
    NUM_GPU=40       # 8 layers → CPU
    NUM_CTX=16384
    NAME="qwen3-14b-q8"
    ;;
  30b-moe-q4)
    BASE_REPO="hf.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:Q4_K_M"
    NUM_GPU=50       # 12 layers → CPU; MoE expert는 자동으로 RAM 상주
    NUM_CTX=32768
    NAME="qwen3-coder-30b-a3b-q4"
    ;;
  30b-moe-q6)
    BASE_REPO="hf.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:Q6_K"
    NUM_GPU=35
    NUM_CTX=16384
    NAME="qwen3-coder-30b-a3b-q6"
    ;;
  32b-q4)
    BASE_REPO="hf.co/bartowski/Qwen_Qwen3-32B-GGUF:Q4_K_M"
    NUM_GPU=40       # 24 layers → CPU (dense라 느림)
    NUM_CTX=16384
    NAME="qwen3-32b-q4"
    ;;
  r1-32b-q4)
    BASE_REPO="hf.co/bartowski/DeepSeek-R1-Distill-Qwen-32B-GGUF:Q4_K_M"
    NUM_GPU=40
    NUM_CTX=16384
    NAME="r1-distill-32b-q4"
    ;;
  *)
    echo "Unknown profile: $PROFILE"
    echo "Available: 14b-q6 | 14b-q6-long | 14b-q8 | 30b-moe-q4 | 30b-moe-q6 | 32b-q4 | r1-32b-q4"
    exit 1
    ;;
esac

# ---- Modelfile 생성 ------------------------------------------------------
MODELFILE="$(mktemp)"
trap 'rm -f "$MODELFILE"' EXIT

cat > "$MODELFILE" <<EOF
FROM $BASE_REPO

PARAMETER num_gpu $NUM_GPU
PARAMETER num_ctx $NUM_CTX
PARAMETER num_batch 512
PARAMETER num_thread 8

# 코딩에 적합한 sampling
PARAMETER temperature 0.2
PARAMETER top_p 0.9
PARAMETER repeat_penalty 1.05

# Qwen3 계열 stop tokens
PARAMETER stop "<|im_end|>"
PARAMETER stop "<|endoftext|>"
EOF

echo "[setup] Profile: $PROFILE"
echo "[setup] Base:    $BASE_REPO"
echo "[setup] Layers:  $NUM_GPU on GPU (나머지 CPU)"
echo "[setup] Ctx:     $NUM_CTX"

# ---- ollama serve 가 환경변수를 보고 있는지 확인 ---------------------------
if ! pgrep -x ollama >/dev/null; then
  echo "[setup] ollama serve 가 실행 중이 아닙니다."
  echo "        새 터미널에서 다음을 먼저 실행하세요:"
  echo "          OLLAMA_FLASH_ATTENTION=1 OLLAMA_KV_CACHE_TYPE=q8_0 ollama serve"
  exit 1
fi

# ---- 모델 등록 -----------------------------------------------------------
echo "[setup] Creating model '$NAME' ..."
ollama create "$NAME" -f "$MODELFILE"

echo ""
echo "[setup] 완료. 실행:"
echo "  ollama run $NAME"
echo ""
echo "VRAM 모니터링:  watch -n 1 nvidia-smi"
echo "벤치마크:        ollama run $NAME --verbose '<프롬프트>'"
