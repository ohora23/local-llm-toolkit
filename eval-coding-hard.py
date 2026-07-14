#!/usr/bin/env python3
# 어려운 코딩 품질 평가 (2bpw 스트레스). 생성코드 실제 실행검증.
# 사용: eval-coding-hard.py <BASE_URL> <MODEL_ID> [outfile]   (env NOTHINK=1 → enable_thinking:false)
import sys, json, re, subprocess, tempfile, os, time, urllib.request
BASE, MODEL = sys.argv[1], sys.argv[2]
OUT = sys.argv[3] if len(sys.argv) > 3 else None

PROBLEMS = [
 ("LFU_cache",
  "Implement `LFUCache` class: `__init__(self, capacity)`, `get(self,key)` returns value or -1, `put(self,key,value)`. On capacity overflow evict the least-frequently-used key; break ties by least-recently-used. O(1) amortized. Return ONLY one ```python code block.",
  "c=LFUCache(2)\nc.put(1,1); c.put(2,2)\nassert c.get(1)==1\nc.put(3,3)\nassert c.get(2)==-1\nassert c.get(3)==3\nc.put(4,4)\nassert c.get(1)==-1\nassert c.get(3)==3\nassert c.get(4)==4"),
 ("min_heap",
  "Implement a `MinHeap` class from scratch (no heapq): `push(self,x)`, `pop(self)` removes and returns the minimum, `peek(self)` returns min without removing, `__len__`. Return ONLY one ```python code block.",
  "h=MinHeap()\nfor x in [5,3,8,1,9,2,7]: h.push(x)\nassert h.peek()==1\nassert len(h)==7\nout=[h.pop() for _ in range(7)]\nassert out==[1,2,3,5,7,8,9]\nassert len(h)==0"),
 ("dijkstra",
  "Write `dijkstra(graph, start)` returning a dict of shortest distances from start to every node. graph is {node: {neighbor: weight}} with non-negative weights. Return ONLY one ```python code block.",
  "g={'A':{'B':1,'C':4},'B':{'C':2,'D':5},'C':{'D':1},'D':{}}\nassert dijkstra(g,'A')=={'A':0,'B':1,'C':3,'D':4}\ng2={'X':{'Y':10},'Y':{'Z':1},'Z':{'X':1}}\nassert dijkstra(g2,'X')=={'X':0,'Y':10,'Z':11}"),
 ("wildcard_match",
  "Write `is_match(s, p)` for wildcard pattern matching where '?' matches any single char and '*' matches any sequence (including empty). Return True/False. Return ONLY one ```python code block.",
  "assert is_match('aa','a')==False\nassert is_match('aa','*')==True\nassert is_match('cb','?a')==False\nassert is_match('adceb','*a*b')==True\nassert is_match('acdcb','a*c?b')==False\nassert is_match('','*')==True\nassert is_match('','')==True"),
 ("edit_distance",
  "Write `edit_distance(a, b)` returning the Levenshtein edit distance (min insert/delete/replace) between strings a and b. Return ONLY one ```python code block.",
  "assert edit_distance('horse','ros')==3\nassert edit_distance('intention','execution')==5\nassert edit_distance('','abc')==3\nassert edit_distance('abc','abc')==0\nassert edit_distance('sunday','saturday')==3"),
 ("calculator",
  "Write `calc(expr)` that evaluates a math expression string with +, -, * and non-negative integers, honoring operator precedence (* before +/-). No parentheses. Do NOT use eval(). Return ONLY one ```python code block.",
  "assert calc('3+2*2')==7\nassert calc('2*3+4*5')==26\nassert calc('10-2*3')==4\nassert calc('2*2*2+1')==9\nassert calc('100')==100\nassert calc('1+2+3+4')==10"),
]

def ask(prompt):
    msgs=[{"role":"user","content":prompt}]
    if os.environ.get("SYSPROMPT"): msgs.insert(0,{"role":"system","content":os.environ["SYSPROMPT"]})
    payload={"model":MODEL,"messages":msgs,"temperature":0.0,"max_tokens":int(os.environ.get("MAXTOK","2000"))}
    if os.environ.get("NOTHINK")=="1": payload["chat_template_kwargs"]={"enable_thinking":False}
    req=urllib.request.Request(BASE+"/v1/chat/completions",data=json.dumps(payload).encode(),headers={"Content-Type":"application/json"})
    with urllib.request.urlopen(req,timeout=240) as r: return json.load(r)["choices"][0]["message"]["content"] or ""

def extract_code(txt):
    txt=re.sub(r"<think>.*?</think>","",txt,flags=re.DOTALL)
    m=re.findall(r"```(?:python)?\s*\n(.*?)```",txt,flags=re.DOTALL)
    return max(m,key=len) if m else txt

def run_test(code,tests):
    script=code+"\n\n"+tests+"\nprint('OK')\n"
    with tempfile.NamedTemporaryFile("w",suffix=".py",delete=False) as f: f.write(script); path=f.name
    try:
        p=subprocess.run([sys.executable,path],capture_output=True,text=True,timeout=15)
        ok=(p.returncode==0 and "OK" in p.stdout)
        return ok,("" if ok else (p.stderr.strip().splitlines()[-1] if p.stderr.strip() else "실패"))
    except subprocess.TimeoutExpired: return False,"TIMEOUT"
    finally: os.unlink(path)

lines=[f"===== 어려운 코딩 평가: {MODEL} (NOTHINK={os.environ.get('NOTHINK','0')}) ====="]; passed=0
for name,prompt,tests in PROBLEMS:
    t0=time.perf_counter()
    try:
        code=extract_code(ask(prompt)); ok,err=run_test(code,tests)
    except Exception as e: ok,err=False,f"요청오류 {e}"
    passed+=ok; dt=time.perf_counter()-t0
    lines.append(f"[{'PASS' if ok else 'FAIL'}] {name:16s} ({dt:.1f}s)"+("" if ok else f"  → {err}"))
lines.append(f"----- 통과: {passed}/{len(PROBLEMS)} -----")
rep="\n".join(lines); print(rep)
if OUT: open(OUT,"w").write(rep+"\n")
