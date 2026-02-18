# Auto-Debug: Automated Error Detection and GitHub Issue Filing

Appmotel can automatically detect runtime errors in deployed apps, analyze them with Claude Code, and file GitHub issues against the app's source repository.

## How It Works

The auto-debug system runs as part of the **autopull cycle** (every 2 minutes via `appmotel-autopull.timer`). For each deployed app, `check_app_errors()` in `bin/appmo` performs these steps:

1. **Opt-out check** — Skips apps with `AUTO_DEBUG=no` in their `.env`
2. **Cooldown check** — Skips apps that had an issue filed in the last 24 hours (timestamp in `~/.config/appmotel/<app>/.auto-debug-cooldown`)
3. **Log scan** — Reads the last 3 minutes of `journalctl --user -u appmotel-<app>` output
4. **Error detection** — Searches for patterns: `ERROR`, `CRITICAL`, `EXCEPTION`, `TRACEBACK`, `FATAL`, `PANIC:`, `UnhandledPromise`
5. **Prerequisite check** — Verifies that `claude` (Claude Code CLI) and `gh` (GitHub CLI, authenticated) are both available
6. **Claude analysis** — Pipes the logs to `claude -p` with a structured prompt requesting `TITLE:`, `CAUSE:`, and `FIX:` sections
7. **Issue filing** — Uses `gh issue create` to file against the app's `GITHUB_URL` (from `metadata.conf`), including the error excerpt, Claude's analysis, and full logs in a collapsible section
8. **Cooldown stamp** — Writes the current Unix timestamp to the cooldown file

## Prerequisites

Both tools must be installed and configured on the appmotel server:

### Claude Code CLI

```bash
# Install (see https://claude.ai/code)
npm install -g @anthropic-ai/claude-code
# Or via curl installer — check the official docs for current instructions
```

### GitHub CLI

```bash
# Install
sudo apt install gh          # Debian/Ubuntu
sudo dnf install gh          # RHEL/Amazon Linux

# Authenticate (required — must have access to file issues on app repos)
gh auth login
```

Verify both:
```bash
command -v claude && echo "claude OK"
gh auth status
```

## Configuration

### Global (default: enabled)

Auto-debug is **enabled by default** for all apps. No global configuration is needed — it activates automatically when both `claude` and `gh` are available. If either tool is missing, it silently skips with an informational log message.

### Per-App Opt-Out

Add to the app's `.env` file:

```bash
AUTO_DEBUG=no
```

Edit via: `appmo env <app-name>`

### Cooldown Period

The default cooldown is **24 hours** (86400 seconds), hardcoded in `check_app_errors()`. After filing an issue for an app, no further issues will be filed for that app until the cooldown expires.

The cooldown file is stored at:
```
~/.config/appmotel/<app>/.auto-debug-cooldown
```

To force a re-check (e.g., after deploying a fix), delete the cooldown file:
```bash
rm ~/.config/appmotel/<app>/.auto-debug-cooldown
```

## Error Detection Patterns

The log scan uses case-insensitive grep with these patterns:

| Pattern | Catches |
|---------|---------|
| `ERROR` | Python logging, generic frameworks, Java |
| `CRITICAL` | Python logging critical level |
| `EXCEPTION` | Python/Java exception messages |
| `TRACEBACK` | Python `Traceback (most recent call last):` |
| `FATAL` | Go `log.Fatal`, generic fatal errors |
| `PANIC:` | Go `panic:` runtime errors |
| `UnhandledPromise` | Node.js `UnhandledPromiseRejectionWarning` |

## GitHub Issue Format

Filed issues include:

- **Title:** `[appmotel] <Claude's one-line summary>`
- **Body:**
  - Server hostname and UTC timestamp
  - Error excerpt (just the matched error lines)
  - Claude Code analysis (cause + suggested fix)
  - Full recent logs in a collapsible `<details>` block
  - Footer with opt-out instructions

## Architecture Notes

### Where the code lives

- **`bin/appmo` — `check_app_errors()`** (lines ~3133-3292): The main function
- **`bin/appmo` — `cmd_autopull()`**: Calls `check_app_errors "${app_name}"` at the end of each app's update-check iteration

### Metadata dependency

The function reads `GITHUB_URL` from `~/.config/appmotel/<app>/metadata.conf` (written by `save_app_metadata()` during `appmo add`). This is the target repo for `gh issue create`. If `GITHUB_URL` is missing, auto-debug is skipped for that app.

### Deduplication strategy

A simple timestamp-based cooldown file. The system does **not** track error fingerprints — if the same error recurs after the cooldown expires, a new issue will be filed. This is intentional: recurring errors after 24 hours likely indicate the issue wasn't resolved.

### Failure modes

All failures are non-fatal (the function returns 0):

| Condition | Behavior |
|-----------|----------|
| No errors in logs | Silent return |
| `claude` not installed | Logs: "auto-debug requires Claude Code CLI" |
| `gh` not installed | Logs: "auto-debug requires the GitHub CLI" |
| `gh` not authenticated | Logs: "auto-debug requires 'gh auth login'" |
| No `GITHUB_URL` in metadata | Logs warning, skips |
| Claude returns empty output | Logs warning, skips |
| `gh issue create` fails | Logs warning, does NOT write cooldown (will retry next cycle) |

### Security considerations

- Claude Code runs in non-interactive print mode (`-p`) — no filesystem access, no code execution
- The `gh` CLI must be pre-authenticated; auto-debug does not store or handle any credentials
- Log content is sent to Claude's API for analysis; ensure no secrets are logged by your apps
- Issues are filed under the authenticated GitHub user's identity
