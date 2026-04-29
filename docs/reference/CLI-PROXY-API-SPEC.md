## CLIProxyAPI - Implementation Spec for OPS

> Source repo: https://github.com/daotaolaixe-quangthang/CLIProxyAPI
> Release metadata: https://api.github.com/repos/router-for-me/CLIProxyAPI/releases/latest
> Runtime model: native Go binary + systemd
> Port: `8317` (fixed)
> Binding: `127.0.0.1:8317` only
> Implementation authority: `ops/modules/cli-proxy-api.sh`, `ops/modules/templates/nginx/cli-proxy-api.vhost.conf.tpl`, `ops/modules/nginx.sh`, `ops/modules/verify.sh`, `ops/modules/codex-cli.sh`

### Source of truth and agent guardrails

When docs, prompts, comments, and runtime observations disagree, defer to the implementation authority above.

- Do not switch CLIProxyAPI back to `0.0.0.0`.
- Do not open UFW port `8317`.
- Do not move CLIProxyAPI under PM2 or Docker as the primary OPS path.
- Keep Nginx as the only public entrypoint.
- Keep `proxy_buffering off` in the provider vhost.

---

### 1. What is CLIProxyAPI?

CLIProxyAPI is an OpenAI-compatible local proxy for AI coding tools and model providers.

On an OPS-managed VPS it is used to:

- provide a single local endpoint for Codex CLI, Claude Code compatible clients, Gemini-compatible flows, and similar tools
- keep provider auth material under the runtime user home directory
- expose a local OpenAI-compatible API at `http://127.0.0.1:8317/v1`
- publish that API safely through Nginx when the operator links a domain

Architecture on OPS-managed VPS:

```text
[AI CLI Tools] -> Nginx (public, 443) -> [CLIProxyAPI on 127.0.0.1:8317]
                                             |
                                             +-> provider auth in ~/.cli-proxy-api
```

---

### 2. Install flow (inside `modules/cli-proxy-api.sh`)

#### 2.1 Prerequisites

- systemd
- Nginx if the operator wants a public domain
- no PM2 requirement for CLIProxyAPI itself

#### 2.2 Download release and install

```bash
CLIPROXYAPI_INSTALL_DIR="/opt/cli-proxy-api"
CLIPROXYAPI_SERVICE_NAME="cli-proxy-api"
CLIPROXYAPI_PORT="8317"
RUNTIME_USER="<ops runtime user>"
RUNTIME_HOME="<runtime user home>"

# Fetch upstream latest release metadata
release_json=$(curl -fsSL "https://api.github.com/repos/router-for-me/CLIProxyAPI/releases/latest")

# Select Linux amd64 archive from assets, download, and extract binary into /opt/cli-proxy-api
mkdir -p "$CLIPROXYAPI_INSTALL_DIR"
```

OPS installs the binary into `/opt/cli-proxy-api`, preserves the config file across updates, and runs the service as the configured runtime user.

#### 2.3 Config file

OPS writes `/opt/cli-proxy-api/config.yaml` with these baseline rules:

```yaml
host: "127.0.0.1"
port: 8317
tls:
  enable: false
remote-management:
  allow-remote: false
  secret-key: ""
pprof:
  enable: false
auth-dir: "/home/<runtime_user>/.cli-proxy-api"
api-keys: []             # populated when require-api-key is on
passthrough-headers: true
nonstream-keepalive-interval: 30
routing:
  strategy: "round-robin"
  session-affinity: true
  session-affinity-ttl: "12h"
streaming:
  keepalive-seconds: 30
  bootstrap-retries: 3
oauth-model-alias:
  codex:
    - name: "gpt-5.4"
      alias: "claude-opus-4-5-20251101"
    - name: "gpt-5.4"
      alias: "claude-sonnet-4-6"
    - name: "gpt-5.4-mini"
      alias: "claude-haiku-4-5-20251001"
    - name: "gpt-5.4-mini"
      alias: "claude-3-5-haiku-20241022"
    - name: "gpt-5.3-codex"
      alias: "claude-sonnet-4-5"
  antigravity:
    - name: "claude-sonnet-4-6"
      alias: "claude-opus-4-5-20251101"
    - name: "claude-sonnet-4-6"
      alias: "claude-opus-4-7"
    - name: "claude-sonnet-4-6"
      alias: "claude-sonnet-4-6"
    - name: "claude-sonnet-4-6"
      alias: "claude-haiku-4-5-20251001"
payload:
  filter:
    - models:
        - name: "*"
          protocol: "antigravity"
      params:
        - "tools.#.input_schema.propertyNames"
        - "tools.#.input_schema.additionalProperties"
        - "tools.#.input_schema.patternProperties"
logging-to-file: false
```

Key production settings:

- `passthrough-headers: true` - required for Claude Code CLI to work correctly (forwards full SDK request headers)
- `session-affinity: true / 12h` - prevents "dot token" errors by keeping conversations on the same OAuth account
- `streaming.keepalive-seconds: 30` - prevents proxy timeout on long streaming responses
- `oauth-model-alias` - provider-scoped alias lists that translate Claude model names to real provider model names for Codex (gpt-5.4 family) and Antigravity/Gemini (`claude-sonnet-4-6`)
- `payload.filter` - rule list that strips JSON Schema fields rejected by Gemini API for Antigravity traffic (`propertyNames`, `additionalProperties`, `patternProperties`) to avoid 400 errors

Required posture:

