#!/usr/bin/env bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE="${CLAUDE_BIN:-claude}"

if [ "${VERIFY_ALLOW_DANGEROUS:-0}" != "1" ]; then
  echo "✗ This script runs claude with --dangerously-skip-permissions."
  echo "  Set VERIFY_ALLOW_DANGEROUS=1 to proceed."
  exit 1
fi

AC_ID="$1"
TIMEOUT_SECS="${2:-240}"

[ -n "$AC_ID" ] || { echo "Usage: $0 <ac_id> [timeout_secs]"; exit 1; }
[ -f ".verify/plan.json" ] || { echo "✗ .verify/plan.json not found"; exit 1; }

# Detect timeout command (macOS: gtimeout from coreutils; Linux: timeout)
if command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_CMD="gtimeout"
elif command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD="timeout"
else
  echo "✗ timeout not found. Install: brew install coreutils"
  exit 1
fi

VERIFY_BASE_URL="${VERIFY_BASE_URL:-$(jq -r '.baseUrl // "http://localhost:3000"' .verify/config.json 2>/dev/null)}"

# Extract AC data
AC_JSON=$(jq -r --arg id "$AC_ID" '.criteria[] | select(.id == $id)' .verify/plan.json)
[ -n "$AC_JSON" ] || { echo "✗ AC '$AC_ID' not found in plan.json"; exit 1; }

AC_DESC=$(echo "$AC_JSON" | jq -r '.description')
AC_URL=$(echo "$AC_JSON" | jq -r '.url')
STEPS=$(echo "$AC_JSON" | jq -r '.steps[]' | nl -ba)
SCREENSHOTS=$(echo "$AC_JSON" | jq -r '.screenshot_at | join(", ")')

# Build agent prompt — all substitutions via env vars to avoid sed injection
# (values come from LLM-generated plan.json and may contain sed delimiter chars)
mkdir -p ".verify/evidence/$AC_ID" ".verify/prompts"
REPLACE_AC_DESCRIPTION="$AC_DESC" \
REPLACE_AC_ID="$AC_ID" \
REPLACE_BASE_URL="${VERIFY_BASE_URL}${AC_URL}" \
REPLACE_SCREENSHOT_AT="$SCREENSHOTS" \
REPLACE_STEPS_VAL="$STEPS" \
python3 -c "
import sys, os
content = open(sys.argv[1]).read()
content = content.replace('REPLACE_AC_DESCRIPTION', os.environ['REPLACE_AC_DESCRIPTION'])
content = content.replace('REPLACE_AC_ID',          os.environ['REPLACE_AC_ID'])
content = content.replace('REPLACE_BASE_URL',       os.environ['REPLACE_BASE_URL'])
content = content.replace('REPLACE_SCREENSHOT_AT',  os.environ['REPLACE_SCREENSHOT_AT'])
content = content.replace('REPLACE_STEPS',          os.environ['REPLACE_STEPS_VAL'])
print(content, end='')
" "$SCRIPT_DIR/prompts/agent.txt" > ".verify/prompts/${AC_ID}-agent.txt"

# Playwright MCP config — each agent gets its own --output-dir so videos land
# directly in the AC's evidence folder (works correctly in parallel runs)
EVIDENCE_DIR="$(pwd)/.verify/evidence/$AC_ID"
AUTH_STATE_PATH="$(pwd)/.verify/auth.json"
MCP_CONFIG_FILE=$(mktemp "${TMPDIR:-/tmp}/verify-mcp-XXXXXX")
MCP_VERSION="${PLAYWRIGHT_MCP_VERSION:-0.0.68}"
jq -n --arg outdir "$EVIDENCE_DIR" --arg authstate "$AUTH_STATE_PATH" --arg mcpver "$MCP_VERSION" '{
  mcpServers: {
    playwright: {
      command: "npx",
      args: [
        ("@playwright/mcp@" + $mcpver),
        "--save-video=1280x720",
        "--caps", "vision",
        "--storage-state", $authstate,
        "--save-trace",
        "--output-dir", $outdir
      ]
    }
  }
}' > "$MCP_CONFIG_FILE"
# shellcheck disable=SC2064
trap "rm -f '$MCP_CONFIG_FILE'" EXIT

