#!/usr/bin/env python3
# 장문 recall(needle-in-haystack): 긴 filler 중간(여러 깊이)에 needle 심고 끝에서 질문 → 정답 포함 여부.
# 실제 로드된 모델로 감. 사용: needle-recall.py <BASE> <approx_tokens> <depth_frac ...>
import sys, json, time, urllib.request

BASE = sys.argv[1]
APPROX = int(sys.argv[2])
DEPTHS = [float(x) for x in sys.argv[3:]] or [0.1, 0.5, 0.9]

NEEDLE_VAL = "MAGENTA-7291"
NEEDLE = f"IMPORTANT FACT: The secret authorization passcode for the Zeta project is {NEEDLE_VAL}. Remember this exactly."
QUESTION = ("Based ONLY on the document above, what is the secret authorization passcode "
            "for the Zeta project? Answer with just the passcode, nothing else.")
FILLER = "The quarterly logistics report notes that warehouse throughput remained stable across all regional distribution centers during the review period. "

def build(approx_tokens, depth):
    n_lines = max(10, int(approx_tokens / 29))   # 실측 ~29 tok/line (Ornith tokenizer)
    lines = [f"[para {i}] {FILLER}" for i in range(n_lines)]
    lines.insert(int(n_lines * depth), NEEDLE)
    return "DOCUMENT START.\n" + "\n".join(lines) + "\nDOCUMENT END.\n\n" + QUESTION

def ask(prompt):
    p = {"model":"m","messages":[{"role":"user","content":prompt}],"temperature":0,
         "max_tokens":40,"chat_template_kwargs":{"enable_thinking":False}}
    req = urllib.request.Request(BASE+"/v1/chat/completions", data=json.dumps(p).encode(),
                                 headers={"Content-Type":"application/json"})
    with urllib.request.urlopen(req, timeout=600) as r:
        d = json.load(r)
    return (d["choices"][0]["message"].get("content") or ""), (d.get("usage") or {})

print(f"=== Needle-in-haystack recall (목표~{APPROX} tok) ===")
passed = 0
for depth in DEPTHS:
    prompt = build(APPROX, depth)
    t0 = time.perf_counter()
    try:
        ans, usage = ask(prompt)
        dt = time.perf_counter() - t0
        ptok = usage.get("prompt_tokens", "?")
        ok = NEEDLE_VAL in ans
        passed += ok
        print(f"[{'PASS' if ok else 'FAIL'}] depth={int(depth*100):>3}% | prompt_tokens={ptok} | {dt:.1f}s | 응답={ans.strip()[:50]!r}")
    except Exception as e:
        print(f"[ERR ] depth={int(depth*100):>3}% → {e}")
print(f"----- recall: {passed}/{len(DEPTHS)} -----")
