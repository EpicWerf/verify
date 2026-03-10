---
name: verify
description: Verify frontend changes against spec acceptance criteria locally. Uses claude -p with OAuth. No extra API charges.
---

# /verify

Verify your frontend changes before pushing.

## Prerequisites
- Dev server running (e.g. `npm run dev`)
- Auth set up (`/verify-setup`) if app requires login

## Conversation Flow

This skill is turn-based. Each turn has a trigger and a bounded set of actions. **Never skip ahead.**

---

## Turn 1: Spec Intake

**Trigger:** User invokes `/verify`.

**Your only action:** Send this message and end your response:

> "What spec are you verifying? Paste the spec content or give a file path."

Do not call any tools. Do not run any bash commands. Do not read any files. End your response and wait for the user to reply.

**Even if the user passed a path as an argument to `/verify`**, still send this prompt to confirm — do not skip ahead to Turn 2.

---

## Turn 2: Read Spec + Pre-flight

**Trigger:** User has provided a spec (pasted content or file path).

1. If they gave a **file path** — read the file now with the Read tool.
2. If they **pasted content** — write it to `.verify/spec.md` with the Write tool.

Then run preflight:

```bash
bash ~/.claude/tools/verify/preflight.sh
```

Stop if preflight fails. Fix the reported issue and ask the user to re-run.

Proceed to Turn 3.

---

## Turn 3: Spec Interpreter

**Trigger:** Preflight passed.

Review the spec inline — no subprocess needed. For each AC, check:

1. **Reveal action** — does it say "shown/displayed/visible" without saying how (inline, hover, click, modal)? → flag
2. **Preconditions** — requires specific data to exist (sent doc, user role, feature flag)? → flag
3. **Target** — UI element identifiable by label or button text? If too vague → flag
4. **Success** — clear pass/fail? If not → flag

If **no ambiguities found**: skip Turn 4, go directly to Turn 5.

If **ambiguities found**: ask the user the first flagged question now. End your response and wait for their answer.

---

## Turn 4: Clarification Loop

**Trigger:** User has answered a clarifying question.

Keep a running list of AC annotations as you collect answers, e.g.:
- AC3: expiry date revealed via hover on Pending badge
- AC1: expiration field is inline in the send dialog

Note the new answer and add it to the list. If more flagged ambiguities remain — ask the next one. End your response and wait.

When all ambiguities are answered — proceed to Turn 5.

---

## Turn 5: Write Annotated Spec → Planner

**Trigger:** All ambiguities resolved (or there were none).

Write `.verify/spec.md` incorporating all clarifications as inline HTML comments, e.g.:
`<!-- clarified: expiry date revealed via hover on Pending badge -->`

Then run the planner:

```bash
VERIFY_ALLOW_DANGEROUS=1 bash ~/.claude/tools/verify/planner.sh .verify/spec.md
```

Show extracted ACs grouped by testability:

```bash
echo "Direct ACs (will run automatically):"
jq -r '.criteria[] | select(.testability == "direct") | "  ✓ \(.id): \(.description)"' .verify/plan.json

CONDITIONAL=$(jq -r '.criteria[] | select(.testability == "conditional") | "  ? \(.id): \(.description)\n    Requires: \(.condition)"' .verify/plan.json)
if [ -n "$CONDITIONAL" ]; then
  echo ""
  echo "Conditional ACs (need setup to run):"
  echo "$CONDITIONAL"
fi

jq -r '.skipped[]? | "  ⊘ Skipped: \(.)"' .verify/plan.json
```

**For each conditional AC**, ask the user:
> "AC [id] requires: [condition]. Is this set up? (y = include / n = skip)"

If n, remove it (substitute the actual AC id for `<ac-id>`):
```bash
AC_ID="<ac-id>"
jq --arg id "$AC_ID" 'del(.criteria[] | select(.id == $id and .testability == "conditional"))' \
  .verify/plan.json > .verify/plan.tmp && mv .verify/plan.tmp .verify/plan.json
```

Then confirm: "Does this look right? (y/n)"
- If n: stop, ask them to refine the spec and re-run.

Stop if no criteria remain:
```bash
COUNT=$(jq '.criteria | length' .verify/plan.json)
[ "$COUNT" -gt 0 ] || { echo "✗ No testable criteria."; exit 1; }
```

---

## Stage 2: Browser Agents

Clear previous evidence:
```bash
rm -rf .verify/evidence .verify/prompts
rm -f /tmp/verify-mcp-*.json
mkdir -p .verify/evidence
```

Run:
```bash
VERIFY_ALLOW_DANGEROUS=1 bash ~/.claude/tools/verify/orchestrate.sh
```

---

## Stage 3: Judge

```bash
VERIFY_ALLOW_DANGEROUS=1 bash ~/.claude/tools/verify/judge.sh
```

---

## Report

```bash
VERIFY_ALLOW_DANGEROUS=1 bash ~/.claude/tools/verify/report.sh
```

---

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
