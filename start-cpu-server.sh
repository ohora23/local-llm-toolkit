#!/usr/bin/env bash
# llama.cpp CPU 전용 서버 기동. active.env 의 모델을 CPU(-ngl 0)에 적재.
# GPU EXL3(포트 5000)와 독립적으로 포트 5001 에 OpenAI 호환 API 를 연다.
# 사전: ./setup-cpu.sh a-moe (또는 b-light) 로 셋업 완료되어 있어야 함.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/cpu-common.sh"

if [ ! -f "$ACTIVE_CONF" ]; then
  echo "[err] 미설치 상태. 먼저: ./setup-cpu.sh a-moe"
  exit 1
fi

echo "[info] 기동 전 RAM:"
free -h | awk 'NR==1 || /^Mem:/'
echo "[info] (참고) GPU 상태 — CPU 서버는 VRAM 을 쓰지 않음:"
nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader 2>/dev/null || true

launch_cpu_server
