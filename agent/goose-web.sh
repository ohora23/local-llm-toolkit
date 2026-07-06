#!/usr/bin/env bash
# Goose 에이전트 = 현재 켜진 로컬 LLM(자동감지) + 웹 도구들:
#   ① SearXNG MCP (자가호스팅 메타검색 :8888, 레이트리밋 없음, 환각방지)
#   ② Playwright MCP (:8931) — 실제 Chrome 헤드리스, 특정 페이지 읽기/상호작용
# --no-profile: Goose 기본 번들 확장 끔 → 위 도구들만(약 25개).
# 사용: goose-web session  /  goose-web run -t "질문..."
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"
pick() { for p in 5000 5001 5002 5003; do curl -s -m2 "http://127.0.0.1:$p/v1/models" >/dev/null 2>&1 && { echo "$p"; return; }; done; }
PORT="$(pick)"
[ -n "$PORT" ] || { echo "[err] 켜진 로컬 LLM 없음 → 먼저: llm up gpu|cpu|hyb"; exit 1; }
MODEL="$(curl -s -m2 "http://127.0.0.1:$PORT/v1/models" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"][0]["id"])' 2>/dev/null || echo local)"
ss -tlnH "( sport = :8931 )" 2>/dev/null | grep -q 8931 || \
  { echo "[err] 브라우저 MCP(:8931) 꺼짐 → 먼저: $(dirname "$0")/start-browser-mcp.sh"; exit 1; }
export GOOSE_PROVIDER=openai GOOSE_MODEL="$MODEL"
export OPENAI_API_KEY=local OPENAI_HOST="http://127.0.0.1:$PORT" OPENAI_BASE_PATH=v1/chat/completions
export GOOSE_DISABLE_KEYRING=1
echo "[goose-web] LLM :$PORT ($MODEL)  +  SearXNG  +  browser MCP :8931  (--no-profile)" >&2
exec goose "$@" --no-profile \
  --with-extension "SEARXNG_URL=http://localhost:8888 npx -y mcp-searxng" \
  --with-streamable-http-extension "http://localhost:8931/mcp"
