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

This spec covers choice 2 only. For Codex CLI see `docs/CODEX-CLI-SPEC.md` (if exists) or `modules/codex-cli.sh` directly.

---

## 2. Claude Code CLI menu actions

`menu_claude_cli()` dispatches 5 actions:

| Choice | Function | What it does |
|---|---|---|
| 1 | `install_claude_cli` | `npm install -g @anthropic-ai/claude-code`; records version + date to state file |
| 2 | `configure_claude_cli` | Prompts mode (CLIProxyAPI local / Anthropic direct), API key, Model; writes export block to admin `~/.bashrc` |
| 3 | `test_claude_cli` | Shows version, masked API key, model, endpoint HTTP status |
| 4 | `install_claude_vietnamese_fix` | Git clones `daotaolaixe-quangthang/claude-code-vietnamese-fix`, runs `install.sh` or `setup.sh` |
| 5 | `menu_telegram_bot` | Opens Claude Code Telegram Bot submenu (5 actions) |

---

## 3. Config paths and permissions

| Artefact | Path | Permission | Note |
|---|---|---|---|
| OPS state file | `/etc/ops/claude-code.conf` | 0640, owned by admin | Tracks install state, version, model, endpoint — NO API key |
| API key + env vars | `~/.bashrc` of admin user | Inherited from file (0644 or 0600) | API key written as `export ANTHROPIC_API_KEY=...` |
| Telegram bot dir | `~/claude-telegram/` (`$(_tg_dir)`) | Owned by admin | Source + config for the bot |
| Telegram bot env | `~/claude-telegram/.env` | 0600, owned by admin | Bot token, allowed users, ANTHROPIC_* vars |
| Bot PID file | `/var/run/claude-telegram-bot.pid` | Created at runtime | Only present when bot runs via nohup fallback |
| Bot log (nohup) | `~/claude-telegram-bot.log` | Owned by admin | Used when systemd service not present |

### Why API key goes in ~/.bashrc, not /etc/ops/

`/etc/ops/` is readable by root + admin group. `.bashrc` is owner-only.
Claude Code CLI reads `ANTHROPIC_API_KEY` from the environment at runtime, so exporting in `.bashrc` is sufficient and avoids centralised secret exposure.

### ~/.bashrc config block format

When mode is **CLIProxyAPI (local)** (default, recommended):

```
# OPS: claude-code config
export ANTHROPIC_BASE_URL=http://127.0.0.1:8317
export ANTHROPIC_API_KEY=<CLIProxyAPI api key from /etc/ops/.cli-proxy-api-key>
export ANTHROPIC_AUTH_TOKEN="${ANTHROPIC_API_KEY}"
export ANTHROPIC_MODEL="claude-opus-4-5-20251101"
```

Note: `ANTHROPIC_BASE_URL` for CLIProxyAPI has NO `/v1` suffix. The Anthropic SDK appends `/v1` automatically. Using `http://127.0.0.1:8317/v1` would cause double-path errors.

When mode is **Anthropic API (direct)**:

```
# OPS: claude-code config
export ANTHROPIC_BASE_URL=https://api.anthropic.com
export ANTHROPIC_API_KEY=sk-ant-...
export ANTHROPIC_AUTH_TOKEN="${ANTHROPIC_API_KEY}"
export ANTHROPIC_MODEL="claude-opus-4-5-20251101"
```

The block is delimited by the marker line `# OPS: claude-code config` and a blank line.
`configure_claude_cli()` removes the old block (idempotent) before writing the new one.
A `backup_file` of `.bashrc` is created before each modification.

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
| 1 | `install_claude_telegram_bot` | pip3 install from GitHub; git clone to `~/claude-telegram/`; copies `.env.example` -> `.env` if .env not present |
| 2 | `configure_claude_telegram_bot` | Prompts bot token, username, allowed user IDs, approved dir; auto-copies `ANTHROPIC_*` from `.bashrc`; writes `~/claude-telegram/.env` (0600) |
| 3 | `start_claude_telegram_bot` | Prefers systemd service `claude-telegram-bot`; falls back to `nohup python3 -m claude_code_telegram` as admin user |
| 4 | `stop_claude_telegram_bot` | `systemctl stop` or `kill` by PID file |
| 5 | `status_claude_telegram_bot` | `systemctl status` or PID file check; shows last 10 log lines |

