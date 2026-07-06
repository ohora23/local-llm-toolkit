#!/usr/bin/env bash
# Ollama 서버를 안정성 옵션과 함께 기동
# - flash attention: 메모리/속도 동시 이득
# - KV cache q8_0: 컨텍스트 길이 사실상 2배
# - 단일 모델/단일 병렬: 듀얼 모니터 환경에서 VRAM 안정성 확보
#
# 사용: ./start-ollama-server.sh
# 이미 systemd 로 ollama가 떠 있다면 먼저 멈추세요:
#   sudo systemctl stop ollama

set -euo pipefail

if pgrep -x ollama >/dev/null; then
  echo "ollama 가 이미 실행 중입니다. 중지 후 다시 실행하세요:"
  echo "  sudo systemctl stop ollama   # 또는 pkill ollama"
  exit 1
fi

export OLLAMA_FLASH_ATTENTION=1
export OLLAMA_KV_CACHE_TYPE=q8_0
export OLLAMA_NUM_PARALLEL=1
export OLLAMA_MAX_LOADED_MODELS=1
export OLLAMA_KEEP_ALIVE=30m
# 필요시 GPU 1개만 사용하도록 고정 (멀티GPU 환경)
# export CUDA_VISIBLE_DEVICES=0

echo "환경 변수:"
env | grep ^OLLAMA_ | sort

exec ollama serve
