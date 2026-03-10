# opslane-verify

A verification layer for Claude Code. Reads your spec doc, runs one browser agent per acceptance criterion against your local dev server, and returns pass/fail with screenshots and video — before you push. No CI. No infrastructure.

## How it works

```mermaid
graph LR
    A[spec doc] --> B[spec interpreter]
    B --> C[planner]
    C --> D[agent: AC 1]
    C --> E[agent: AC 2]
    C --> F[agent: AC n]
    D --> G[judge]
    E --> G
    F --> G
    G --> H[report]
```

1. **Spec Interpreter** — reviews each AC for testability gaps, asks clarifying questions
2. **Planner** — extracts testable acceptance criteria from the annotated spec
3. **Agents** — one Claude + Playwright agent per AC, runs against your dev server
4. **Judge** — reviews screenshots and traces, returns pass/fail per AC
5. **Report** — prints results; failures include screenshot links and session recordings

![Verify Report](docs/report-screenshot.png)

## Installation

### Prerequisites

- Claude Code with OAuth login (`claude login`)
- Playwright MCP

### Install

```bash
/plugin marketplace add opslane/verify
/plugin install opslane-verify@opslane/verify
```

**macOS only:** `brew install coreutils` (for `gtimeout`)

## Usage

```bash
# One-time auth setup (skip if your app has no login)
/verify-setup

# Run verification — will ask you for the spec
/verify
```

`/verify` always asks for your spec upfront, then walks you through any clarifying questions before running.

## Debugging failures

```bash
# View Playwright trace for a failed AC
npx playwright show-report .verify/evidence/<ac_id>/trace

# Watch session recording
open .verify/evidence/<ac_id>/session.webm
```
