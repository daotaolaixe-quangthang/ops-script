## Codex CLI - Implementation Spec for OPS

> Product: OpenAI Codex CLI (`@openai/codex`)
> Source: https://github.com/openai/codex
> Purpose: AI-assisted terminal coding agent used on VPS for ops automation

---

### 1. What is Codex CLI?

Codex CLI (`codex`) is OpenAI's terminal coding agent.

On an OPS-managed VPS, it is used as:

- an AI assistant for writing and debugging Bash scripts
- a companion tool for CLIProxyAPI workflows
- an operator productivity tool for AI-assisted runbook execution

**Two operation modes:**

| Mode | Auth method | When to use |
|---|---|---|
| ChatGPT plan (Plus/Pro/Team) | OAuth login (browser) | If operator has ChatGPT subscription |
| API key mode | `OPENAI_API_KEY` or custom endpoint | If using CLIProxyAPI or another OpenAI-compatible provider |

---

### 2. Install flow (inside `modules/codex-cli.sh`)

#### 2.1 Install method: npm global

```bash
npm install -g @openai/codex
codex --version
```

Why npm, not a binary release:

- consistent with the Node ecosystem already present on OPS hosts
- simple update path via `npm update -g`
- no architecture-specific download logic required

---

### 3. Configuration

Codex CLI config lives at `~/.codex/config.toml`.

OPS manages these configuration paths:

- `~/.codex/config.toml`
- `/etc/ops/codex-cli.conf`
- `/etc/ops/.codex-api-key`

#### 3.1 Using with CLIProxyAPI (recommended on OPS VPS)

When CLIProxyAPI is installed, Codex CLI should point to it as the API endpoint:

```toml
[model]
provider = "openai"
name     = "if/kimi-k2-thinking"

[provider.openai]
base_url = "http://127.0.0.1:8317/v1"
api_key  = "<api-key-from-/etc/ops/.cli-proxy-api-key-or-operator-input>"
```

OPS state example:

```bash
# /etc/ops/codex-cli.conf
CODEX_INSTALLED="yes"
CODEX_VERSION="$(codex --version 2>/dev/null)"
CODEX_MODE="cliproxyapi"
CODEX_ENDPOINT="http://127.0.0.1:8317/v1"
CODEX_API_KEY_FILE="/etc/ops/.codex-api-key"
CODEX_MODEL="if/kimi-k2-thinking"
CODEX_INSTALL_DATE="2026-04-28"
```

The actual key must be stored separately:

```bash
# /etc/ops/.codex-api-key  (0600, owned by admin user)
sk_local_xxxxxxxxxxxxxxxx
```

#### 3.2 Using with OpenAI API key directly

```bash
# Stored in /etc/ops/.codex-api-key (0600)
OPENAI_API_KEY=sk-proj-...
```

OPS can expose this via the admin shell environment when the operator enables auto env.

#### 3.3 Using with ChatGPT OAuth

No API key is needed.
OPS can only:

1. install Codex CLI
2. instruct the operator to run `codex` once and complete browser login
3. test that `codex --version` works

---

### 4. Menu actions in `modules/codex-cli.sh`

```text
1. Install Codex CLI        -> npm install -g @openai/codex
2. Configure Codex          -> write ~/.codex/config.toml + /etc/ops/codex-cli.conf
3. Enable/disable auto env  -> add/remove OPENAI_API_KEY export from ~/.bash_profile
4. Test Codex CLI           -> codex --version + endpoint reachability test
0. Back
```

#### Action implementations

**Install:**
```bash
install_codex_cli() {
    log_info "Installing Codex CLI..."
    npm install -g @openai/codex
    local version
    version=$(codex --version 2>/dev/null)
    ops_conf_set codex-cli.conf CODEX_INSTALLED "yes"
    ops_conf_set codex-cli.conf CODEX_VERSION "$version"
    ops_conf_set codex-cli.conf CODEX_INSTALL_DATE "$(date +%Y-%m-%d)"
}
```

