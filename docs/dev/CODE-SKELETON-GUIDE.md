## OPS Code Skeleton Guide

Muc tieu: cung cap pattern guide sat voi implementation hien tai de AI Agent va human contributors sua scripts dung huong.
Day khong con la guide "scaffold from scratch" cho repo trong trang thai rong. Hay coi no la **authoring guide** cho repo OPS hien tai.

---

## A. Coding spine

### 1) Executable scripts (`ops/bin/`, `install/`)

Dung pattern nay cho entrypoints thuc thi that.

```bash
#!/usr/bin/env bash
# ============================================================
# ops/<path/to/file>.sh
# Purpose: <one-line description>
# Part of:  OPS — VPS Production Setup & Manager
# ============================================================
set -euo pipefail
IFS=$'\n\t'

OPS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source core helpers in this order
# shellcheck source=core/env.sh
source "$OPS_ROOT/core/env.sh"
# shellcheck source=core/utils.sh
source "$OPS_ROOT/core/utils.sh"
# shellcheck source=core/ui.sh
source "$OPS_ROOT/core/ui.sh"
# shellcheck source=core/system.sh
source "$OPS_ROOT/core/system.sh"
```

### 2) Source-only module files (`ops/modules/*.sh`)

```bash
#!/usr/bin/env bash
# ops/modules/<name>.sh
# Called by ops/bin/ops via menu dispatch.
# Do NOT add set -euo pipefail here — inherited from ops/bin/ops.
```

### 3) Display-only exception: `ops-dashboard`

`ops/bin/ops-dashboard` la exception co chu y:

- khong dung `set -e`
- hien tai dung `set -uo pipefail`
- ly do: dashboard chi render thong tin; 1 lenh loi khong duoc lam vo nửa man hinh dang hien

Neu co script display-only tuong tu, phai ghi ro exception nay trong header thay vi ngam dinh moi executable deu `set -euo pipefail`.

---

## B. Repo layout va runtime layout

### 1) Layout trong repo

Repo source tree hien tai:

- `install/ops-install.sh` — public bootstrap installer (`curl && bash`)
- `ops/bin/` — runtime entrypoints
  - `ops`
  - `ops-dashboard`
  - `ops-setup.sh`
  - `ops-ssh-finalize.sh`
- `ops/core/`
  - `env.sh`
  - `utils.sh`
  - `ui.sh`
  - `system.sh`
- `ops/modules/`
  - `setup-wizard.sh`
  - `security.sh`
  - `nginx.sh`
  - `node.sh`
  - `cli-proxy-api.sh`
  - `php.sh`
  - `database.sh`
  - `monitoring.sh`
  - `verify.sh`
  - `checks.sh`
  - `backup.sh`
  - `codex-cli.sh`
  - `ai-agent.sh`
  - `templates/`

### 2) Runtime tren VPS

Trong production, OPS duoc install tai:

- core install path: `/opt/ops`
- state/config path: `/etc/ops/`
- ops symlink path: `/usr/local/bin/ops`
- log path: `/var/log/ops/ops.log`

**Rule:**
- Khi noi ve repo source tree, dung paths nhu `ops/bin/ops`, `ops/modules/nginx.sh`
- Khi noi ve runtime tren VPS, dung paths nhu `/opt/ops/bin/ops`, `/etc/ops/ops.conf`

---

## C. Core helper map

### `ops/core/env.sh`

Phu trach:

- detect OS / version
- detect RAM / CPU / disk / tier
- expose runtime paths
- detect `ADMIN_USER` khi co the
- `ops_conf_set` / `ops_conf_get` cho shell-sourceable OPS state files

**Pattern:**
- dung `ops_conf_set` cho OPS-owned state duoi `/etc/ops/*.conf`
- implementation hien tai da sanitize values va ghi qua temp-file swap; khong doc guide cu ma viet `sed -i` don gian cho state files

### `ops/core/utils.sh`

Phu trach:

