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

# 워밍업: 로드 완료(포트 오픈) 후 더미 요청 1회로 cudagraph/커널 예열 → 첫 실사용 TTFT 정상화
# (예열 안 하면 첫 추론이 워밍업 아티팩트로 수 초 걸림; Ornith에서 3.4s→0.17s 확인)
( for _ in $(seq 1 180); do
    curl -sf "http://$TABBY_HOST:$TABBY_PORT/v1/models" >/dev/null 2>&1 && break
    sleep 1
  done
  curl -sf "http://$TABBY_HOST:$TABBY_PORT/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"m","messages":[{"role":"user","content":"ping"}],"max_tokens":8,"chat_template_kwargs":{"enable_thinking":false}}' \
    >/dev/null 2>&1 && echo "[warmup] 예열 완료 — 첫 실사용 TTFT 정상" ) &

launch_tabby
