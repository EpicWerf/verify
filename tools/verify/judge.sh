#!/usr/bin/env bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE="${CLAUDE_BIN:-claude}"

[ -f ".verify/plan.json" ] || { echo "✗ .verify/plan.json not found"; exit 1; }
echo "→ Running Judge (Opus)..."

SKIPPED=$(jq -r '.skipped' .verify/plan.json)
# Read AC IDs (bash 3 compatible — no mapfile)
AC_IDS=()
while IFS= read -r line; do
  AC_IDS+=("$line")
done < <(jq -r '.criteria[].id' .verify/plan.json)

# Build evidence block — base64-encode screenshots inline (claude -p has no --file for local images)
EVIDENCE=""
for AC_ID in "${AC_IDS[@]}"; do
  AC_DESC=$(jq -r --arg id "$AC_ID" '.criteria[] | select(.id==$id) | .description' .verify/plan.json)
  EVIDENCE+="\n--- AC: $AC_ID ---\n"
  EVIDENCE+="CRITERION: $AC_DESC\n"

  LOG_FILE=".verify/evidence/$AC_ID/agent.log"
  if [ -f "$LOG_FILE" ]; then
    EVIDENCE+="AGENT LOG:\n$(cat "$LOG_FILE")\n"
  else
    EVIDENCE+="AGENT LOG: not found\n"
  fi

  # Embed screenshots as base64 inline — Opus can read them in the prompt
  while IFS= read -r screenshot; do
    [ -f "$screenshot" ] || continue
    LABEL=$(basename "$screenshot" .png)
    B64=$(base64 < "$screenshot" | tr -d '\n')
    EVIDENCE+="SCREENSHOT ($LABEL): data:image/png;base64,${B64}\n"
  done < <(find ".verify/evidence/$AC_ID" -name "screenshot-*.png" 2>/dev/null | sort)
done

PROMPT="$(cat "$SCRIPT_DIR/prompts/judge.txt")

EVIDENCE:
$EVIDENCE

SKIPPED FROM PLAN: $SKIPPED"

REPORT_JSON=$("$CLAUDE" -p \
  --model opus \
  --dangerously-skip-permissions \
  "$PROMPT" 2>/dev/null)

# Strip any markdown fences
REPORT_JSON=$(echo "$REPORT_JSON" | sed '/^```/d' | sed '/^$/d')

if ! echo "$REPORT_JSON" | jq . > /dev/null 2>&1; then
  echo "✗ Judge returned invalid JSON:"
  echo "$REPORT_JSON" | head -20
  exit 1
fi

echo "$REPORT_JSON" | jq '.' > .verify/report.json

VERDICT=$(jq -r '.verdict' .verify/report.json)
SUMMARY=$(jq -r '.summary' .verify/report.json)
echo "✓ Judge complete: $SUMMARY (verdict: $VERDICT)"
