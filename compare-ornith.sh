#!/usr/bin/env bash
# Ornith-1.0-35B(EXL3 3.0bpw) vs 현 데일리 드라이버 Qwen3-Coder-30B-A3B(3.0bpw) head-to-head.
# 각 모델 순차 서빙(gpu:5000, VRAM 배타) → 속도(tok/s) + 코딩 품질(eval-coding-quality.py, 6문제 실행검증 통과율).
# Ornith는 reasoning 모델이라 NOTHINK=1(enable_thinking:false)로 공정 비교. 둘 다 Q6/16384로 동일 조건.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
[ -f "$ROOT/config.env" ] && . "$ROOT/config.env"
CFG="$ROOT/exl3/tabbyAPI/config.yml"
MODELS_DIR="$ROOT/exl3/models"
HOST=127.0.0.1; PORT=5000; BASE="http://$HOST:$PORT"
mkdir -p "$ROOT/logs"
SUMMARY="$ROOT/logs/ornith-vs-coder-summary.txt"
: > "$SUMMARY"
[ -f "$CFG.bak-ornith" ] || cp "$CFG" "$CFG.bak-ornith" 2>/dev/null || true

# 별칭::폴더::cache::ctx::nothink
# Ornith 산출물 14.4GiB라 16GB에 Q6 KV는 빠듯 → 양쪽 Q4/16384로 통일(공정+OOM방지).
CANDS=(
  "ornith::Ornith-1.0-35B-EXL3-3.0bpw::Q4::16384::1"
  "current-coder::Qwen3-Coder-30B-A3B-EXL3-3.0bpw::Q4::16384::0"
)

_stop(){ for pid in $(ss -tlnp 2>/dev/null|grep ":$PORT "|grep -oE 'pid=[0-9]+'|cut -d= -f2|sort -u); do kill "$pid" 2>/dev/null; done; sleep 3; }
trap '_stop; [ -f "$CFG.bak-ornith" ] && cp "$CFG.bak-ornith" "$CFG"' EXIT

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

speed_test(){ # $1=model_id  → "NN.N tok/s"
  BASE="$BASE" MID="$1" python3 - <<'PY'
import os,json,time,urllib.request
base,mid=os.environ["BASE"],os.environ["MID"]
body=json.dumps({"model":mid,"prompt":"Write a Python function that returns the two numbers summing to a target. Type hints, docstring, edge cases.","max_tokens":300,"temperature":0.2,"top_p":0.9,"stream":True}).encode()
req=urllib.request.Request(base+"/v1/completions",data=body,headers={"Content-Type":"application/json"})
t0=time.perf_counter();tf=None;n=0
try:
  with urllib.request.urlopen(req,timeout=120) as r:
    for raw in r:
      s=raw.decode("utf-8","ignore").strip()
      if not s.startswith("data:"):continue
      p=s[5:].strip()
      if p=="[DONE]":break
      try:o=json.loads(p)
      except:continue
      tok=(o.get("choices") or [{}])[0].get("text","")
      if tok:
        if tf is None:tf=time.perf_counter()
        n+=1
  te=time.perf_counter();gen=(te-tf) if tf else 0
  print(f"{n/gen:.1f} tok/s (토큰 {n}, TTFT {(tf-t0)*1000:.0f}ms)" if gen>0 else "측정실패")
except Exception as e:
  print(f"측정오류 {e}")
PY
}

for c in "${CANDS[@]}"; do
  a="${c%%::*}"; rest="${c#*::}"
  sub="${rest%%::*}"; rest="${rest#*::}"
  cm="${rest%%::*}"; rest="${rest#*::}"
  cx="${rest%%::*}"; nt="${rest##*::}"
  [ -d "$MODELS_DIR/$sub" ] || { echo "[skip] $a — 폴더 없음: $sub" | tee -a "$SUMMARY"; continue; }
  echo "######## $a ($sub, cache=$cm ctx=$cx nothink=$nt) ########" | tee -a "$SUMMARY"
  _stop; write_cfg "$sub" "$cm" "$cx"
  nohup "$ROOT/start-tabby-server.sh" > "$ROOT/logs/cmp-serve-$a.log" 2>&1 &
  spid=$!; ok=0
  for i in $(seq 1 150); do
    curl -s -m 2 "$BASE/v1/models" >/dev/null 2>&1 && { ok=1; break; }
    kill -0 "$spid" 2>/dev/null || pgrep -f 'tabbyAPI/main.py' >/dev/null 2>&1 || { grep -qiE 'CUDA out of memory|Model unloaded|Traceback' "$ROOT/logs/cmp-serve-$a.log" && break; }
    sleep 2
  done
  [ "$ok" = 1 ] || { echo "[err] $a 기동 실패:" | tee -a "$SUMMARY"; grep -iE 'out of memory|traceback|error' "$ROOT/logs/cmp-serve-$a.log"|tail -5 | tee -a "$SUMMARY"; _stop; continue; }
  vram=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null|head -1)
  echo "[ok] 기동 | VRAM ${vram}MiB" | tee -a "$SUMMARY"
  echo "속도: $(speed_test "$sub")" | tee -a "$SUMMARY"
  ES="${EVAL_SCRIPT:-eval-coding-quality.py}"; ET="${EVAL_TAG:-cmp-quality}"
  echo "품질(실행검증, $ES):" | tee -a "$SUMMARY"
  NOTHINK=$nt python3 "$ROOT/$ES" "$BASE" "$sub" "$ROOT/logs/$ET-$a.txt"
  grep -E "통과:|^\[PASS|^\[FAIL" "$ROOT/logs/$ET-$a.txt" | tee -a "$SUMMARY"
  echo "" | tee -a "$SUMMARY"
  _stop
done
echo "=== 완료. 요약: $SUMMARY | 상세: logs/cmp-quality-*.txt ===" | tee -a "$SUMMARY"