- `log_info`, `log_warn`, `log_error`
- `ensure_dir`, `ensure_parent_dir`
- `backup_file`
- `write_file`
- `safe_symlink`
- `render_template`
- `require_root`
- idempotence helpers nhu `is_installed`, `service_active`, `file_contains`

**Pattern:**
- dung `write_file` cho generated files khi co the
- dung `backup_file` truoc khi ghi de rollback de hon
- `safe_symlink` cho managed symlinks

### `ops/core/ui.sh`

Phu trach:

- `print_section`, `print_ok`, `print_warn`, `print_error`
- `prompt_input`, `prompt_confirm`, `prompt_secret`
- `press_enter`
- `show_menu`

**Pattern quan trong:**
- interactive prompts hien tai ghi/doc qua `/dev/tty`
- tranh phu thuoc vao stdin khi script dang chay trong nested shells, hooks, hoac command wrappers

### `ops/core/system.sh`

Phu trach:

- `apt_update`, `apt_install`, `apt_remove`
- `service_enable`, `service_start`, `service_restart`, `service_reload`, `service_stop`, `service_status`, `service_active`
- aliases `svc_*` chi de compatibility, khong phai API uu tien
- runtime-user helpers cho PM2/user-owned processes
- `bash_validate`, `nginx_validate`, `nginx_reload`

**Pattern quan trong:**
- uu tien `service_*` thay vi `svc_*` trong code moi
- `service_restart` hien tai co health check/backoff; khong rut gon thanh `systemctl restart` don thuan trong docs moi

---

## D. `ops/bin/ops` — current menu/runtime contract

`ops/bin/ops` khong chi la dispatcher don gian nua. Hien tai no:

- source core theo thu tu `env -> utils -> ui -> system`
- source modules:
  - `setup-wizard.sh`
  - `security.sh`
  - `nginx.sh`
  - `node.sh`
  - `cli-proxy-api.sh`
  - `php.sh`
  - `database.sh`
  - `monitoring.sh`
  - `verify.sh`
  - `checks.sh`
  - `backup.sh`
  - `codex-cli.sh`
  - `ai-agent.sh`
- render main menu va banner thong tin he thong
- read input tu `/dev/tty`
- co timeout 300s de tranh spin neu SSH/TTY bien mat
- co session lock de tranh 2 `ops` sessions cung sua shared state
- reject non-interactive contexts truoc khi vao menu loop

**Do not document `ops/bin/ops` as only:**
- `while true; read -p ...`
- source mot tap module nho hon hien tai
- goi Codex truc tiep tu main menu ma bo qua `menu_ai_agent`

Representative pattern:

```bash
main_menu() {
    while true; do
        clear
        print_section "OPS — VPS Production Manager"
        echo "  8) AI Agent Integration"
        echo "  9) System & Monitoring"
        echo "  s) Security Management"
        printf "Select: " > /dev/tty
        if ! read -r -t 300 choice < /dev/tty; then
            echo "" >&2
            exit 0
        fi
        case "$choice" in
            8) menu_ai_agent   ;;
            9) menu_monitoring ;;
            s|S) menu_security ;;
            0) exit 0          ;;
            *) print_warn "Invalid option" ;;
        esac
    done
}
```

---

## E. Module/menu pattern

### 1) Menu boundary contract

Pattern hien tai:

```bash
menu_<name>() {
    _<name>_menu_run() {
        "$@"
        return 0
    }

    while true; do
        print_section "<Module> Management"
        echo "  1) ..."
        echo "  0) Back"
        printf "  Select: " > /dev/tty
        local choice
        read -r choice < /dev/tty
        case "$choice" in
            1) _<name>_menu_run <name>_action ; press_enter ;;
            0) return 0 ;;
            *) print_warn "Invalid option" ;;
        esac
    done
}
```

