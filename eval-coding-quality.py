#!/usr/bin/env python3
# 코딩 품질 객관 평가: 문제 → 모델이 코드 생성 → 생성코드를 실제 실행해 테스트 통과 여부.
# 사용: eval-coding-quality.py <BASE_URL> <MODEL_ID> [outfile]
import sys, json, re, subprocess, tempfile, os, time, urllib.request

BASE = sys.argv[1]
MODEL = sys.argv[2]
OUT = sys.argv[3] if len(sys.argv) > 3 else None

# 각 문제: 특정 함수명 구현 요구 + 결정적 테스트(asserts). /no_think 로 thinking 끔.
PROBLEMS = [
 ("two_sum",
  "Write a Python function `two_sum(nums, target)` that returns the indices (list of two ints) of the two numbers that add up to target. Assume exactly one solution. Return ONLY a single ```python code block. /no_think",
  "assert sorted(two_sum([2,7,11,15],9))==[0,1]\nassert sorted(two_sum([3,2,4],6))==[1,2]\nassert sorted(two_sum([3,3],6))==[0,1]"),
 ("merge_intervals",
  "Write a Python function `merge_intervals(intervals)` that merges all overlapping intervals (list of [start,end]) and returns the merged list sorted by start. Return ONLY a single ```python code block. /no_think",
  "assert merge_intervals([[1,3],[2,6],[8,10],[15,18]])==[[1,6],[8,10],[15,18]]\nassert merge_intervals([[1,4],[4,5]])==[[1,5]]\nassert merge_intervals([[1,4],[0,4]])==[[0,4]]"),
 ("is_balanced",
  "Write a Python function `is_balanced(s)` returning True iff the brackets ()[]{} in string s are correctly balanced/nested. Non-bracket chars ignored. Return ONLY a single ```python code block. /no_think",
  "assert is_balanced('([]{})')==True\nassert is_balanced('([)]')==False\nassert is_balanced('a(b)c[d]')==True\nassert is_balanced('(((')==False\nassert is_balanced('')==True"),
 ("coin_change",
  "Write a Python function `coin_change(coins, amount)` returning the minimum number of coins to make amount, or -1 if impossible (unbounded coins). Return ONLY a single ```python code block. /no_think",
  "assert coin_change([1,2,5],11)==3\nassert coin_change([2],3)==-1\nassert coin_change([1],0)==0\nassert coin_change([1,5,10,25],63)==6"),
 ("longest_palindrome",
  "Write a Python function `longest_palindrome(s)` returning the longest palindromic substring of s (any one if ties). Return ONLY a single ```python code block. /no_think",
  "r=longest_palindrome('babad'); assert r in ('bab','aba')\nassert longest_palindrome('cbbd')=='bb'\nassert longest_palindrome('a')=='a'\nassert longest_palindrome('forgeeksskeegfor')=='geeksskeeg'"),
 ("fix_binary_search",
  "This binary search has a bug. Fix it so `bsearch(arr, target)` returns the index of target in sorted arr, or -1. Return ONLY the corrected single ```python code block. /no_think\n\n```python\ndef bsearch(arr, target):\n    lo, hi = 0, len(arr)\n    while lo < hi:\n        mid = (lo + hi) // 2\n        if arr[mid] == target:\n            return mid\n        elif arr[mid] < target:\n            hi = mid\n        else:\n            lo = mid + 1\n    return -1\n```",
  "assert bsearch([1,3,5,7,9],7)==3\nassert bsearch([1,3,5,7,9],1)==0\nassert bsearch([1,3,5,7,9],9)==4\nassert bsearch([1,3,5,7,9],4)==-1\nassert bsearch([],5)==-1"),
]

def ask(prompt):
    payload = {"model":MODEL,"messages":[{"role":"user","content":prompt}],
               "temperature":0.0,"max_tokens":1200}
    if os.environ.get("NOTHINK") == "1":
        payload["chat_template_kwargs"] = {"enable_thinking": False}
    body = json.dumps(payload).encode()
    req = urllib.request.Request(BASE+"/v1/chat/completions", data=body,
                                 headers={"Content-Type":"application/json"})
    with urllib.request.urlopen(req, timeout=180) as r:
        d = json.load(r)
    return d["choices"][0]["message"]["content"]

def extract_code(txt):
    # <think>...</think> 제거
    txt = re.sub(r"<think>.*?</think>", "", txt, flags=re.DOTALL)
    m = re.findall(r"```(?:python)?\s*\n(.*?)```", txt, flags=re.DOTALL)
    if m:
        return max(m, key=len)  # 가장 긴 코드블록
    return txt  # 펜스 없으면 통째로

def run_test(code, tests):
    script = code + "\n\n" + tests + "\nprint('OK')\n"
    with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False) as f:
        f.write(script); path = f.name
    try:
        p = subprocess.run([sys.executable, path], capture_output=True, text=True, timeout=10)
        ok = (p.returncode == 0 and "OK" in p.stdout)
        err = "" if ok else (p.stderr.strip().splitlines()[-1] if p.stderr.strip() else "실패")
        return ok, err
    except subprocess.TimeoutExpired:
        return False, "TIMEOUT(무한루프?)"
    finally:
        os.unlink(path)

lines = [f"===== 코딩 품질 평가: {MODEL} ====="]
passed = 0
for name, prompt, tests in PROBLEMS:
    t0 = time.perf_counter()
    try:
        out = ask(prompt)
        code = extract_code(out)
        ok, err = run_test(code, tests)
    except Exception as e:
        ok, err = False, f"요청오류 {e}"
    passed += ok
    dt = time.perf_counter() - t0
    lines.append(f"[{'PASS' if ok else 'FAIL'}] {name:20s} ({dt:.1f}s)" + ("" if ok else f"  → {err}"))
lines.append(f"----- 통과: {passed}/{len(PROBLEMS)} -----")
report = "\n".join(lines)
print(report)
if OUT:
    open(OUT, "w").write(report + "\n")
