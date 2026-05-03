# CLAUDE-CODE-SPEC — Claude Code CLI & Telegram Bot

Source module: `ops/modules/ai-agent.sh`
Menu path: `ops -> 8) AI Agent Integration -> 2) Claude Code CLI Integration`

---

## 1. Scope of ai-agent.sh

`ai-agent.sh` implements two top-level menus under `menu_ai_agent()`:

| Choice | Menu |
|---|---|
| 1 | Codex CLI Integration (`menu_codex_cli` — defined in `codex-cli.sh`) |
| 2 | Claude Code CLI Integration (`menu_claude_cli`) |

This spec covers choice 2 only. For Codex CLI see `docs/reference/CODEX-CLI-SPEC.md` or `modules/codex-cli.sh` directly.

---

## 2. Claude Code CLI menu actions

`menu_claude_cli()` dispatches 5 actions:

| Choice | Function | What it does |
|---|---|---|
| 1 | `install_claude_cli` | `npm install -g @anthropic-ai/claude-code`; records version + date to state file |
| 2 | `configure_claude_cli` | Prompts mode (CLIProxyAPI local / Anthropic direct), API key, Model; writes managed export block to admin `~/.bashrc` |
| 3 | `test_claude_cli` | Shows version, secret-file presence status, model, endpoint HTTP status |
| 4 | `install_claude_vietnamese_fix` | Git clones `daotaolaixe-quangthang/claude-code-vietnamese-fix`, runs `install.sh` or `setup.sh` |
| 5 | `menu_telegram_bot` | Opens Claude Code Telegram Bot submenu (5 actions) |

---

## 3. Config paths and permissions

| Artefact | Path | Permission | Note |
|---|---|---|---|
| OPS state file | `/etc/ops/claude-code.conf` | 0640, owned by admin | Tracks install state, version, model, endpoint — NO API key |
| API key file | `~/.claude-api-key` | 0600, owned by admin | Canonical Claude secret file |
| Shell env block | `~/.bashrc` of admin user | Inherited from file | Managed loader block that reads `~/.claude-api-key` |
| Telegram bot dir | `~/claude-telegram/` (`$(_tg_dir)`) | Owned by admin | Source + config for the bot |
| Telegram bot env | `~/claude-telegram/.env` | 0600, owned by admin | Bot-local config + secret file |
| Bot PID file | `~/claude-telegram/claude-telegram-bot.pid` | Created at runtime | Present when bot runs via nohup fallback |
| Bot log (nohup) | `~/claude-telegram-bot.log` | Owned by admin | Used when systemd service not present |

### Why API key goes in `~/.claude-api-key`, not `/etc/ops/`

`/etc/ops/` is readable by root + admin group. For Claude Code CLI, OPS keeps the raw key in owner-only `~/.claude-api-key` and lets admin `~/.bashrc` read from that file at shell startup.

This keeps:
- `/etc/ops/claude-code.conf` as metadata only
- the shell block free of inline secrets
- Claude CLI compatible with environment-based auth

### `~/.bashrc` config block format

When mode is **CLIProxyAPI (local)** (default, recommended):

```bash
# OPS: claude-code config
export ANTHROPIC_BASE_URL=http://127.0.0.1:8317
export ANTHROPIC_MODEL=claude-opus-4-5-20251101
if [[ -f ~/.claude-api-key ]]; then
    export ANTHROPIC_API_KEY="$(tr -d '\r\n' < ~/.claude-api-key)"
    export ANTHROPIC_AUTH_TOKEN="${ANTHROPIC_API_KEY}"
else
    unset ANTHROPIC_API_KEY
    unset ANTHROPIC_AUTH_TOKEN
fi
# OPS: claude-code config end
```

Note: `ANTHROPIC_BASE_URL` for CLIProxyAPI has NO `/v1` suffix. The Anthropic SDK appends `/v1` automatically. Using `http://127.0.0.1:8317/v1` would cause double-path errors.

When mode is **Anthropic API (direct)**, the same block format is used, but `ANTHROPIC_BASE_URL` points to `https://api.anthropic.com` and `~/.claude-api-key` stores the direct API key.

The block is delimited by `# OPS: claude-code config` and `# OPS: claude-code config end`.
`configure_claude_cli()` rewrites only that managed block, validates shell syntax, and keeps a backup before modification.

---

## 4. State file keys (claude-code.conf)

Written via `_claude_set_state()` -> `ops_conf_set()`:

| Key | Set by | Value |
|---|---|---|
| `CLAUDE_INSTALLED` | `install_claude_cli` | `yes` |
| `CLAUDE_VERSION` | `install_claude_cli` | output of `claude --version` |
| `CLAUDE_INSTALL_DATE` | `install_claude_cli` | `YYYY-MM-DD` |
| `CLAUDE_BASE_URL` | `configure_claude_cli` | endpoint URL |
| `CLAUDE_MODEL` | `configure_claude_cli` | model name |
| `CLAUDE_VIETNAMESE_FIX` | `install_claude_vietnamese_fix` | `yes` |
| `CLAUDE_VIETNAMESE_FIX_DATE` | `install_claude_vietnamese_fix` | `YYYY-MM-DD` |
| `CLAUDE_TG_INSTALLED` | `install_claude_telegram_bot` | `yes` |
| `CLAUDE_TG_INSTALL_DATE` | `install_claude_telegram_bot` | `YYYY-MM-DD` |
| `CLAUDE_TG_BOT_USERNAME` | `configure_claude_telegram_bot` | Telegram bot username |
| `CLAUDE_TG_ALLOWED_USERS` | `configure_claude_telegram_bot` | comma-separated Telegram user IDs |
| `CLAUDE_TG_APPROVED_DIR` | `configure_claude_telegram_bot` | directory Claude Code is allowed to operate in |

