---
name: verify
description: Verify frontend changes against spec acceptance criteria locally. Uses claude -p with OAuth. No extra API charges.
---

# /verify

Verify your frontend changes before pushing.

## Prerequisites
- Dev server running (e.g. `npm run dev`)
- Auth set up (`/verify-setup`) if app requires login

## Steps

### Stage 0: Pre-flight

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/preflight.sh"
```

Stop if this fails. Fix the reported issue and re-run.

### Stage 1: Planner

```bash
SPEC_PATH=$(cat .verify/.spec_path 2>/dev/null || echo ".verify/spec.md")
VERIFY_ALLOW_DANGEROUS=1 bash "${CLAUDE_PLUGIN_ROOT}/scripts/planner.sh" "$SPEC_PATH"
```

Show the extracted ACs to the user, grouped by testability:

```bash
echo ""
echo "Direct ACs (will run automatically):"
jq -r '.criteria[] | select(.testability == "direct") | "  ✓ \(.id): \(.description)"' .verify/plan.json

echo ""
CONDITIONAL=$(jq -r '.criteria[] | select(.testability == "conditional") | "  ? \(.id): \(.description)\n    Requires: \(.condition)"' .verify/plan.json)
if [ -n "$CONDITIONAL" ]; then
  echo "Conditional ACs (need setup to run):"
  echo "$CONDITIONAL"
fi

echo ""
jq -r '.skipped[]? | "  ⊘ Skipped: \(.)"' .verify/plan.json
```

**Human review of conditional ACs:**

For each conditional AC, ask the user:
- Read the condition from `.verify/plan.json` for that AC
- Ask: "AC [id] requires: [condition]. Is this set up? (y = include it / n = skip it)"
- If n: remove that AC from the plan before proceeding:
  ```bash
  jq 'del(.criteria[] | select(.id == "ACID" and .testability == "conditional"))' \
    .verify/plan.json > .verify/plan.tmp && mv .verify/plan.tmp .verify/plan.json
  ```

Then confirm remaining direct ACs: "Does this look right? (y/n)"
- If n: stop. Ask them to refine the spec doc and re-run.

Stop if criteria count is 0:
```bash
COUNT=$(jq '.criteria | length' .verify/plan.json)
[ "$COUNT" -gt 0 ] || { echo "✗ No testable criteria. Refine the spec or set up required conditions."; exit 1; }
```

### Stage 2: Browser Agents

Clear previous evidence and stale temp files first:
```bash
rm -rf .verify/evidence .verify/prompts
rm -f /tmp/verify-mcp-*.json
mkdir -p .verify/evidence
```

Run:
```bash
VERIFY_ALLOW_DANGEROUS=1 bash "${CLAUDE_PLUGIN_ROOT}/scripts/orchestrate.sh"
```

### Stage 3: Judge

```bash
VERIFY_ALLOW_DANGEROUS=1 bash "${CLAUDE_PLUGIN_ROOT}/scripts/judge.sh"
```

### Report

```bash
VERIFY_ALLOW_DANGEROUS=1 bash "${CLAUDE_PLUGIN_ROOT}/scripts/report.sh"
```

## Error Handling

| Failure | Action |
|---------|--------|
| Pre-flight fails | Print error, stop |
| 0 criteria after human review | Print message, stop |
| All agents timeout/error | Print "Check dev server and auth", suggest `/verify-setup` |
| Judge returns invalid JSON | Print raw output, tell user to check `.verify/evidence/` manually |

## Quick Reference

```bash
/verify-setup                                          # one-time auth
/verify                                                # run pipeline
npx playwright show-report .verify/evidence/<id>/trace # debug failure
open .verify/evidence/<id>/session.webm                # watch video
```