echo "  → Agent $AC_ID (timeout: ${TIMEOUT_SECS}s)..."

set +e
# Retry loop: up to 3 attempts for transient failures (non-zero, non-124 exit codes)
EXIT_CODE=1
for attempt in 1 2 3; do
  $TIMEOUT_CMD "$TIMEOUT_SECS" "$CLAUDE" -p \
    --model sonnet \
    --dangerously-skip-permissions \
    --mcp-config "$MCP_CONFIG_FILE" \
    < ".verify/prompts/${AC_ID}-agent.txt" > ".verify/evidence/$AC_ID/claude.log" 2>&1
  EXIT_CODE=$?
  [ $EXIT_CODE -eq 0 ] && break          # success
  [ $EXIT_CODE -eq 124 ] && break        # timeout — don't retry
  if [ $attempt -lt 3 ]; then
    echo "  ↻ $AC_ID: attempt $attempt failed (exit $EXIT_CODE), retrying in 5s..."
    sleep 5
  fi
done
set -e

LOG_FILE=".verify/evidence/$AC_ID/agent.log"
PROGRESS_FILE=".verify/progress.jsonl"
TS=$(date +%s)

_append_progress() {
  # Use jq for safe JSON construction — handles quotes/special chars in AC_ID or verdict
  jq -n --arg ac_id "$1" --arg status "$2" --arg verdict "$3" --argjson ts "$TS" \
    '{"ac_id":$ac_id,"status":$status,"verdict":$verdict,"ts":$ts}' >> "$PROGRESS_FILE"
}

if [ $EXIT_CODE -eq 124 ]; then
  printf "VERDICT: timeout\nREASONING: Agent exceeded ${TIMEOUT_SECS}s\nSTEPS_COMPLETED: unknown\n" > "$LOG_FILE"
  echo "  ⏱ $AC_ID: timeout"
  _append_progress "$AC_ID" "timeout" "timeout"
elif [ $EXIT_CODE -ne 0 ]; then
  printf "VERDICT: error\nREASONING: Agent exited with code $EXIT_CODE\nSTEPS_COMPLETED: 0/unknown\n" > "$LOG_FILE"
  echo "  ✗ $AC_ID: error (exit $EXIT_CODE)"
  _append_progress "$AC_ID" "error" "error"
else
  if [ ! -f "$LOG_FILE" ]; then
    grep -A2 "^VERDICT:" ".verify/evidence/$AC_ID/claude.log" > "$LOG_FILE" 2>/dev/null || \
      printf "VERDICT: error\nREASONING: Agent did not write agent.log\nSTEPS_COMPLETED: unknown\n" > "$LOG_FILE"
  fi
  # Validate agent.log has expected VERDICT line; overwrite with structured error if malformed
  if ! grep -q "^VERDICT:" "$LOG_FILE"; then
    printf "VERDICT: error\nREASONING: claude.log missing VERDICT line\nSTEPS_COMPLETED: unknown\n" > "$LOG_FILE"
  fi
  # Use sed to capture full verdict value (handles multi-word verdicts like "partial pass")
  VERDICT=$(sed -n 's/^VERDICT: *//p' "$LOG_FILE" | head -1)
  echo "  ✓ $AC_ID: done (verdict: $VERDICT)"
  _append_progress "$AC_ID" "done" "$VERDICT"
fi

# Video lands in the evidence dir via --output-dir; rename UUID to session.webm
LATEST_VIDEO=$(find "$EVIDENCE_DIR" -name "*.webm" 2>/dev/null | head -1)
if [ -n "$LATEST_VIDEO" ] && [ "$LATEST_VIDEO" != "$EVIDENCE_DIR/session.webm" ]; then
  mv "$LATEST_VIDEO" "$EVIDENCE_DIR/session.webm"
  echo "  📹 $AC_ID: video saved"
fi
