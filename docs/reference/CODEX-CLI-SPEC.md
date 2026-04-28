## Codex CLI — Implementation Spec for OPS

> Product: OpenAI Codex CLI (`@openai/codex`)
> Source: https://github.com/openai/codex
> Purpose: AI-assisted terminal coding agent, used on VPS for ops automation

---

### 1. What is Codex CLI?

Codex CLI (`codex`) is OpenAI's lightweight coding agent that runs in the terminal.

On an OPS-managed VPS, it is used as:
- An AI assistant for writing and debugging bash scripts
- A companion tool for 9Router workflows (using 9router as the API endpoint)
- An operator productivity tool for AI-assisted runbook execution

**Two operation modes:**

| Mode | Auth method | When to use |
|---|---|---|
| ChatGPT plan (Plus/Pro/Team) | OAuth login (browser) | If operator has ChatGPT subscription |
| API key mode | `OPENAI_API_KEY` or custom endpoint | If using 9router or other OpenAI-compatible provider |

---

### 2. Install Flow (inside `modules/codex-cli.sh`)

#### 2.1 Install method: npm global

```bash
# Requires Node.js 20+ (already installed by node module)
npm install -g @openai/codex

# Verify
codex --version
```

> **Why npm, not binary release?** The `npm install -g` method auto-updates via `npm update -g`,
> is consistent with the Node ecosystem already installed by OPS, and avoids architecture-specific
> binary download logic.

#### 2.2 Alternative: pre-built binary (for minimal Node environments)

Not recommended for OPS since Node.js is already installed. Document for reference only:

```bash
# Linux x86_64
ARCH="x86_64-unknown-linux-musl"
RELEASE=$(curl -s https://api.github.com/repos/openai/codex/releases/latest | grep tag_name | cut -d'"' -f4)
curl -L "https://github.com/openai/codex/releases/download/${RELEASE}/codex-${ARCH}.tar.gz" -o /tmp/codex.tar.gz
tar -xzf /tmp/codex.tar.gz -C /tmp/
mv /tmp/codex-${ARCH} /usr/local/bin/codex
chmod +x /usr/local/bin/codex
```

---

### 3. Configuration

Codex CLI config lives at `~/.codex/config.toml` (or `~/.codex/config.json` depending on version).

OPS manages the following configuration aspects:

#### 3.1 Using with 9router (recommended on OPS VPS)

When 9router is installed, Codex CLI can point to it as the API endpoint:

```toml
# ~/.codex/config.toml (for the admin user)
[model]
provider = "openai"
name     = "if/kimi-k2-thinking"    # or any 9router model prefix

[provider.openai]
base_url = "http://127.0.0.1:20128/v1"
api_key  = "<api-key-from-9router-dashboard>"
```

Store the 9router API key in the OPS state file (not in code):

```bash
# /etc/ops/codex-cli.conf
CODEX_INSTALLED="yes"
CODEX_VERSION="$(codex --version 2>/dev/null)"
CODEX_MODE="9router"               # "9router" | "openai-api" | "chatgpt-oauth"
CODEX_ENDPOINT="http://127.0.0.1:20128/v1"
CODEX_API_KEY_FILE="/etc/ops/.codex-api-key"   # file holding the actual key, 0600
CODEX_MODEL="if/kimi-k2-thinking"
CODEX_INSTALL_DATE="2026-03-18"
```

The actual API key MUST be stored in a separate restricted file:

```bash
# /etc/ops/.codex-api-key  (0600, owned by admin user)
sk_9router_xxxxxxxxxxxxxxxx
```

#### 3.2 Using with OpenAI API key directly

```bash
# Stored in /etc/ops/.codex-api-key (0600)
OPENAI_API_KEY=sk-proj-...
```

OPS sets this in the admin user's environment via a non-secret env export:

```bash
# Added to ~/.bash_profile (guarded, only if mode = openai-api)
if [[ -f /etc/ops/.codex-api-key ]]; then
    export OPENAI_API_KEY="$(cat /etc/ops/.codex-api-key)"
fi
```

#### 3.3 Using with ChatGPT OAuth

No key needed. Operator runs `codex` once after install → interactive browser OAuth.
OPS cannot automate this — it can only:
1. Install codex
2. Instruct operator to run `codex` once to login
3. Test that `codex --version` works

---

### 4. Menu Actions in `modules/codex-cli.sh`

Corresponding to `MENU-REFERENCE.md` Section 9:

```
1. Install Codex CLI        → npm install -g @openai/codex
2. Configure Codex          → write ~/.codex/config.toml + /etc/ops/codex-cli.conf
3. Enable/disable auto env  → add/remove OPENAI_API_KEY export from ~/.bash_profile
4. Test Codex CLI           → codex --version + simple model query test
0. Back
```

#### Action implementations:

