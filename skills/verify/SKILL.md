---
name: verify
description: Verify frontend changes against spec acceptance criteria locally. Uses claude -p with OAuth. No extra API charges.
---

# /verify

Verify your frontend changes before pushing.

## Prerequisites
- Auth set up (`/verify-setup`) if app requires login
- `.verify/config.json` with build/start commands (see bottom of this file)

## Auto-Advance Mode

**If `.verify/spec.md` already exists** (e.g., written during planning via `build-and-verify`), skip Turns 1–4 entirely. The spec was already reviewed and approved by the user during planning. Go directly to Turn 5.

## Conversation Flow

This skill is turn-based. Each turn has a trigger and a bounded set of actions. **Never skip ahead** (unless auto-advance applies above).

---

## Turn 1: Spec Intake

**Trigger:** User invokes `/verify` AND `.verify/spec.md` does NOT exist.

**Your only action:** Send this message and end your response:

> "What spec are you verifying? Paste the spec content or give a file path."

Do not call any tools. Do not run any bash commands. Do not read any files. End your response and wait for the user to reply.

---

## Turn 2: Read Spec + Pre-flight

**Trigger:** User has provided a spec (pasted content or file path).

1. If they gave a **file path** — read the file now with the Read tool.
2. If they **pasted content** — first create the directory, then write the file:

```bash
mkdir -p .verify
```

Then write the content to `.verify/spec.md` with the Write tool.

Then run preflight:

```bash
bash ~/Documents/Github/verify/scripts/preflight.sh
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
VERIFY_ALLOW_DANGEROUS=1 bash ~/Documents/Github/verify/scripts/planner.sh .verify/spec.md
```

**Step 1 — Show extracted ACs (no testability labels):**

```bash
jq -r '.skipped[]? | "  ⊘ Skipped: \(.)"' .verify/plan.json
echo ""
echo "ACs to verify:"
jq -r '.criteria[] | "  • \(.id): \(.description)"' .verify/plan.json
```

**Step 2 — Research each AC's setup needs**

For each AC, check its `condition` field in `plan.json` (present only when setup is needed; absent means no setup expected — but still verify). Then use these tools to understand what app state is required:

- Use the **Grep** tool to search `prisma/schema.prisma`, `db/schema.*`, `src/models/**` for relevant data models
- Use the **Glob** tool to find `**/seed*.ts`, `**/fixtures/**`, `**/factories/**` for seed scripts or factories
- Use the **Grep** tool to search `src/app/api/**` or `src/routes/**` for API routes that create the required entity
- Use the **Grep** tool to search `src/config/**`, `.env.example` for feature flags or config values

For each AC, determine what data, auth state, or config must exist — and what setup command (if any) would create it. Use `$VERIFY_BASE_URL` for any URLs, never hardcode them.

**Step 3 — Present unified setup checklist**

Present all ACs together in a single block. **Setup commands are shown here but NOT executed yet — execution happens in Step 5 after confirmation.**

> Here's what I need before running:
>
> **AC1** — [description]
> → Needs: [what must exist]
> → Found: [model/route at path:line]
> → I'll run: `curl -X POST $VERIFY_BASE_URL/api/... --data-raw '{"field":"value"}'`
>
> **AC2** — [description]
> → No setup needed
>
> **AC3** — [description]
> → No setup needed

**Step 4 — Confirmation**

**If auto-advancing** (spec was pre-written): skip this step — proceed directly to Step 5.

**If interactive** (user provided spec in Turn 1): Ask:
> "Ready to set up and run? (y = set up and run all / s [ac-id] = skip that AC / edit = adjust setup)"

- `y` — proceed to Step 5
- `s ac1` (or any AC id) — remove that AC from plan.json:
  ```bash
  AC_ID="ac1"  # replace with actual id
  jq --arg id "$AC_ID" 'del(.criteria[] | select(.id == $id))' \
    .verify/plan.json > .verify/plan.tmp && mv .verify/plan.tmp .verify/plan.json
  ```
  Then re-show the updated checklist (Step 3) and re-ask for confirmation (Step 4).
- `edit` — user provides corrections; update your setup plan, re-show the updated checklist (Step 3), and re-ask for confirmation (Step 4). After 2–3 rounds without resolution, suggest: "Consider refining the spec and re-running `/verify`."

**Step 5 — Execute setup, verify, then proceed**

First, stop if no criteria remain:
```bash
COUNT=$(jq '.criteria | length' .verify/plan.json)
[ "$COUNT" -gt 0 ] || { echo "✗ No testable criteria."; exit 1; }
```

Now run each proposed setup command. After each, verify it worked (e.g. check the HTTP response code, or query the DB). If a setup command fails, skip that AC, remove it from `plan.json`, and report: `"Setup for [ac-id] failed — skipping."` Then confirm to the user:

> "Setup complete — all ACs ready. Proceeding to Stage 2."

---

## Stage 2: Browser Agents

Clear previous evidence:
```bash
rm -rf .verify/evidence .verify/prompts
rm -f /tmp/verify-mcp-*.json
mkdir -p .verify/evidence
```

Run orchestrate in the foreground — **never background this**:
```bash
VERIFY_ALLOW_DANGEROUS=1 bash ~/Documents/Github/verify/scripts/orchestrate.sh
```

---

## Stage 3: Judge

```bash
VERIFY_ALLOW_DANGEROUS=1 bash ~/Documents/Github/verify/scripts/judge.sh
```

---

## Report

```bash
VERIFY_ALLOW_DANGEROUS=1 bash ~/Documents/Github/verify/scripts/report.sh
```

---

## Error Handling

| Failure | Action |
|---------|--------|
| Pre-flight fails | Print error, stop |
| 0 criteria after human review | Print message, stop |
| All agents timeout/error | Print "Check dev server and auth", suggest `/verify-setup` |
| Judge returns invalid JSON | Print raw output, tell user to check `.verify/evidence/` manually |
| `progress.jsonl` missing after orchestrate | Agents never started or all exited instantly — check `.verify/evidence/*/claude.log` |

## Config

`.verify/config.json` in the project root:

```json
{
  "baseUrl": "http://localhost:3000",
  "buildCmd": "npm run build",
  "startCmd": "npm start"
}
```

Preflight will run `buildCmd`, then start `startCmd` as a background process, and clean it up after the report.

## Quick Reference

```bash
/verify-setup                                          # one-time auth
/verify                                                # run pipeline (auto-advances if .verify/spec.md exists)
npx playwright show-report .verify/evidence/<id>/trace # debug failure
open .verify/evidence/<id>/session.webm                # watch video
```
