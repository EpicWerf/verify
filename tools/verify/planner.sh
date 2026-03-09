#!/usr/bin/env bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE="${CLAUDE_BIN:-claude}"

SPEC_PATH="${1:-$(cat .verify/.spec_path 2>/dev/null)}"
[ -n "$SPEC_PATH" ] && [ -f "$SPEC_PATH" ] || { echo "✗ Spec doc not found: $SPEC_PATH"; exit 1; }

VERIFY_BASE_URL="${VERIFY_BASE_URL:-$(jq -r '.baseUrl // "http://localhost:3000"' .verify/config.json 2>/dev/null)}"

echo "→ Running Planner (Opus)..."
echo "  Spec: $SPEC_PATH"

# Collect changed React component files (process substitution keeps variable in current shell)
COMPONENT_CONTEXT=""
while IFS= read -r file; do
  [ -f "$file" ] || continue
  COMPONENT_CONTEXT+="\n\n--- FILE: $file ---\n$(cat "$file")"
done < <({
  git diff --name-only HEAD 2>/dev/null
  git ls-files --others --exclude-standard 2>/dev/null
} | grep -E "\.(tsx?|jsx?)$" | head -10)

PROMPT="$(cat "$SCRIPT_DIR/prompts/planner.txt")

---
BASE URL: ${VERIFY_BASE_URL}

SPEC DOC (${SPEC_PATH}):
$(cat "$SPEC_PATH")
${COMPONENT_CONTEXT}"

# Call Opus — capture raw output once, parse separately
RAW=$("$CLAUDE" -p --model opus "$PROMPT" 2>/dev/null)

# Strip markdown fences if model ignores the instruction
PLAN_JSON=$(echo "$RAW" | sed '/^```/d' | sed '/^$/d' | tr -d '\r')

# Validate JSON
if ! echo "$PLAN_JSON" | jq . > /dev/null 2>&1; then
  echo "✗ Planner returned invalid JSON:"
  echo "$PLAN_JSON" | head -20
  exit 1
fi

mkdir -p .verify
echo "$PLAN_JSON" | jq '.' > .verify/plan.json

# Print skipped
SKIPPED_COUNT=$(jq '.skipped | length' .verify/plan.json)
if [ "$SKIPPED_COUNT" -gt 0 ]; then
  echo ""
  jq -r '.skipped[]' .verify/plan.json | while IFS= read -r msg; do
    echo "  ⚠ Skipped: $msg"
  done
fi

CRITERIA_COUNT=$(jq '.criteria | length' .verify/plan.json)
echo "✓ Planner complete: $CRITERIA_COUNT criteria, $SKIPPED_COUNT skipped → .verify/plan.json"