**Rules:**
- `menu_*` boundary phai `return 0` khi thoat binh thuong
- action-level non-zero duoc hap thu boi wrapper `_menu_run`
- parent menus va `ops/bin/ops` goi `menu_*` truc tiep, khong dung `menu_x || true` nhu workaround
- verify/status actions cung theo contract nay: PASS/WARN/FAIL duoc render ra man hinh, nhung menu boundary van return `0`

### 2) Prompt pattern

- uu tien `prompt_input`, `prompt_confirm`, `prompt_secret`
- neu can read custom, uu tien `/dev/tty`
- chi goi `press_enter` sau cac action co output can operator xem; khong bat buoc cho moi action ngan gon

### 3) Action pattern

Action functions nen theo flow:

1. gather inputs
2. backup affected files/state
3. apply change
4. validate (`nginx -t`, `bash -n`, service checks, v.v.)
5. reload/restart with helper phu hop
6. verify observable result
7. log

---

## F. State, config, va secrets patterns

### 1) OPS-owned state

Dung `ops_conf_set` / `ops_conf_get` cho shell-sourceable state duoi `/etc/ops/*.conf`, vi du:

- `/etc/ops/ops.conf`
- `/etc/ops/capacity.conf`
- `/etc/ops/cli-proxy-api.conf`
- `/etc/ops/codex-cli.conf`
- `/etc/ops/claude-code.conf`
- `/etc/ops/notifications.conf`
- `/etc/ops/database.conf`
- `/etc/ops/apps/<app>.conf`
- `/etc/ops/domains/<domain>.conf`
- `/etc/ops/php-sites/<site>.conf`

### 2) Service-native configs

Khong phai moi file can di qua `ops_conf_set`.
Voi service-native configs (Nginx, PHP ini/pools, sshd include files, systemd units, v.v.), dung pattern phu hop hon:

- `backup_file` truoc khi sua
- `write_file` / temp-file swap / focused edit tuy case
- validate truoc reload/restart

### 3) Secrets

- khong inline secrets trong `.conf` shell-sourceable khi co the
- uu tien file-based secrets voi permission hep
- current implementation dung nhieu vi tri secrets khac nhau tuy module, vi du:
  - `/etc/ops/.cli-proxy-api-key`
  - `/etc/ops/.db-root-password`
  - `/etc/ops/.codex-api-key`
  - `/etc/ops/.telegram-bot-token`
  - admin `~/.bashrc` export block cho Claude Code

---

## G. Convention cheat sheet

| Rule | Detail |
|---|---|
| Source order | `env.sh` -> `utils.sh` -> `ui.sh` -> `system.sh` |
| Repo vs runtime path | Repo docs: `ops/...`; production docs: `/opt/ops/...` |
| Menu input | Uu tien `/dev/tty` / UI helpers thay vi `read -p` don thuan |
| Service API | Uu tien `service_*`; `svc_*` chi la compatibility aliases |
| OPS state files | Dung `ops_conf_set` / `ops_conf_get` cho `/etc/ops/*.conf` shell-sourceable |
| Generated files | Uu tien `backup_file` + `write_file` / temp-file swap |
| Nginx reload | `nginx_validate` truoc `nginx_reload` |
| Root guard | Dung `require_root` o dau action can root |
| Logging | `log_info`, `log_warn`, `log_error` |
| Verify contract | PASS/WARN/FAIL duoc render, nhung menu boundary van return `0` |
| AI menu | Main menu item `8` la `AI Agent Integration`; Codex/Claude nam duoi submenu nay |

---

## H. Practical review checklist

Khi review code moi, check nhanh:

1. dang sua repo path hay runtime path? co dung namespace chua?
2. code moi co reuse helper hien tai thay vi invent helper moi khong?
3. menu/action co theo wrapper return-0 pattern khong?
4. state moi nam trong runtime contract ro rang chua?
5. service-native config co backup + validate + reload/restart co kiem soat khong?
6. docs co dang mo ta implementation that, hay dang vo tinh ke lai skeleton cu?
