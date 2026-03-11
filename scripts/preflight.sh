#!/usr/bin/env bash
set -e

SKIP_AUTH=false
SKIP_SPEC=false
for arg in "$@"; do
  case $arg in
    --skip-auth) SKIP_AUTH=true ;;
    --skip-spec) SKIP_SPEC=true ;;
  esac
done

# Check for gtimeout (macOS coreutils) or timeout (Linux)
if command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_CMD="gtimeout"
elif command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD="timeout"
else
  echo "✗ timeout command not found. Install: brew install coreutils"
  exit 1
fi
export TIMEOUT_CMD

# Load config inline
CONFIG_FILE=".verify/config.json"
VERIFY_BASE_URL="${VERIFY_BASE_URL:-$(jq -r '.baseUrl // "http://localhost:3000"' "$CONFIG_FILE" 2>/dev/null || echo "http://localhost:3000")}"
VERIFY_AUTH_CHECK_URL="${VERIFY_AUTH_CHECK_URL:-$(jq -r '.authCheckUrl // "/api/me"' "$CONFIG_FILE" 2>/dev/null || echo "/api/me")}"
VERIFY_SPEC_PATH="${VERIFY_SPEC_PATH:-$(jq -r '.specPath // empty' "$CONFIG_FILE" 2>/dev/null || echo "")}"
VERIFY_BUILD_CMD="${VERIFY_BUILD_CMD:-$(jq -r '.buildCmd // "npm run build"' "$CONFIG_FILE" 2>/dev/null || echo "npm run build")}"
VERIFY_START_CMD="${VERIFY_START_CMD:-$(jq -r '.startCmd // "npm start"' "$CONFIG_FILE" 2>/dev/null || echo "npm start")}"
export VERIFY_BASE_URL VERIFY_AUTH_CHECK_URL VERIFY_SPEC_PATH VERIFY_BUILD_CMD VERIFY_START_CMD

PORT=$(echo "$VERIFY_BASE_URL" | grep -oE ':[0-9]+' | tr -d ':')

# 1. Build production bundle and start server
echo "→ Building production bundle..."
if ! eval "$VERIFY_BUILD_CMD"; then
  echo "✗ Build failed. Fix build errors and retry."
  exit 1
fi
echo "✓ Build succeeded"

# Kill any existing process on our port
if [ -n "$PORT" ]; then
  EXISTING_PID=$(lsof -ti :"$PORT" -sTCP:LISTEN 2>/dev/null || true)
  if [ -n "$EXISTING_PID" ]; then
    echo "→ Killing existing process on port $PORT (pid $EXISTING_PID)"
    kill "$EXISTING_PID" 2>/dev/null || true
    sleep 1
  fi
fi

echo "→ Starting prod server: $VERIFY_START_CMD (port $PORT)..."
eval "PORT=${PORT:-3000} $VERIFY_START_CMD" > .verify/server.log 2>&1 &
VERIFY_SERVER_PID=$!
echo "$VERIFY_SERVER_PID" > .verify/.server_pid

# Wait for server to be ready (up to 30s)
echo "→ Waiting for server at $VERIFY_BASE_URL..."
WAITED=0
while [ $WAITED -lt 30 ]; do
  if curl -sf --max-time 2 "$VERIFY_BASE_URL" > /dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$VERIFY_SERVER_PID" 2>/dev/null; then
    echo "✗ Server process died. Check .verify/server.log"
    exit 1
  fi
  sleep 1
  WAITED=$((WAITED + 1))
done

if [ $WAITED -ge 30 ]; then
  echo "✗ Server failed to start within 30s. Check .verify/server.log"
  kill "$VERIFY_SERVER_PID" 2>/dev/null || true
  exit 1
fi
echo "✓ Prod server running (pid $VERIFY_SERVER_PID)"

# 2. Auth validity check
if [ "$SKIP_AUTH" = false ]; then
  if [ ! -f ".verify/auth.json" ]; then
    echo "✗ No auth state found. Run /verify setup first."
    exit 1
  fi
  AUTH_URL="${VERIFY_BASE_URL}${VERIFY_AUTH_CHECK_URL}"
  echo "→ Checking auth at $AUTH_URL..."
  # Build Cookie header string from Playwright storageState JSON
  COOKIE_STR=$(jq -r '[.cookies[]? | "\(.name)=\(.value)"] | join("; ")' .verify/auth.json 2>/dev/null || echo "")
  HTTP_CODE=$(curl -sf --max-time 5 \
    ${COOKIE_STR:+-H "Cookie: $COOKIE_STR"} \
    -o /dev/null -w "%{http_code}" \
    "$AUTH_URL" 2>/dev/null || echo "000")
  if [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "403" ] || [ "$HTTP_CODE" = "302" ] || [ "$HTTP_CODE" = "000" ]; then
    echo "✗ Session expired or invalid (HTTP $HTTP_CODE). Run /verify setup to re-authenticate."
    exit 1
  fi
  echo "✓ Auth valid (HTTP $HTTP_CODE)"
fi

# 3. Spec doc detection
if [ "$SKIP_SPEC" = false ]; then
  echo "→ Finding spec doc..."
  SPEC_PATH=""

  if [ -n "$VERIFY_SPEC_PATH" ]; then
    SPEC_PATH="$VERIFY_SPEC_PATH"
  else
    # Changed files in diff (tracked)
    SPEC_PATH=$(git diff --name-only HEAD 2>/dev/null | grep "^docs/plans/.*\.md$" | head -1 || true)
    # Newly added (untracked)
    if [ -z "$SPEC_PATH" ]; then
      SPEC_PATH=$(git ls-files --others --exclude-standard 2>/dev/null | grep "^docs/plans/.*\.md$" | head -1 || true)
    fi
    # Fall back to newest by mtime (avoid xargs ls -t which breaks on spaces)
    if [ -z "$SPEC_PATH" ]; then
      SPEC_PATH=$(find docs/plans -name "*.md" -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | awk '{print $2}' || true)
      # macOS fallback: find doesn't support -printf
      if [ -z "$SPEC_PATH" ]; then
        SPEC_PATH=$(ls -t docs/plans/*.md 2>/dev/null | head -1 || true)
      fi
    fi
  fi

  if [ -z "$SPEC_PATH" ] || [ ! -f "$SPEC_PATH" ]; then
    echo "✗ No spec doc found. Set specPath in .verify/config.json or add a plan doc to docs/plans/."
    exit 1
  fi

  echo "✓ Spec doc: $SPEC_PATH"
  mkdir -p .verify
  echo "$SPEC_PATH" > .verify/.spec_path
fi

echo "✓ Pre-flight complete"