**Configure (CLIProxyAPI mode):**
```bash
configure_codex_with_cliproxyapi() {
    local api_key
    api_key=$(cat /etc/ops/.cli-proxy-api-key)

    echo "$api_key" > /etc/ops/.codex-api-key
    chmod 600 /etc/ops/.codex-api-key
    chown "$ADMIN_USER:$ADMIN_USER" /etc/ops/.codex-api-key

    mkdir -p "/home/$ADMIN_USER/.codex"
    cat > "/home/$ADMIN_USER/.codex/config.toml" <<EOF
[model]
provider = "openai"
name     = "if/kimi-k2-thinking"

[provider.openai]
base_url = "http://127.0.0.1:8317/v1"
api_key  = "${api_key}"
EOF
    chown -R "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER/.codex"
    chmod 600 "/home/$ADMIN_USER/.codex/config.toml"

    ops_conf_set codex-cli.conf CODEX_MODE "cliproxyapi"
    ops_conf_set codex-cli.conf CODEX_ENDPOINT "http://127.0.0.1:8317/v1"
    ops_conf_set codex-cli.conf CODEX_MODEL "if/kimi-k2-thinking"
}
```

**Enable auto env:**
```bash
enable_codex_auto_env() {
    local marker="# OPS: codex-cli auto env"
    local profile="/home/$ADMIN_USER/.bash_profile"

    cat >> "$profile" <<EOF

${marker}
if [[ -f /etc/ops/.codex-api-key ]]; then
    export OPENAI_API_KEY="$(cat /etc/ops/.codex-api-key)"
fi
EOF

    ops_conf_set codex-cli.conf CODEX_AUTO_ENV "yes"
}
```

**Disable auto env:**
```bash
disable_codex_auto_env() {
    sed -i '/# OPS: codex-cli auto env/,/^fi$/d' "/home/$ADMIN_USER/.bash_profile"
    ops_conf_set codex-cli.conf CODEX_AUTO_ENV "no"
}
```

**Test:**
```bash
test_codex_cli() {
    echo "Version: $(codex --version 2>/dev/null || echo 'NOT FOUND')"
    echo "Config:  $(ls ~/.codex/config.toml 2>/dev/null || echo 'NOT CONFIGURED')"
    if [[ "$CODEX_MODE" == "cliproxyapi" ]]; then
        echo "CLIProxyAPI endpoint reachable: $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8317/v1/models)"
    fi
}
```

---

### 5. Runtime state

| Artefact | Path | Permissions |
|---|---|---|
| Codex binary | `/usr/local/bin/codex` | 755 |
| Codex config | `~/.codex/config.toml` | 600, owned by admin user |
| Codex API key file | `/etc/ops/.codex-api-key` | 600, owned by admin user |
| OPS state | `/etc/ops/codex-cli.conf` | 640 |

---

### 6. Verify

```bash
command -v codex && codex --version
ls -la ~/.codex/config.toml
grep -r "api_key\|OPENAI_API_KEY" /var/log/ops/ 2>/dev/null | grep -v "KEY_FILE"
curl -s http://127.0.0.1:8317/v1/models
```

If API key mode is enabled, test with the configured key:

```bash
curl -s -H "Authorization: Bearer $(cat /etc/ops/.codex-api-key)" \
  http://127.0.0.1:8317/v1/models
```

---

### 7. Rollback

```bash
disable_codex_auto_env
rm -f ~/.codex/config.toml /etc/ops/.codex-api-key
npm uninstall -g @openai/codex
ops_conf_set codex-cli.conf CODEX_INSTALLED "no"
```

---

### 8. Security rules

- never print API keys to terminal or logs
- never store the raw key in `/etc/ops/codex-cli.conf`
- never commit `.codex-api-key` to the repo
- `~/.codex/config.toml` must stay `0600`
- auto env must remain opt-in only
