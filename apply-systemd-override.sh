#!/usr/bin/env bash
# Ollama 안정성 환경변수를 systemd drop-in 으로 영구 적용 (1회성, sudo 필요).
# flash-attention + KV 캐시 q8 + 단일 사용자/모델 → 듀얼모니터 16GB 상시 운용 안정화.
#
# 사용:  sudo ./apply-systemd-override.sh
# 동작:  drop-in 작성 → daemon-reload → restart → /proc/<pid>/environ 검증
set -euo pipefail

DROPIN_DIR="/etc/systemd/system/ollama.service.d"
DROPIN="$DROPIN_DIR/override.conf"

if [ "$(id -u)" -ne 0 ]; then
  echo "[err] root 권한 필요. 다시: sudo $0"
  exit 1
fi

echo "[setup] drop-in 작성 → $DROPIN"
mkdir -p "$DROPIN_DIR"
cat > "$DROPIN" <<'EOF'
[Service]
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_KEEP_ALIVE=30m"
EOF

# 각 변수 의미:
#   OLLAMA_FLASH_ATTENTION=1  flash attention 활성화 (메모리·속도 동시 이득)
#   OLLAMA_KV_CACHE_TYPE=q8_0 KV 캐시 양자화 → FP16 대비 KV 메모리 절반
#   OLLAMA_NUM_PARALLEL=1     단일 사용자 (동시요청 분산 안 함)
#   OLLAMA_MAX_LOADED_MODELS=1 모델 스와핑 방지 → VRAM 단편화 최소화
#   OLLAMA_KEEP_ALIVE=30m     30분 유휴 후 언로드

echo "[setup] systemctl daemon-reload"
systemctl daemon-reload

echo "[setup] ollama 재시작"
systemctl restart ollama
sleep 2

echo "[verify] systemctl show 기준:"
systemctl show ollama -p Environment --value | tr ' ' '\n' | grep '^OLLAMA_' || true

echo "[verify] 실행 중 프로세스 /proc/<pid>/environ 기준:"
PID="$(systemctl show ollama -p MainPID --value)"
if [ -n "$PID" ] && [ "$PID" != "0" ] && [ -r "/proc/$PID/environ" ]; then
  tr '\0' '\n' < "/proc/$PID/environ" | grep '^OLLAMA_' || echo "  (OLLAMA_ 변수 미검출 — 적용 실패?)"
else
  echo "  [warn] ollama MainPID 확인 불가 (서비스 미기동?)"
fi

echo "[done] 적용 완료."
