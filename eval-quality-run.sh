#!/usr/bin/env bash
# 코딩 품질 head-to-head: Qwen3.6-35B-A3B(2.08bpw) vs 현재 Qwen3-Coder-30B(3.0bpw).
# 각 모델 서빙 → eval-coding-quality.py(6문제, 생성코드 실행검증) → 통과율 비교.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
[ -f "$ROOT/config.env" ] && . "$ROOT/config.env"
CFG="$ROOT/exl3/tabbyAPI/config.yml"
MODELS_DIR="$ROOT/exl3/models"
HOST=127.0.0.1; PORT=5000; BASE="http://$HOST:$PORT"
[ -f "$CFG.bak-eval" ] || cp "$CFG" "$CFG.bak-eval"

CANDS=(
  "qwen3.6-35b::Qwen3.6-35B-A3B-EXL3-2.08bpw::Q6::16384"
  "current-coder::Qwen3-Coder-30B-A3B-EXL3-3.0bpw::Q6::16384"
)

_stop(){ for pid in $(ss -tlnp 2>/dev/null|grep ":$PORT "|grep -oE 'pid=[0-9]+'|cut -d= -f2|sort -u); do kill "$pid" 2>/dev/null; done; sleep 3; }
trap '_stop; cp "$CFG.bak-eval" "$CFG"' EXIT

write_cfg(){ cat > "$CFG" <<EOF
network:
  host: $HOST
  port: $PORT
  disable_auth: true
model:
  model_dir: $MODELS_DIR
  model_name: $1
  max_seq_len: $3
  cache_mode: $2
sampling:
  override_preset:
developer:
  unsafe_launch: false
EOF
}

for c in "${CANDS[@]}"; do
  a="$(echo "$c"|cut -d: -f1)"; sub="$(echo "$c"|cut -d: -f3)"
  cm="$(echo "$c"|cut -d: -f5)"; cx="$(echo "$c"|cut -d: -f7)"
  [ -d "$MODELS_DIR/$sub" ] || { echo "[skip] $a — 폴더 없음"; continue; }
  echo "######## $a ($sub) ########"
  _stop; write_cfg "$sub" "$cm" "$cx"
  nohup "$ROOT/start-tabby-server.sh" > "$ROOT/logs/eval-serve-$a.log" 2>&1 &
  spid=$!; ok=0
  for i in $(seq 1 120); do
    curl -s -m 2 "$BASE/v1/models" >/dev/null 2>&1 && { ok=1; break; }
    kill -0 "$spid" 2>/dev/null || pgrep -f 'tabbyAPI/main.py' >/dev/null 2>&1 || { grep -qiE 'CUDA out of memory|Model unloaded' "$ROOT/logs/eval-serve-$a.log" && break; }
    sleep 2
  done
  [ "$ok" = 1 ] || { echo "[err] $a 기동 실패"; grep -iE 'out of memory|traceback' "$ROOT/logs/eval-serve-$a.log"|tail -3; _stop; continue; }
  echo "[ok] $a 기동, 평가 시작..."
  # thinking 모델(qwen3.6)만 enable_thinking=false. Qwen3-Coder는 thinking 모델 아님 → NOTHINK=0.
  nt=0; case "$a" in qwen3.6*) nt=1;; esac
  NOTHINK=$nt python3 "$ROOT/${EVAL_SCRIPT:-eval-coding-quality.py}" "$BASE" "$sub" "$ROOT/logs/${EVAL_TAG:-eval}-$a.txt"
  _stop
done
echo "=== 완료. logs/eval-*.txt ==="
