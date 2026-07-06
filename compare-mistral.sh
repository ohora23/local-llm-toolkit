#!/usr/bin/env bash
# Mistral 3종 GPU 비교 하니스.
# 각 GGUF 를 llama.cpp GPU(-ngl 99)로 순차 기동 → 속도 벤치 + 품질 4종(코딩/추론/한국어/툴콜) → 종료.
# 결과는 logs/mistral-compare-<alias>.txt 에 저장. 5000~5003 엔드포인트와 겹치지 않게 5005 사용.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
[ -f "$ROOT/config.env" ] && . "$ROOT/config.env"
LLAMA="${LLAMA_DIR:-$HOME/0_AI/llama.cpp}/build/bin/llama-server"   # CUDA 빌드(GPU)
B="${MODEL_STORE:-$HOME/b_Models}"
HOST=127.0.0.1 ; PORT=5005 ; BASE="http://$HOST:$PORT"
CTX=8192
mkdir -p "$ROOT/logs"

# alias :: gguf파일
MODELS=(
  "devstral::$B/Devstral-Small-2507-Q4_K_M.gguf"
  "magistral::$B/Magistral-Small-2509-Q4_K_M.gguf"
  "mistral-small-3.2::$B/Mistral-Small-3.2-24B-Instruct-2506-Q4_K_M.gguf"
)

[ -x "$LLAMA" ] || { echo "[err] llama-server 없음: $LLAMA"; exit 1; }

_stop() { pkill -f "llama-serv[e]r.*:$PORT" 2>/dev/null; pkill -f "port $PORT.*llama-serv[e]r" 2>/dev/null; sleep 2; }
trap _stop EXIT

run_one() {
  local alias="$1" gguf="$2"
  local OUT="$ROOT/logs/mistral-compare-$alias.txt"
  if [ ! -f "$gguf" ]; then echo "[skip] $alias — GGUF 없음: $gguf"; return; fi
  echo "================================================================" | tee "$OUT"
  echo "[model] $alias  ($(basename "$gguf"), $(du -h "$gguf"|cut -f1))" | tee -a "$OUT"
  echo "================================================================"

  # 24B dense Q4(~14GB)는 16GB(데스크톱 점유분 제외 ~13.7GB 여유)에 풀 오프로드 불가.
  # -ngl 사다리로 실제 올라가는 최대치를 탐색(99=풀 시도 → 실패시 부분 오프로드).
  local ok=0 used_ngl=""
  for NGL in 99 36 32 28; do
    _stop
    echo "[run] $alias 기동 시도: -ngl $NGL -fa -c $CTX KV q8_0"
    CUDA_VISIBLE_DEVICES=0 "$LLAMA" -m "$gguf" -a "$alias" \
        -ngl "$NGL" -fa on -c "$CTX" \
        --cache-type-k q8_0 --cache-type-v q8_0 \
        -t 8 --host "$HOST" --port "$PORT" --jinja \
        >"$ROOT/logs/mistral-serve-$alias.log" 2>&1 &
    local spid=$!
    for i in $(seq 1 60); do
      kill -0 "$spid" 2>/dev/null || break   # 프로세스 죽음(OOM 등) → 다음 NGL
      curl -s -m 2 "$BASE/v1/models" >/dev/null 2>&1 && { ok=1; break; }
      sleep 2
    done
    [ "$ok" = 1 ] && { used_ngl="$NGL"; break; }
    echo "[warn] -ngl $NGL 실패(OOM 가능) → 낮춰서 재시도" | tee -a "$OUT"
  done
  [ "$ok" = 1 ] || { echo "[err] $alias 기동 실패(모든 -ngl) — 로그:" | tee -a "$OUT"; tail -15 "$ROOT/logs/mistral-serve-$alias.log" | tee -a "$OUT"; _stop; return; }
  local vram=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1)
  local gpu_layers=$(grep -oE 'offloaded [0-9]+/[0-9]+ layers' "$ROOT/logs/mistral-serve-$alias.log" | tail -1)
  echo "[ok] 기동 성공: -ngl $used_ngl | GPU VRAM ${vram} MiB | $gpu_layers" | tee -a "$OUT"

  # ── 속도 벤치 (생성구간 tok/s) ──
  echo ; echo "── [속도 벤치] ──" | tee -a "$OUT"
  BASE="$BASE" ALIAS="$alias" python3 - <<'PY' | tee -a "$OUT"
