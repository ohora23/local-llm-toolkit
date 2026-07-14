#!/usr/bin/env python3
# 멀티파일 리팩터 검증: 다파일 코드베이스(중복 포함) 제공 → "동작보존 리팩터" 지시 →
# 리팩터된 파일들을 원본 테스트로 실행해 통과여부 채점. env NOTHINK=1 → enable_thinking:false.
import sys, os, re, json, subprocess, tempfile, shutil, urllib.request
BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:5000"
NOTHINK = os.environ.get("NOTHINK", "1") == "1"

BANK_PY = '''\
class InsufficientFunds(Exception):
    pass

class InvalidAmount(Exception):
    pass

class Account:
    def __init__(self, owner, balance=0):
        self.owner = owner
        self.balance = balance
        self.history = []

    def deposit(self, amount):
        if not isinstance(amount, (int, float)):
            raise InvalidAmount("amount must be a number")
        if amount <= 0:
            raise InvalidAmount("amount must be positive")
        self.balance += amount
        self.history.append(("deposit", amount))
        return self.balance

    def withdraw(self, amount):
        if not isinstance(amount, (int, float)):
            raise InvalidAmount("amount must be a number")
        if amount <= 0:
            raise InvalidAmount("amount must be positive")
        if amount > self.balance:
            raise InsufficientFunds("not enough balance")
        self.balance -= amount
        self.history.append(("withdraw", amount))
        return self.balance

    def apply_interest(self, rate):
        if not isinstance(rate, (int, float)):
            raise InvalidAmount("rate must be a number")
        if rate <= 0:
            raise InvalidAmount("rate must be positive")
        earned = self.balance * rate
        self.balance += earned
        self.history.append(("interest", earned))
        return self.balance


class Bank:
    def __init__(self):
        self.accounts = {}

    def open(self, owner, balance=0):
        acc = Account(owner, balance)
        self.accounts[owner] = acc
        return acc

    def transfer(self, src, dst, amount):
        if not isinstance(amount, (int, float)):
            raise InvalidAmount("amount must be a number")
        if amount <= 0:
            raise InvalidAmount("amount must be positive")
        a = self.accounts[src]
        b = self.accounts[dst]
        if amount > a.balance:
            raise InsufficientFunds("not enough balance")
        a.balance -= amount
        b.balance += amount
        a.history.append(("transfer_out", amount))
        b.history.append(("transfer_in", amount))
        return a.balance
'''

REPORT_PY = '''\
def account_summary(acc):
    lines = []
    lines.append("Account: " + str(acc.owner))
    lines.append("Balance: " + str(acc.balance))
    lines.append("Transactions: " + str(len(acc.history)))
    return "\\n".join(lines)

def bank_summary(bank):
    lines = []
    lines.append("Accounts: " + str(len(bank.accounts)))
    total = sum(a.balance for a in bank.accounts.values())
    lines.append("Total balance: " + str(total))
    for owner, acc in bank.accounts.items():
        lines.append("Account: " + str(acc.owner))
        lines.append("Balance: " + str(acc.balance))
        lines.append("Transactions: " + str(len(acc.history)))
    return "\\n".join(lines)
'''

# 원본(불변) 테스트 — 리팩터 후에도 통과해야 함.
TEST_PY = '''\
from bank import Account, Bank, InsufficientFunds, InvalidAmount
from report import account_summary, bank_summary

b = Bank()
a = b.open("alice", 100)
c = b.open("bob", 50)
assert a.deposit(50) == 150
assert a.withdraw(30) == 120
b.transfer("alice", "bob", 20)
assert a.balance == 100 and c.balance == 70
assert round(b.open("carol", 200).apply_interest(0.1), 6) == 220.0
for bad in [0, -5, "x"]:
    try: a.deposit(bad); raise SystemExit("deposit should raise")
    except InvalidAmount: pass
try: a.withdraw(10**9); raise SystemExit("withdraw should raise")
except InsufficientFunds: pass
try: b.transfer("alice","bob",10**9); raise SystemExit("transfer should raise")
except InsufficientFunds: pass
s = account_summary(a)
assert "Account: alice" in s and "Balance: 100" in s and "Transactions:" in s
bs = bank_summary(b)
assert "Accounts: 3" in bs and "Total balance:" in bs and "Account: bob" in bs
print("OK")
'''