**Install:**
```bash
install_codex_cli() {
    log_info "Installing Codex CLI..."
    npm install -g @openai/codex
    local version
    version=$(codex --version 2>/dev/null)
    log_info "Codex CLI installed: $version"
    ops_conf_set codex-cli.conf CODEX_INSTALLED "yes"
    ops_conf_set codex-cli.conf CODEX_VERSION   "$version"
    ops_conf_set codex-cli.conf CODEX_INSTALL_DATE "$(date +%Y-%m-%d)"
}
```

**Configure (9router mode):**
```bash
configure_codex_with_9router() {
    local api_key
    read -r -s -p "Paste API key from 9router dashboard: " api_key
    echo

    # Store key securely
    echo "$api_key" > /etc/ops/.codex-api-key
    chmod 600 /etc/ops/.codex-api-key
    chown "$ADMIN_USER":"$ADMIN_USER" /etc/ops/.codex-api-key

    # Write codex config
    mkdir -p "/home/$ADMIN_USER/.codex"
    cat > "/home/$ADMIN_USER/.codex/config.toml" <<EOF
[model]
provider = "openai"
name     = "if/kimi-k2-thinking"

[provider.openai]
base_url = "http://127.0.0.1:20128/v1"
api_key  = "${api_key}"
EOF
    chown -R "$ADMIN_USER":"$ADMIN_USER" "/home/$ADMIN_USER/.codex"
    chmod 600 "/home/$ADMIN_USER/.codex/config.toml"

    # Update OPS state
    ops_conf_set codex-cli.conf CODEX_MODE     "9router"
    ops_conf_set codex-cli.conf CODEX_ENDPOINT "http://127.0.0.1:20128/v1"
    ops_conf_set codex-cli.conf CODEX_MODEL    "if/kimi-k2-thinking"

    log_info "Codex CLI configured to use 9router"
}
```

**Enable auto env (adds OPENAI_API_KEY export to bash_profile):**
```bash
enable_codex_auto_env() {
    local marker="# OPS: codex-cli auto env"
    local profile="/home/$ADMIN_USER/.bash_profile"

    if grep -q "$marker" "$profile" 2>/dev/null; then
        log_warn "Codex auto env already enabled"
        return
    fi

    cat >> "$profile" <<EOF

${marker}
if [[ -f /etc/ops/.codex-api-key ]]; then
    export OPENAI_API_KEY="\$(cat /etc/ops/.codex-api-key)"
fi
EOF
    ops_conf_set codex-cli.conf CODEX_AUTO_ENV "yes"
    log_info "Codex auto env enabled"
}
```

**Disable auto env (removes the block):**
```bash
disable_codex_auto_env() {
    local profile="/home/$ADMIN_USER/.bash_profile"
    # Remove lines between marker and closing fi
    sed -i '/# OPS: codex-cli auto env/,/^fi$/d' "$profile"
    ops_conf_set codex-cli.conf CODEX_AUTO_ENV "no"
    log_info "Codex auto env disabled"
}
```

**Test:**
```bash
test_codex_cli() {
    print_section "Codex CLI Test"
    echo "Version: $(codex --version 2>/dev/null || echo 'NOT FOUND')"
    echo "Config:  $(ls ~/.codex/config.toml 2>/dev/null || echo 'NOT CONFIGURED')"
    if [[ "$CODEX_MODE" == "9router" ]]; then
        echo "9router endpoint reachable: $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:20128/v1/models)"
    fi
}
```

---

### 5. Runtime State

| Artefact | Path | Permissions |
|---|---|---|
| Codex binary | `/usr/local/bin/codex` (via npm global) | 755 |
| Codex config | `~/.codex/config.toml` | 600, owned by admin user |
| API key file | `/etc/ops/.codex-api-key` | 600, owned by admin user |
| OPS state | `/etc/ops/codex-cli.conf` | 640 |

---

### 6. Verify

```bash
# Binary present
command -v codex && codex --version

# Config exists
ls -la ~/.codex/config.toml

# No secrets in logs
grep -r "api_key\|OPENAI_API_KEY" /var/log/ops/ 2>/dev/null | grep -v "KEY_FILE"

# If 9router mode: endpoint reachable
curl -s http://127.0.0.1:20128/v1/models | python3 -c "import sys,json; print(json.load(sys.stdin)['object'])"
```

---

### 7. Rollback

```bash
# Disable auto env
disable_codex_auto_env

# Remove config
rm -f ~/.codex/config.toml /etc/ops/.codex-api-key

# Uninstall
npm uninstall -g @openai/codex

# Reset OPS state
ops_conf_set codex-cli.conf CODEX_INSTALLED "no"
```

---

### 8. Security Rules (non-negotiable)

- NEVER print API key to terminal or logs
- NEVER store API key in `/etc/ops/codex-cli.conf` (only store in `/etc/ops/.codex-api-key`)
- NEVER commit `.codex-api-key` to any repo
- `~/.codex/config.toml` must have permission `0600`
- Auto env must be opt-in only (never enabled silently by installer)
