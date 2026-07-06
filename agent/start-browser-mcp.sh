#!/usr/bin/env bash
# 공유 웹 도구 = Playwright MCP (실제 google-chrome, 전용 프로필=로그인 불가, 헤드리스).
# HTTP(SSE) 서버로 띄워 Open WebUI·Goose 가 같은 인스턴스를 공유.
# --headless: 화면에 창을 띄우지 않음(백그라운드 브라우징).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
exec npx -y @playwright/mcp@latest \
  --browser chrome \
  --headless \
  --user-data-dir "$DIR/chrome-profile" \
  --output-dir "$DIR/browser-output" \
  --host 127.0.0.1 --port 8931 \
  --shared-browser-context \
  --block-service-workers