### .env written by configure_claude_telegram_bot

```
TELEGRAM_BOT_TOKEN=<hidden>
TELEGRAM_BOT_USERNAME=<name>
APPROVED_DIRECTORY=<dir>
ALLOWED_USERS=<user_id1>,<user_id2>
AGENTIC_MODE=true
VERBOSE_LEVEL=1
ANTHROPIC_API_KEY=<copied from ~/.bashrc>
ANTHROPIC_BASE_URL=<copied from ~/.bashrc>
ANTHROPIC_MODEL=<copied from ~/.bashrc>
```

`ANTHROPIC_*` lines are only appended if found in `.bashrc`.

### Bot source repository

```
https://github.com/daotaolaixe-quangthang/claude-code-telegram
```

### Start mechanism priority

1. If systemd unit `claude-telegram-bot.service` is registered -> `systemctl start`
2. Else -> `nohup python3 -m claude_code_telegram` as admin user, PID written to `/var/run/claude-telegram-bot.pid`

---

## 6. Vietnamese fix

Source: `https://github.com/daotaolaixe-quangthang/claude-code-vietnamese-fix`

- Git cloned to a temp dir
- Runs `install.sh` if present, else `setup.sh`
- If neither exists, lists directory and warns operator
- Temp dir cleaned up regardless

Sets `CLAUDE_VIETNAMESE_FIX=yes` in state file when complete.

---

## 7. Security rules

1. `~/claude-telegram/.env` must always be `0600` owned by admin — enforced by `configure_claude_telegram_bot` and `install_claude_telegram_bot`
2. API key must NOT be written to `/etc/ops/claude-code.conf` or any group-readable file
3. `claude-code.conf` is always `chmod 640` after every `_claude_set_state` call
4. `backup_file` is called on `.bashrc` before any modification
5. Bot token collected with `read -r -s` (hidden input)
6. API key collected with `read -r -s` (hidden input)

---

## 8. Rollback

### Uninstall Claude Code CLI

```bash
npm uninstall -g @anthropic-ai/claude-code

# Remove config block from ~/.bashrc
grep -n "# OPS: claude-code config" ~/.bashrc   # find line
# Edit manually or run configure again with empty values
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
rm -f /var/run/claude-telegram-bot.pid

# Remove state keys (or delete whole state file)
rm -f /etc/ops/claude-code.conf
```

### Restore .bashrc backup

`backup_file` creates backups at `<file>.bak.<timestamp>` (convention from `core/utils.sh`).

```bash
ls ~/.bashrc.bak.*
cp ~/.bashrc.bak.<timestamp> ~/.bashrc
```

---

## 9. Verify checklist

```bash
# Claude Code CLI installed
claude --version

# Config in bashrc
grep "OPS: claude-code" ~/.bashrc

# State file
cat /etc/ops/claude-code.conf
ls -la /etc/ops/claude-code.conf   # expect: -rw-r----- admin admin

# Telegram bot env
ls -la ~/claude-telegram/.env       # expect: -rw------- admin admin
cat ~/claude-telegram/.env | grep -v API_KEY  # review without exposing key

# Bot running (nohup mode)
cat /var/run/claude-telegram-bot.pid
kill -0 $(cat /var/run/claude-telegram-bot.pid)
```

---

## 10. Authority boundary

- `ai-agent.sh` does NOT manage Telegram alert notifications (system monitoring) — that is `modules/monitoring.sh`.
- `ai-agent.sh` Telegram bot is an operator convenience tool; system health alerts are separate.
- Claude Code API key lives in `~/.bashrc`, not in `/etc/ops/` — this is intentional and must not be changed without updating this spec.
