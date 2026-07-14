#!/usr/bin/env bash
# Agentic 재평가: 멀티파일 리팩터(refactor-eval.py, 동작보존) A/B.
#   Ornith thinking-ON / thinking-OFF  vs  현 데일리 Qwen3-Coder-30B.
# 데몬은 exec setsid + 전체 fd 리다이렉트 + disown 으로 완전 분리(파이프/명령치환 데드락 회피).
# serve()는 절대 파이프 안에서 호출하지 않는다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
CFG="$ROOT/exl3/tabbyAPI/config.yml"; MODELS_DIR="$ROOT/exl3/models"; BASE=http://127.0.0.1:5000
SUM="$ROOT/logs/refactor-ab-summary.txt"; : > "$SUM"
SLOG="$ROOT/logs/refab-serve.log"

kill5000(){ for pid in $(ss -tlnp 2>/dev/null|grep ':5000 '|grep -oE 'pid=[0-9]+'|cut -d= -f2|sort -u); do kill -9 "$pid" 2>/dev/null; done; sleep 3; }

serve(){ # $1=folder → tabby 기동+로드대기. 성공 0 / 실패 1. 파이프 밖에서만 호출!
  local sub="$1" i
  kill5000; : > "$SLOG"
  cat > "$CFG" <<YAML
network:
  host: 127.0.0.1
  port: 5000
  disable_auth: true
model:
  model_dir: $MODELS_DIR
  model_name: $sub
  max_seq_len: 16384
  cache_mode: Q4
sampling:
  override_preset:
developer:
  unsafe_launch: false
YAML
  # 완전 분리: exec setsid 로 서브셸을 python으로 대체, 모든 fd를 SLOG/dev-null로, disown
  ( cd "$ROOT/exl3/tabbyAPI" && exec setsid .venv/bin/python main.py ) >"$SLOG" 2>&1 </dev/null &
  disown 2>/dev/null || true
  for i in $(seq 1 150); do
    grep -q "Model successfully loaded" "$SLOG" 2>/dev/null && return 0
    grep -qiE "CUDA out of memory|Traceback|Error loading" "$SLOG" 2>/dev/null && return 1
    sleep 2
  done
  return 1
}

run(){ # $1=label $2=folder $3=env
  local label="$1" sub="$2" envs="$3" loaded vram
  { echo ""; echo "######## $label ($sub) ########"; } >> "$SUM"
  echo "▶ $label 기동중..."
  if serve "$sub"; then
    loaded=$(grep "Loading model:" "$SLOG" | tail -1 | grep -oE '[^/]+$')
    vram=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits|head -1)
    echo "[ok] 로드=$loaded VRAM=${vram}MiB" | tee -a "$SUM"
    env $envs python3 "$ROOT/refactor-eval.py" "$BASE" 2>&1 | tee -a "$SUM"
  else
    { echo "[err] 서빙/로드 실패:"; tail -4 "$SLOG"; } | tee -a "$SUM"
  fi
  kill5000
}

run "Ornith thinking-ON"  "Ornith-1.0-35B-EXL3-3.0bpw" "NOTHINK=0 MAXTOK=12000"
run "Ornith thinking-OFF" "Ornith-1.0-35B-EXL3-3.0bpw" "NOTHINK=1 MAXTOK=6000"
run "Qwen3-Coder-30B"     "Qwen3-Coder-30B-A3B-EXL3-3.0bpw" "NOTHINK=1 NOKWARG=1 MAXTOK=6000"
echo "=== 완료 ===" | tee -a "$SUM"
