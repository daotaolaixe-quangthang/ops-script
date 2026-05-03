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

**Supported operation modes:**

| Mode | Auth method | When to use |
|---|---|---|
| CLIProxyAPI local mode | `CLI_PROXY_API_KEY` loaded from `/etc/ops/.cli-proxy-api-key` | Recommended on OPS hosts using the local provider service |
| OpenAI API mode | `OPENAI_API_KEY` loaded from `/etc/ops/.codex-api-key` | If using OpenAI directly |
| Custom endpoint mode | `OPENAI_API_KEY` loaded from `/etc/ops/.codex-api-key` | If using another OpenAI-compatible provider |
| ChatGPT OAuth | Browser login | If operator has ChatGPT subscription |

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
- `/etc/ops/.cli-proxy-api-key` (CLIProxyAPI mode)
- `/etc/ops/.codex-api-key` (OpenAI API and custom endpoint modes)
- admin `~/.bashrc` (managed loader block for `CLI_PROXY_API_KEY` in CLIProxyAPI mode)
- admin `~/.bash_profile` (managed loader block for `OPENAI_API_KEY` when auto env is enabled)

#### 3.1 Using with CLIProxyAPI (recommended on OPS VPS)

When CLIProxyAPI is installed, Codex CLI points to it as the API endpoint.

OPS writes `~/.codex/config.toml` with this format:

```toml
model = "gpt-5.4"
model_provider = "cliproxyapi"
model_reasoning_effort = "medium"

[model_providers.cliproxyapi]
name = "CLIProxyAPI"
base_url = "http://127.0.0.1:8317/v1"
wire_api = "responses"
env_key = "CLI_PROXY_API_KEY"
env_key_instructions = "Set CLI_PROXY_API_KEY to your CLIProxyAPI api key (from /etc/ops/.cli-proxy-api-key)"

[profiles.max]
model = "gpt-5.4"
model_provider = "cliproxyapi"

[profiles.fast]
model = "gpt-5.3-codex"
model_provider = "cliproxyapi"
```

Key notes:
- `wire_api = "responses"` tells Codex CLI to use Responses API format.
- API key is NOT stored in `config.toml` or `codex-cli.conf`.
- OPS keeps `/etc/ops/.cli-proxy-api-key` as the canonical secret and writes a managed loader block in admin `~/.bashrc`:

```bash
# OPS: codex-cliproxyapi env
if [[ -f /etc/ops/.cli-proxy-api-key ]]; then
    export CLI_PROXY_API_KEY="$(tr -d '\r\n' < /etc/ops/.cli-proxy-api-key)"
else
    unset CLI_PROXY_API_KEY
fi
# OPS: codex-cliproxyapi env end
```

OPS state:

```bash
# /etc/ops/codex-cli.conf
CODEX_INSTALLED="yes"
CODEX_VERSION="<version>"
CODEX_MODE="cliproxyapi"
CODEX_ENDPOINT="http://127.0.0.1:8317/v1"
CODEX_MODEL="gpt-5.4"
CODEX_API_KEY_FILE=""
CODEX_INSTALL_DATE="2026-04-28"
```

#### 3.2 Using with OpenAI API key directly

OPS stores the key in `/etc/ops/.codex-api-key` (`0600`) and writes `~/.codex/config.toml` without any inline secret:

```toml
[model]
provider = "openai"
name     = "gpt-4o"

[provider.openai]
base_url = "https://api.openai.com/v1"
```

To run Codex in this mode, the operator must either:
- enable Codex auto env (`OPENAI_API_KEY` loader block in admin `~/.bash_profile`), or
- export `OPENAI_API_KEY` manually before running `codex`

#### 3.3 Using with a custom endpoint

OPS stores the key in `/etc/ops/.codex-api-key` (`0600`) and writes `~/.codex/config.toml` with the chosen model and base URL, again without any inline secret:

```toml
[model]
provider = "openai"
name     = "gpt-4o"

[provider.openai]
base_url = "https://provider.example/v1"
```

This mode also relies on `OPENAI_API_KEY` coming from Codex auto env or a manual export.