- bind only `127.0.0.1`
- do not terminate TLS inside the app
- keep remote management disabled by default
- keep pprof disabled by default
- store provider auth state under `~/.cli-proxy-api`

#### 2.4 systemd unit

OPS manages CLIProxyAPI via systemd only.

```ini
[Unit]
Description=CLIProxyAPI
After=network.target

[Service]
Type=simple
User=<runtime_user>
Group=<runtime_user>
WorkingDirectory=/opt/cli-proxy-api
Environment=HOME=<runtime_home>
ExecStart=/opt/cli-proxy-api/cli-proxy-api
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

Service name: `cli-proxy-api.service`

#### 2.5 Bootstrap auth providers

OPS does not copy provider credentials into `/etc/ops`.
Auth bootstrap is done as the runtime user:

```bash
sudo -u <runtime_user> env HOME=<runtime_home> /opt/cli-proxy-api/cli-proxy-api --claude-login
sudo -u <runtime_user> env HOME=<runtime_home> /opt/cli-proxy-api/cli-proxy-api --codex-login
sudo -u <runtime_user> env HOME=<runtime_home> /opt/cli-proxy-api/cli-proxy-api --login
```

These commands populate the auth directory at `~/.cli-proxy-api`.

#### 2.6 Nginx vhost

When the operator links CLIProxyAPI to a domain, OPS creates an Nginx vhost that proxies to `127.0.0.1:8317`.

Required vhost properties:

- `proxy_pass http://127.0.0.1:8317;`
- `proxy_buffering off;`
- TLS terminates at Nginx, not in CLIProxyAPI
- the public entrypoint is the Nginx vhost only

#### 2.7 Update flow

OPS update behaviour:

- fetch latest release metadata again
- stop `cli-proxy-api.service`
- replace the binary under `/opt/cli-proxy-api`
- preserve `config.yaml`
- preserve auth state in `~/.cli-proxy-api`
- restart the systemd service
- keep UFW posture unchanged: no public allow on `8317`

---

### 3. Runtime state

| Artefact | Path | Purpose |
|---|---|---|
| Binary | `/opt/cli-proxy-api/cli-proxy-api` | Service executable |
| Config | `/opt/cli-proxy-api/config.yaml` | Runtime config |
| Auth dir | `~/.cli-proxy-api/` | Provider auth state |
| OPS state | `/etc/ops/cli-proxy-api.conf` | OPS metadata |
| Local API key file | `/etc/ops/.cli-proxy-api-key` | Local client key when API key mode is enabled |
| systemd unit | `/etc/systemd/system/cli-proxy-api.service` | Service definition |
| Nginx vhost | `/etc/nginx/sites-available/cli-proxy-api.<domain>` | Public routing |

#### Network posture contract

- CLIProxyAPI listens on `127.0.0.1:8317` only.
- Nginx is the only public entrypoint for the CLIProxyAPI domain.
- UFW must not contain `ALLOW 8317`.
- TLS terminates at Nginx.

#### OPS state file format

```bash
# /etc/ops/cli-proxy-api.conf
CLIPROXYAPI_INSTALLED="yes"
CLIPROXYAPI_DIR="/opt/cli-proxy-api"
CLIPROXYAPI_PORT="8317"
CLIPROXYAPI_RUNTIME_USER=""
CLIPROXYAPI_DOMAIN=""
CLIPROXYAPI_SSL="no"
CLIPROXYAPI_REQUIRE_API_KEY="no"
CLIPROXYAPI_REQUEST_LOGS="no"
CLIPROXYAPI_INSTALL_DATE=""
```

---

### 4. API key and request logging toggles

OPS exposes two runtime toggles:

1. API key requirement
   - writes or clears the `api-keys:` list in `config.yaml`
   - stores the generated local client key at `/etc/ops/.cli-proxy-api-key`
   - restarts `cli-proxy-api.service`

2. Request logging
   - toggles `logging-to-file` in `config.yaml`
   - restarts `cli-proxy-api.service`

The local API key file must be `0600` and must never be printed to terminal.

---

### 5. Verify

```bash
# 1. Service active
systemctl is-active cli-proxy-api

# 2. Local endpoint responds
curl -s http://127.0.0.1:8317/v1/models

# 3. Port 8317 is not opened in UFW
ufw status | grep 8317

# 4. Public domain works through Nginx when linked
curl -I https://<domain>/v1/models
```

If API key mode is enabled, include the local key:

```bash
curl -s -H "Authorization: Bearer $(cat /etc/ops/.cli-proxy-api-key)" \
  http://127.0.0.1:8317/v1/models
```

---

### 6. Rollback

If CLIProxyAPI fails to start or an update goes wrong:

```bash
systemctl stop cli-proxy-api

# Remove or disable the Nginx vhost if linked
rm -f /etc/nginx/sites-enabled/cli-proxy-api.<domain>
nginx -t && systemctl reload nginx

# Restore previous binary/config backup, then restart
systemctl start cli-proxy-api
```

Minimum rollback expectations:

- restore previous binary or VPS snapshot
- keep `config.yaml` and auth directory intact if possible
- remove broken public vhost before reopening traffic

---

### 7. Security contract

- Port `8317` must never be opened publicly in UFW.
- `config.yaml` must keep `host: 127.0.0.1`.
- `remote-management.allow-remote` must remain `false` by default.
- `remote-management.secret-key` must be empty by default.
- `pprof.enable` must remain `false` by default.
- `/etc/ops/.cli-proxy-api-key` must be `0600` when present.
- Provider auth material stays under the runtime user home, not `/etc/ops`.