INSTR = f"""You are refactoring a small Python codebase (2 files). GOAL: eliminate the duplicated
validation logic in bank.py (the isinstance/<=0 checks repeated across deposit, withdraw,
apply_interest, transfer; and the balance check) and the duplicated report-line building in
report.py — by extracting helper functions/methods.

CRITICAL: preserve ALL observable behavior and the PUBLIC API EXACTLY — same class names,
method names, function names, signatures, return values, and exception types
(InsufficientFunds, InvalidAmount). An existing hidden test suite must still pass unchanged.

Output BOTH files, each as:
### FILE: bank.py
```python
<full refactored file>
```
### FILE: report.py
```python
<full refactored file>
```

=== bank.py ===
{BANK_PY}
=== report.py ===
{REPORT_PY}
"""

def ask(prompt):
    p = {"model":"m","messages":[{"role":"user","content":prompt}],"temperature":0,"max_tokens":int(os.environ.get("MAXTOK","6000"))}
    if os.environ.get("NOKWARG") != "1":  # non-thinking 모델(Qwen3-Coder)엔 kwarg 생략
        p["chat_template_kwargs"] = {"enable_thinking": (not NOTHINK)}
    req = urllib.request.Request(BASE+"/v1/chat/completions", data=json.dumps(p).encode(),
                                 headers={"Content-Type":"application/json"})
    with urllib.request.urlopen(req, timeout=300) as r:
        return json.load(r)["choices"][0]["message"].get("content") or ""

def parse_files(txt):
    txt = re.sub(r"<think>.*?</think>", "", txt, flags=re.DOTALL)
    out = {}
    # ### FILE: name  다음의 코드블록
    for m in re.finditer(r"###\s*FILE:\s*([^\n]+?)\s*\n+```(?:python)?\s*\n(.*?)```", txt, flags=re.DOTALL):
        out[m.group(1).strip()] = m.group(2)
    return out

print(f"=== 멀티파일 리팩터 검증 (thinking={'OFF' if NOTHINK else 'ON'}) ===")
import time; t0=time.perf_counter()
raw = ask(INSTR)
dt = time.perf_counter()-t0
files = parse_files(raw)
print(f"모델 응답: {len(raw)}자, {dt:.1f}s | 추출된 파일: {list(files)}")

d = tempfile.mkdtemp()
try:
    if "bank.py" not in files or "report.py" not in files:
        print("[FAIL] 두 파일 모두 추출 실패"); print(raw[:600]); sys.exit()
    open(os.path.join(d,"bank.py"),"w").write(files["bank.py"])
    open(os.path.join(d,"report.py"),"w").write(files["report.py"])
    open(os.path.join(d,"test_bank.py"),"w").write(TEST_PY)
    p = subprocess.run([sys.executable, os.path.join(d,"test_bank.py")], capture_output=True, text=True, timeout=15, cwd=d)
    ok = (p.returncode==0 and "OK" in p.stdout)
    print(f"\n{'[PASS] 원본 테스트 전부 통과 (동작 보존 성공)' if ok else '[FAIL] 테스트 실패'}")
    if not ok:
        print("  stderr:", (p.stderr.strip().splitlines() or ['?'])[-1])
    # 중복 실제로 줄었나(부가 지표)
    import re as _re
    dep_checks = files["bank.py"].count('isinstance(amount')
    print(f"  [지표] bank.py 내 'isinstance(amount' 반복: {dep_checks}회 (원본 4회 → 리팩터로 감소 기대)")
    print(f"  [지표] bank.py 길이: {len(files['bank.py'].splitlines())}줄 (원본 62줄)")
finally:
    shutil.rmtree(d, ignore_errors=True)
