#!/usr/bin/env python3
# 멀티스텝 에이전트 실전 검증: 실제 툴 제공 → 모델이 다단계 툴호출+추론으로 과제 완수하는지.
# 과제(정답 검증 가능): local-llm 디렉터리에서 줄 수 최다 .sh 파일 찾기.
import sys, json, os, glob, urllib.request
BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:5000"
NOTHINK = os.environ.get("NOTHINK", "1") == "1"
ROOT = os.path.dirname(os.path.abspath(__file__))

# ── 실제 툴 구현 ──
def list_sh_files(directory):
    fs = sorted(os.path.basename(p) for p in glob.glob(os.path.join(directory, "*.sh")))
    return json.dumps(fs)
def count_lines(filepath):
    p = filepath if os.path.isabs(filepath) else os.path.join(ROOT, filepath)
    try:
        return str(sum(1 for _ in open(p, encoding="utf-8", errors="ignore")))
    except Exception as e:
        return f"ERROR: {e}"
TOOLS_IMPL = {"list_sh_files": lambda a: list_sh_files(a["directory"]),
              "count_lines":   lambda a: count_lines(a["filepath"])}
TOOLS = [
 {"type":"function","function":{"name":"list_sh_files","description":"List .sh filenames in a directory (non-recursive).",
   "parameters":{"type":"object","properties":{"directory":{"type":"string"}},"required":["directory"]}}},
 {"type":"function","function":{"name":"count_lines","description":"Return the number of lines in a file. filepath relative to the project root or absolute.",
   "parameters":{"type":"object","properties":{"filepath":{"type":"string"}},"required":["filepath"]}}},
]

def chat(messages):
    p = {"model":"m","messages":messages,"tools":TOOLS,"tool_choice":"auto","temperature":0,"max_tokens":800}
    if NOTHINK: p["chat_template_kwargs"] = {"enable_thinking": False}
    req = urllib.request.Request(BASE+"/v1/chat/completions", data=json.dumps(p).encode(),
                                 headers={"Content-Type":"application/json"})
    with urllib.request.urlopen(req, timeout=180) as r:
        return json.load(r)["choices"][0]["message"]

messages = [
 {"role":"system","content":"You are a coding agent. Use the provided tools to answer. Call tools until you have the answer, then give a final answer."},
 {"role":"user","content":f"In the directory {ROOT}, which shell script (.sh file) has the MOST lines? Give the filename and its exact line count."},
]

print(f"=== 에이전트 루프 (thinking={'OFF' if NOTHINK else 'ON'}) ===")
ncalls = 0
for step in range(20):
    m = chat(messages)
    tcs = m.get("tool_calls") or []
    # assistant 메시지 기록(툴콜 포함)
    messages.append({"role":"assistant","content":m.get("content") or "","tool_calls":tcs})
    if not tcs:
        print(f"\n[최종답변 step{step}]\n" + (m.get("content") or "")[:500])
        break
    for tc in tcs:
        ncalls += 1
        fn = tc["function"]["name"]
        try: args = json.loads(tc["function"]["arguments"])
        except: args = {}
        try: result = TOOLS_IMPL[fn](args)
        except Exception as e: result = f"ERROR: {e}"
        short = result if len(result) < 90 else result[:90]+"..."
        print(f"  step{step} 툴콜#{ncalls}: {fn}({args}) → {short}")
        messages.append({"role":"tool","tool_call_id":tc.get("id","0"),"content":result})
else:
    print("\n[!] 20스텝 초과 — 미완")

# ── 정답 검증 ──
truth = {}
for f in glob.glob(os.path.join(ROOT,"*.sh")):
    truth[os.path.basename(f)] = sum(1 for _ in open(f, errors="ignore"))
win = max(truth, key=truth.get)
print(f"\n=== 정답: {win} ({truth[win]} lines) | 총 {ncalls} 툴콜 ===")
