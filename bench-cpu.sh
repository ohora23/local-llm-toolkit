#!/usr/bin/env bash
# CPU llama-server 토큰 속도 측정 (스트리밍 → 생성 구간만 정밀 측정).
# EXL3/Ollama 의 eval rate 와 동일 의미로 비교 가능.
#
# 사용: ./bench-cpu.sh            # 기본 200 토큰 (CPU 는 느리니 작게)
#       ./bench-cpu.sh -n 400
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/cpu-common.sh"

MAX_TOKENS=200
[ "${1:-}" = "-n" ] && MAX_TOKENS="${2:-200}"
[ -f "$ACTIVE_CONF" ] && source "$ACTIVE_CONF"
BASE="http://${CPU_HOST:-127.0.0.1}:${CPU_PORT:-5001}"
PY=python3

echo "[bench] endpoint: $BASE  max_tokens=$MAX_TOKENS"
MODEL=$(curl -s -m 3 "$BASE/v1/models" | "$PY" -c "import sys,json;print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null || echo current)
echo "[bench] model: $MODEL  threads: ${CPU_THREADS:-?}"

# bench-exl3.sh / bench.sh 와 동일 프롬프트
PROMPT='Write a Python function that takes a list of integers and returns the two numbers that sum to a target value. Include type hints, docstring, and edge case handling.'

BASE="$BASE" MODEL="$MODEL" PROMPT="$PROMPT" MAXTOK="$MAX_TOKENS" "$PY" - <<'PY'
import os, json, time, urllib.request
base, model, prompt = os.environ["BASE"], os.environ["MODEL"], os.environ["PROMPT"]
maxtok = int(os.environ["MAXTOK"])
body = json.dumps({
    "model": model, "prompt": prompt, "max_tokens": maxtok,
    "temperature": 0.2, "top_p": 0.9, "stream": True,
}).encode()
req = urllib.request.Request(base + "/v1/completions", data=body,
                             headers={"Content-Type": "application/json"})
t0 = time.perf_counter(); t_first = None; n = 0; text = []
with urllib.request.urlopen(req) as r:
    for raw in r:
        line = raw.decode("utf-8", "ignore").strip()
        if not line.startswith("data:"): continue
        payload = line[5:].strip()
        if payload == "[DONE]": break
        try: obj = json.loads(payload)
        except Exception: continue
        ch = (obj.get("choices") or [{}])[0]
        tok = ch.get("text", "")
        if tok:
            if t_first is None: t_first = time.perf_counter()
            n += 1; text.append(tok)
t_end = time.perf_counter()
gen = (t_end - t_first) if t_first else 0.0
e2e = t_end - t0
print("".join(text)[:600])
print()
print(f"[bench] 생성 토큰(청크): {n}")
print(f"[bench] TTFT(첫 토큰까지): {(t_first-t0)*1000:.0f} ms" if t_first else "[bench] 첫 토큰 없음")
print(f"[bench] 생성 구간: {gen:.2f}s  | end-to-end: {e2e:.2f}s")
if gen > 0:
    print(f"[bench] ★ 생성 속도(eval rate): {n/gen:.1f} tok/s")
    print(f"[bench]   end-to-end 속도: {n/e2e:.1f} tok/s")
PY
