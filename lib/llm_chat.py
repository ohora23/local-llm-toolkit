#!/usr/bin/env python3
# Interactive chat REPL for the local LLM endpoints.
# Run as a FILE (not via `python3 - <<heredoc`) so stdin stays the terminal
# and input() works.  Driven by env HOST/PORT.  Commands: /exit /reset
import os, json, urllib.request

host = os.environ["HOST"]
port = os.environ["PORT"]
msgs = []


def send():
    body = json.dumps({
        "model": "local", "messages": msgs,
        "temperature": 0.3, "stream": True,
    }).encode()
    req = urllib.request.Request(
        f"http://{host}:{port}/v1/chat/completions",
        data=body, headers={"Content-Type": "application/json"},
    )
    acc = []
    with urllib.request.urlopen(req) as r:
        for raw in r:
            line = raw.decode("utf-8", "ignore").strip()
            if not line.startswith("data:"):
                continue
            p = line[5:].strip()
            if p == "[DONE]":
                break
            try:
                obj = json.loads(p)
            except Exception:
                continue
            d = (obj.get("choices") or [{}])[0].get("delta", {}).get("content", "")
            if d:
                acc.append(d)
                print(d, end="", flush=True)
    print()
    return "".join(acc)


while True:
    try:
        u = input("\033[36myou>\033[0m ")
    except (EOFError, KeyboardInterrupt):
        print()
        break
    s = u.strip()
    if s in ("/exit", "/quit"):
        break
    if s == "/reset":
        msgs.clear()
        print("(reset)")
        continue
    if not s:
        continue
    msgs.append({"role": "user", "content": u})
    print("\033[32mllm>\033[0m ", end="", flush=True)
    msgs.append({"role": "assistant", "content": send()})
