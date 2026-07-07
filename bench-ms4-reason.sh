#!/usr/bin/env bash
# MS4 추론모드 검증: 같은 논리퍼즐(정답 C)을 reasoning_effort none vs high 로 비교.
# 논리오류가 Q3 quant 탓인지 thinking-off 탓인지 가림.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"; [ -f "$ROOT/config.env" ] && . "$ROOT/config.env"
S1="${1:-$HOME/b_Models/Mistral-Small-4-119B-Q3_K_M/UD-Q3_K_M/Mistral-Small-4-119B-2603-UD-Q3_K_M-00001-of-00003.gguf}"
IK="${IK_BIN_DIR:-${IK_DIR:-$HOME/0_AI/ik_llama.cpp}/build/bin}"
PORT=5005; BASE="http://127.0.0.1:$PORT"; ALIAS=ms4; NCM="${NCM:-30}"
SLOG="$ROOT/logs/ms4-reason-serve.log"; OUT="$ROOT/logs/ms4-reason.txt"
_stop(){ local i p pids; for i in $(seq 1 12); do
  pids=$(ss -tlnp 2>/dev/null|grep ":$PORT "|grep -oE 'pid=[0-9]+'|cut -d= -f2|sort -u)
  [ -z "$pids" ]&&{ sleep 1;return;}; for p in $pids;do kill $p 2>/dev/null;done;sleep 1;done;}
trap _stop EXIT; _stop
"$IK/llama-server" -m "$S1" -a "$ALIAS" -ngl 999 --n-cpu-moe $NCM -t 8 -c 8192 \
  --host 127.0.0.1 --port $PORT --jinja >"$SLOG" 2>&1 &
sp=$!
for i in $(seq 1 150); do kill -0 $sp 2>/dev/null||{ echo "[err] 서버죽음";tail -12 "$SLOG";exit 1;}
  curl -s -m 8 "$BASE/v1/completions" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$ALIAS\",\"prompt\":\"hi\",\"max_tokens\":1}" 2>/dev/null|grep -q '"text"'&&break; sleep 3; done
echo "[ok] MS4 기동 (NCM=$NCM)" | tee "$OUT"

PUZZLE="3명의 용의자 A,B,C 중 한 명만 진실을 말한다. A:'내가 범인이다' B:'A는 거짓말한다' C:'내가 범인이 아니다'. 범인은 누구인가? 논리적으로 설명하고 마지막 줄에 '정답: X' 형식으로 답하라."
ask(){ # $1=effort
  echo ; echo "════════ reasoning_effort=$1 ════════" | tee -a "$OUT"
  EFF="$1" PZ="$PUZZLE" AL="$ALIAS" BASE="$BASE" python3 - <<'PY' | tee -a "$OUT"
import os,json,urllib.request,time
base,al,eff,pz=os.environ["BASE"],os.environ["AL"],os.environ["EFF"],os.environ["PZ"]
body={"model":al,"messages":[{"role":"user","content":pz}],"max_tokens":3000,"temperature":0.1,"chat_template_kwargs":{"reasoning_effort":eff}}
t0=time.perf_counter()
req=urllib.request.Request(base+"/v1/chat/completions",data=json.dumps(body).encode(),headers={"Content-Type":"application/json"})
try:
 d=json.load(urllib.request.urlopen(req,timeout=300));m=d["choices"][0]["message"]
 rc=m.get("reasoning_content") or ""
 c=m.get("content") or ""
 print(f"[elapsed {time.perf_counter()-t0:.1f}s]  reasoning_content 길이={len(rc)}  content 길이={len(c)}")
 if rc:print("--- reasoning(앞600) ---\n"+rc[:600])
 print("--- answer ---\n"+c[-700:])
except Exception as e:print("[err]",e)
PY
}
ask none
ask high
_stop; echo ; echo "[done] → $OUT"
