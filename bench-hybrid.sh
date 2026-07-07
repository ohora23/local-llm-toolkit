#!/usr/bin/env bash
# 하이브리드(GPU+CPU, ik_llama) MoE 모델 1개를 속도+품질4종으로 벤치.
# compare-mistral.sh 와 동일 프롬프트 → 결과 비교 가능. 큰 MoE(gpt-oss/Mistral-Small-4 등)용.
# 사용:  ./bench-hybrid.sh <model.gguf> <alias> [n_cpu_moe]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"; [ -f "$ROOT/config.env" ] && . "$ROOT/config.env"
M="$1"; ALIAS="$2"; NCM="${3:-32}"
IK="${IK_BIN_DIR:-${IK_DIR:-$HOME/0_AI/ik_llama.cpp}/build/bin}"
CTX="${CTX:-8192}"; THREADS="${THREADS:-8}"; PORT="${PORT:-5005}"
HOST=127.0.0.1; BASE="http://$HOST:$PORT"
OUT="$ROOT/logs/hybrid-compare-$ALIAS.txt"; SLOG="$ROOT/logs/hybrid-serve-$ALIAS.log"
[ -x "$IK/llama-server" ] || { echo "[err] ik_llama 없음: $IK/llama-server"; exit 1; }
[ -f "$M" ] || { echo "[err] 모델 없음: $M"; exit 1; }

_stop() { local i pids p
  for i in $(seq 1 12); do
    pids=$(ss -tlnp 2>/dev/null | grep ":$PORT " | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)
    [ -z "$pids" ] && { sleep 1; return 0; }
    for p in $pids; do kill "$p" 2>/dev/null; done; sleep 1
  done; }
trap _stop EXIT
_stop

echo "================================================================" | tee "$OUT"
echo "[model] $ALIAS  ($(basename "$M"))  n-cpu-moe=$NCM ctx=$CTX" | tee -a "$OUT"
echo "================================================================"
"$IK/llama-server" -m "$M" -a "$ALIAS" -ngl 999 --n-cpu-moe "$NCM" \
    -t "$THREADS" -c "$CTX" --host "$HOST" --port "$PORT" --jinja >"$SLOG" 2>&1 &
spid=$!
ok=0
for i in $(seq 1 150); do   # 최대 ~7.5분 (52GB mmap 로드 여유)
  kill -0 "$spid" 2>/dev/null || { echo "[err] 서버 죽음 — 로그:"; tail -15 "$SLOG" | tee -a "$OUT"; exit 1; }
  curl -s -m 8 "$BASE/v1/completions" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$ALIAS\",\"prompt\":\"hi\",\"max_tokens\":1}" 2>/dev/null | grep -q '"text"' && { ok=1; break; }
  sleep 3
done
[ "$ok" = 1 ] || { echo "[err] readiness 실패 — 로그:"; tail -15 "$SLOG" | tee -a "$OUT"; exit 1; }
vram=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1)
echo "[ok] 기동: GPU VRAM ${vram} MiB | $(grep -oE 'offloaded [0-9]+/[0-9]+ layers' "$SLOG" | tail -1)" | tee -a "$OUT"

echo ; echo "── [속도 벤치] ──" | tee -a "$OUT"
BASE="$BASE" ALIAS="$ALIAS" python3 - <<'PY' | tee -a "$OUT"
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

echo ; echo "── [품질 4종] ──" | tee -a "$OUT"
_chat() {
  echo ; echo "【$1】" | tee -a "$OUT"
  curl -s -m 240 "$BASE/v1/chat/completions" -H 'Content-Type: application/json' -d "$(python3 -c '
import json,sys
print(json.dumps({"model":sys.argv[1],"messages":[{"role":"system","content":sys.argv[2]},{"role":"user","content":sys.argv[3]}],"max_tokens":600,"temperature":0.3}))' "$ALIAS" "$2" "$3")" \
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

echo ; echo "【툴콜/에이전트】" | tee -a "$OUT"
curl -s -m 90 "$BASE/v1/chat/completions" -H 'Content-Type: application/json' -d "$(python3 -c '
import json,sys
tools=[{"type":"function","function":{"name":"get_weather","description":"도시의 현재 날씨를 반환","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}]
print(json.dumps({"model":sys.argv[1],"messages":[{"role":"user","content":"서울 날씨 알려줘"}],"tools":tools,"tool_choice":"auto","max_tokens":300}))' "$ALIAS")" \
| python3 -c 'import sys,json
try:
 d=json.load(sys.stdin);m=d["choices"][0]["message"]
 tc=m.get("tool_calls")
 if tc:print("✅ tool_calls 정상:",json.dumps(tc,ensure_ascii=False)[:300])
 else:print("❌ tool_calls 없음. content:",(m.get("content") or "")[:300])
except Exception as e:print("[parse err]",e)' | tee -a "$OUT"

_stop
echo ; echo "[done] $ALIAS → $OUT"
