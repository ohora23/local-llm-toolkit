#!/usr/bin/env bash
# 16GB EXL3 후보 비교 (TabbyAPI, gpu:5000). 각 모델을 config.yml에 꽂아 순차 서빙 → 속도+코딩품질.
# 기준선: Qwen3-Coder-30B-A3B-EXL3-3.0bpw (~115 tok/s).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
[ -f "$ROOT/config.env" ] && . "$ROOT/config.env"
CFG="$ROOT/exl3/tabbyAPI/config.yml"
MODELS_DIR="$ROOT/exl3/models"
HOST=127.0.0.1; PORT=5000; BASE="http://$HOST:$PORT"
mkdir -p "$ROOT/logs"
[ -f "$CFG.bak-compare" ] || cp "$CFG" "$CFG.bak-compare"

# 별칭::모델폴더::cache_mode::ctx
CANDS=(
  "qwen3.6-35b-a3b::Qwen3.6-35B-A3B-EXL3-2.08bpw::Q6::16384"
)
# 이전 테스트 완료(logs/exl3-compare-{devstral,qwen3.6-27b}.txt):
#   "devstral::Devstral-Small-2505-EXL3-4.0bpw::Q6::16384"
#   "qwen3.6-27b::Qwen3.6-27B-EXL3-3.08bpw::Q4::8192"

_stop() { for pid in $(ss -tlnp 2>/dev/null | grep ":$PORT " | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u); do kill "$pid" 2>/dev/null; done; sleep 3; }
trap '_stop; cp "$CFG.bak-compare" "$CFG"' EXIT

write_cfg() { # $1=model_subdir $2=cache $3=ctx
  cat > "$CFG" <<EOF
# 임시 (compare-exl3-candidates.sh). 원복은 config.yml.bak-compare.
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

run_one() {
  local alias="$1" sub="$2" cache="$3" ctx="$4"
  local OUT="$ROOT/logs/exl3-compare-$alias.txt"
  [ -d "$MODELS_DIR/$sub" ] || { echo "[skip] $alias — 폴더 없음: $sub"; return; }
  echo "================ $alias ($sub, cache=$cache ctx=$ctx) ================" | tee "$OUT"
  _stop
  write_cfg "$sub" "$cache" "$ctx"
  nohup "$ROOT/start-tabby-server.sh" > "$ROOT/logs/exl3-serve-$alias.log" 2>&1 &
  local spid=$!
  local ok=0
  for i in $(seq 1 120); do
    curl -s -m 2 "$BASE/v1/models" >/dev/null 2>&1 && { ok=1; break; }
    # 서버 프로세스(및 자식 python)가 완전히 죽었으면 실패로 간주
    kill -0 "$spid" 2>/dev/null || pgrep -f 'tabbyAPI/main.py' >/dev/null 2>&1 || { grep -qiE 'CUDA out of memory|Model unloaded' "$ROOT/logs/exl3-serve-$alias.log" && break; }
    sleep 2
  done
  [ "$ok" = 1 ] || { echo "[err] $alias 기동 실패:" | tee -a "$OUT"; grep -iE 'out of memory|traceback|OOM' "$ROOT/logs/exl3-serve-$alias.log" | tail -5 | tee -a "$OUT"; _stop; return; }
  # TabbyAPI는 inline_model_loading 미설정 시 요청 model명을 무시하고 로드된 모델 사용 → 라벨은 config값 사용
  local mid vram
  mid="$sub"
  vram=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null|head -1)
  echo "[ok] served=$mid | VRAM ${vram}MiB" | tee -a "$OUT"

  # 속도 벤치 (2회)
  echo "-- 속도 --" | tee -a "$OUT"
  for r in 1 2; do
  BASE="$BASE" MID="$mid" python3 - <<'PY' | tee -a "$OUT"
import os,json,time,urllib.request
base,mid=os.environ["BASE"],os.environ["MID"]
body=json.dumps({"model":mid,"prompt":"Write a Python function that takes a list of integers and returns the two numbers that sum to a target value. Include type hints, docstring, and edge case handling.","max_tokens":300,"temperature":0.2,"top_p":0.9,"stream":True}).encode()
req=urllib.request.Request(base+"/v1/completions",data=body,headers={"Content-Type":"application/json"})
t0=time.perf_counter();tf=None;n=0
with urllib.request.urlopen(req) as r:
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
print(f"   {n/gen:.1f} tok/s (토큰 {n}, TTFT {(tf-t0)*1000:.0f}ms)")
PY
  done

  # 코딩 품질 (chat, 비스트림, 앞부분)
  echo "-- 코딩 품질 --" | tee -a "$OUT"
  curl -s -m 120 "$BASE/v1/chat/completions" -H 'Content-Type: application/json' -d "$(python3 -c '
import json,sys
print(json.dumps({"model":sys.argv[1],"messages":[{"role":"user","content":"Implement an LRU cache class in Python with O(1) get/put using a doubly linked list + dict. Include a short docstring. Code only."}],"max_tokens":700,"temperature":0.2}))' "$mid")" \
  | python3 -c 'import sys,json
try:
 d=json.load(sys.stdin);print(d["choices"][0]["message"]["content"][:1200])
except Exception as e:print("[parse err]",e)' | tee -a "$OUT"

  _stop
  echo "[done] $alias → $OUT"
}

for c in "${CANDS[@]}"; do
  a="$(echo "$c"|cut -d: -f1)"; sub="$(echo "$c"|cut -d: -f3)"
  cm="$(echo "$c"|cut -d: -f5)"; cx="$(echo "$c"|cut -d: -f7)"
  run_one "$a" "$sub" "$cm" "$cx"
done
echo "=== 완료. 결과: logs/exl3-compare-*.txt (기준선 Qwen3-Coder-30B ~115 tok/s) ==="