#### 3.4 Using with ChatGPT OAuth

No API key is needed.
OPS can only:

1. install Codex CLI
2. instruct the operator to run `codex` once and complete browser login
3. test that `codex --version` works

---

### 4. Menu actions in `modules/codex-cli.sh`

```text
1. Install Codex CLI        -> npm install -g @openai/codex
2. Configure Codex          -> choose one of 4 modes:
                               - CLIProxyAPI endpoint (recommended)
                               - OpenAI API key
                               - ChatGPT OAuth
                               - Custom endpoint
3. Enable/disable auto env  -> add/remove managed OPENAI_API_KEY loader block in admin ~/.bash_profile
4. Test Codex CLI           -> codex --version + config path + optional CLIProxyAPI reachability check
0. Back
```

#### Runtime behaviour summary

- **Install** records `CODEX_INSTALLED`, version, and install date in `/etc/ops/codex-cli.conf`.
- **Configure / CLIProxyAPI mode**:
  - writes `~/.codex/config.toml` in `env_key = "CLI_PROXY_API_KEY"` format
  - keeps `/etc/ops/.cli-proxy-api-key` as the canonical secret
  - writes a managed loader block into admin `~/.bashrc`
- **Configure / OpenAI API mode**:
  - stores the key in `/etc/ops/.codex-api-key`
  - writes `~/.codex/config.toml` without any inline secret
  - relies on Codex auto env or a manual `OPENAI_API_KEY` export at runtime
- **Configure / Custom endpoint mode**:
  - stores the key in `/etc/ops/.codex-api-key`
  - writes `~/.codex/config.toml` with provider/model/base URL only
  - relies on Codex auto env or a manual `OPENAI_API_KEY` export at runtime
- **Enable auto env** writes a managed loader block into admin `~/.bash_profile`:

```bash
# OPS: codex-cli auto env
if [[ -f /etc/ops/.codex-api-key ]]; then
    export OPENAI_API_KEY="$(tr -d '\r\n' < /etc/ops/.codex-api-key)"
else
    unset OPENAI_API_KEY
fi
# OPS: codex-cli auto env end
```

- **Disable auto env** removes only that managed block.
- **Test** prints version, config path, and for CLIProxyAPI mode the HTTP status from `http://127.0.0.1:8317/v1/models`.

---

### 5. Runtime state

| Artefact | Path | Permissions |
|---|---|---|
| Codex binary | `/usr/local/bin/codex` | 755 |
| Codex config | `~/.codex/config.toml` | 600, owned by admin user |
| CLIProxyAPI key (local mode) | `/etc/ops/.cli-proxy-api-key` | 600, owned by admin user |
| Codex API key (direct/custom modes) | `/etc/ops/.codex-api-key` | 600, owned by admin user |
| CLIProxyAPI loader block | admin `~/.bashrc` | inherited from file |
| Auto env block | admin `~/.bash_profile` | inherited from file |
| OPS state | `/etc/ops/codex-cli.conf` | 640 |

---

### 6. Verify

```bash
command -v codex && codex --version
ls -la ~/.codex/config.toml
grep -n "OPS: codex-cliproxyapi env" ~/.bashrc 2>/dev/null
grep -n "OPS: codex-cli auto env" ~/.bash_profile 2>/dev/null
ls -la /etc/ops/.cli-proxy-api-key /etc/ops/.codex-api-key 2>/dev/null
curl -s http://127.0.0.1:8317/v1/models
```

Direct/custom modes should not inline the secret into `~/.codex/config.toml`; instead verify that `OPENAI_API_KEY` is loaded from auto env or exported manually before running `codex`.

---

### 7. Rollback

```bash
# Remove managed loader blocks if present
sed -i '/# OPS: codex-cliproxyapi env/,/# OPS: codex-cliproxyapi env end/d' ~/.bashrc 2>/dev/null || true
sed -i '/# OPS: codex-cli auto env/,/# OPS: codex-cli auto env end/d' ~/.bash_profile 2>/dev/null || true

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
