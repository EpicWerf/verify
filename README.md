# opslane-verify

Browser-based acceptance criteria verification for frontend PRs. Runs Claude + Playwright agents against your local dev server to verify each AC in a spec doc — no CI required.

## How it works

1. `/verify setup` — one-time: captures auth session for apps that require login
2. `/verify` — runs the full pipeline:
   - **Planner**: reads your spec doc, extracts testable ACs
   - **Browser Agents**: one Claude+Playwright agent per AC, takes screenshots
   - **Judge**: reviews evidence, returns pass/fail per AC
   - **Report**: prints results with debug links for failures

## Installation

### Claude Code

Register the marketplace:

```bash
/plugin marketplace add opslane/opslane-v3
```

Install the plugin:

```bash
/plugin install opslane-verify@opslane-v3
```

### Prerequisites

- `claude` CLI with OAuth login (`claude login`)
- `node` + `npx` (for Playwright MCP)
- `jq`
- `curl`
- `coreutils` on macOS: `brew install coreutils` (for `gtimeout`)

## Usage

```bash
# One-time auth setup (skip if app has no login)
/verify setup

# Run verification
/verify
```

## Configuration

`.verify/config.json` (created by `/verify setup`):

```json
{
  "baseUrl": "http://localhost:3000",
  "authCheckUrl": "/api/me",
  "specPath": null
}
```

- `baseUrl`: your dev server URL
- `authCheckUrl`: endpoint that returns 200 when authenticated
- `specPath`: override spec doc path (default: auto-detect from `docs/plans/`)

## Debugging failures

```bash
npx playwright show-report .verify/evidence/<ac_id>/trace
open .verify/evidence/<ac_id>/session.webm
```