**API key is NOT stored in this file.**

---

## 5. Claude Code Telegram Bot

`menu_telegram_bot()` is a submenu with 5 actions:

| Choice | Function | What it does |
|---|---|---|
| 1 | `install_claude_telegram_bot` | warns operator, then clones from GitHub, creates `~/claude-telegram/`, builds a venv, installs the package, and copies `.env.example` -> `.env` if `.env` not present |
| 2 | `configure_claude_telegram_bot` | Prompts bot token, username, allowed user IDs, approved dir; copies `ANTHROPIC_*` from canonical Claude config (`claude-code.conf` + `~/.claude-api-key`); writes `~/claude-telegram/.env` (0600) |
| 3 | `start_claude_telegram_bot` | Prefers systemd service `claude-telegram-bot`; falls back to `nohup ~/claude-telegram/.venv/bin/claude-telegram-bot` as admin user |
| 4 | `stop_claude_telegram_bot` | `systemctl stop` or `kill` by PID file |
| 5 | `status_claude_telegram_bot` | `systemctl status` or PID file check; shows last 10 log lines |

### `.env` written by `configure_claude_telegram_bot`

Values are written as quoted dotenv entries so paths and secrets stay parseable.

```dotenv
TELEGRAM_BOT_TOKEN="<hidden>"
TELEGRAM_BOT_USERNAME="<name>"
APPROVED_DIRECTORY="<dir>"
ALLOWED_USERS="<user_id1>,<user_id2>"
AGENTIC_MODE="true"
VERBOSE_LEVEL="1"
ANTHROPIC_API_KEY="<copied from ~/.claude-api-key>"
ANTHROPIC_BASE_URL="<copied from claude-code.conf>"
ANTHROPIC_MODEL="<copied from claude-code.conf>"
```

`ANTHROPIC_*` lines are only appended when Claude Code CLI has already been configured.

### Bot source repository

```
https://github.com/daotaolaixe-quangthang/claude-code-telegram
```

### Start mechanism priority

1. If systemd unit `claude-telegram-bot.service` is registered -> `systemctl start`
2. Else -> `nohup ~/claude-telegram/.venv/bin/claude-telegram-bot` as admin user, PID written to `~/claude-telegram/claude-telegram-bot.pid`, log written to `~/claude-telegram-bot.log`
3. In nohup fallback mode, OPS also exports `ANTHROPIC_API_KEY` from `~/.claude-api-key` before launch

---

## 6. Vietnamese fix

Source: `https://github.com/daotaolaixe-quangthang/claude-code-vietnamese-fix`

- Warns operator that this is third-party code from GitHub
- Requires explicit confirmation before cloning/executing
- Git cloned to a temp dir
- Runs `install.sh` if present, else `setup.sh`
- If neither exists, lists directory and warns operator
- Temp dir cleaned up regardless

Sets `CLAUDE_VIETNAMESE_FIX=yes` in state file when complete.

---

## 7. Security rules

1. `~/.claude-api-key` must stay `0600` and admin-owned.
2. `~/claude-telegram/.env` must stay `0600` and admin-owned.
3. API key must NOT be written to `/etc/ops/claude-code.conf` or any group-readable state file.
4. `claude-code.conf` is always `chmod 640` after every `_claude_set_state` call.
5. The managed `.bashrc` block is validated with `bash -n` and backed up before rewrite.
6. Telegram `.env` values are written as quoted dotenv entries to avoid parsing drift.
7. Bot token and Claude API key are collected with hidden input.
8. Third-party install flows warn and require explicit confirmation before cloning/executing code.

---

## 8. Rollback

### Uninstall Claude Code CLI

```bash
npm uninstall -g @anthropic-ai/claude-code
rm -f ~/.claude-api-key

# Remove managed config block from ~/.bashrc
sed -i '/# OPS: claude-code config/,/# OPS: claude-code config end/d' ~/.bashrc
```

### Remove Claude Code state

```bash
rm -f /etc/ops/claude-code.conf
```

### Uninstall Telegram bot

```bash
# Stop first
ops -> 8 -> 2 -> 5 -> 4  (Stop)

# Remove files
rm -rf ~/claude-telegram/
rm -f ~/claude-telegram-bot.log
rm -f ~/claude-telegram/claude-telegram-bot.pid

# Remove state keys (or delete whole state file)
rm -f /etc/ops/claude-code.conf
```

### Restore `.bashrc` backup

Managed block rewrites keep timestamped backups at `<file>.bak.<timestamp>`.

```bash
ls ~/.bashrc.bak.*
cp ~/.bashrc.bak.<timestamp> ~/.bashrc
```

---

## 9. Verify checklist

```bash
# Claude Code CLI installed
claude --version

# Secret + shell wiring
ls -la ~/.claude-api-key           # expect: -rw-------
grep "OPS: claude-code" ~/.bashrc

# State file
cat /etc/ops/claude-code.conf
ls -la /etc/ops/claude-code.conf   # expect: -rw-r----- admin admin

# Telegram bot env
ls -la ~/claude-telegram/.env      # expect: -rw------- admin admin
grep -v 'ANTHROPIC_API_KEY' ~/claude-telegram/.env

# Bot running (nohup mode)
cat ~/claude-telegram/claude-telegram-bot.pid
kill -0 $(cat ~/claude-telegram/claude-telegram-bot.pid)
```

---

## 10. Authority boundary

- `ai-agent.sh` does NOT manage Telegram alert notifications (system monitoring) — that is `modules/monitoring.sh`.
- `ai-agent.sh` Telegram bot is an operator convenience tool; system health alerts are separate.
- Claude Code API key lives in `~/.claude-api-key`, not in `/etc/ops/` or `/etc/ops/claude-code.conf` — this is the runtime contract.
