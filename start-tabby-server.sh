#!/usr/bin/env bash
# TabbyAPI(ExLlamaV3) 서버 기동. config.yml 의 모델을 GPU 적재.
# 사전: ./setup-exl3.sh a-safe (또는 b-quality) 로 셋업 완료되어 있어야 함.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/exl3-common.sh"

if [ ! -d "$VENV_DIR" ] || [ ! -f "$TABBY_DIR/config.yml" ]; then
  echo "[err] 미설치 상태. 먼저: ./setup-exl3.sh a-safe"
  exit 1
fi

echo "[info] 기동 전 VRAM:"
nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader || true

launch_tabby