import os,json,time,urllib.request
base,model=os.environ["BASE"],os.environ["ALIAS"]
body=json.dumps({"model":model,"prompt":"Write a Python function that takes a list of integers and returns the two numbers that sum to a target value. Include type hints, docstring, and edge case handling.","max_tokens":200,"temperature":0.2,"top_p":0.9,"stream":True}).encode()
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
print(f"생성토큰 {n}  TTFT {(tf-t0)*1000:.0f}ms  생성구간 {gen:.2f}s")
if gen>0:print(f"★ 생성속도 {n/gen:.1f} tok/s")
PY

  # ── 품질 4종 (chat completions, 비스트리밍, 앞부분만) ──
  echo ; echo "── [품질 4종] ──" | tee -a "$OUT"
  _chat() { # $1=label $2=system $3=user
    echo ; echo "【$1】" | tee -a "$OUT"
    curl -s -m 180 "$BASE/v1/chat/completions" -H 'Content-Type: application/json' -d "$(python3 -c '
import json,sys
print(json.dumps({"model":sys.argv[1],"messages":[{"role":"system","content":sys.argv[2]},{"role":"user","content":sys.argv[3]}],"max_tokens":600,"temperature":0.3}))' "$alias" "$2" "$3")" \
    | python3 -c 'import sys,json
try:
 d=json.load(sys.stdin);m=d["choices"][0]["message"]
 print((m.get("content") or "")[:900])
 if m.get("tool_calls"):print("\n[tool_calls]",json.dumps(m["tool_calls"],ensure_ascii=False)[:400])
except Exception as e:print("[parse err]",e)' | tee -a "$OUT"
  }
  _chat "코딩" "You are a senior software engineer." "Refactor this into idiomatic, well-typed code and explain briefly: def f(l):\n r=[]\n for i in range(len(l)):\n  for j in range(len(l)):\n   if i!=j and l[i]+l[j]==0: r.append((l[i],l[j]))\n return r"
  _chat "추론" "Think step by step." "3명의 용의자 A,B,C 중 한 명만 진실을 말한다. A:'내가 범인이다' B:'A는 거짓말한다' C:'내가 범인이 아니다'. 범인은 누구인가? 논리적으로 설명하라."
  _chat "한국어" "당신은 한국어 비서입니다." "베어로보틱스(Bear Robotics)라는 서빙로봇 회사를 한국어로 3문장으로 소개하고, 회사명을 절대 영어로 바꾸지 말 것."

  # 툴콜: tools 정의를 주고 함수호출 형태로 응답하는지
  echo ; echo "【툴콜/에이전트】" | tee -a "$OUT"
  curl -s -m 60 "$BASE/v1/chat/completions" -H 'Content-Type: application/json' -d "$(python3 -c '
import json,sys
tools=[{"type":"function","function":{"name":"get_weather","description":"도시의 현재 날씨를 반환","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}]
print(json.dumps({"model":sys.argv[1],"messages":[{"role":"user","content":"서울 날씨 알려줘"}],"tools":tools,"tool_choice":"auto","max_tokens":300}))' "$alias")" \
  | python3 -c 'import sys,json
try:
 d=json.load(sys.stdin);m=d["choices"][0]["message"]
 tc=m.get("tool_calls")
 if tc:print("✅ tool_calls 정상:",json.dumps(tc,ensure_ascii=False)[:300])
 else:print("❌ tool_calls 없음. content:",(m.get("content") or "")[:300])
except Exception as e:print("[parse err]",e)' | tee -a "$OUT"

  _stop
  echo ; echo "[done] $alias → $OUT"
}

for m in "${MODELS[@]}"; do run_one "${m%%::*}" "${m##*::}"; done
echo ; echo "=== 전체 완료. 결과: logs/mistral-compare-*.txt ==="