## OPS Runtime Artefact Inventory

Muc tieu: liet ke cac runtime artefacts ma OPS tao/quan ly de debug, verify, va rollback nhanh.

Luu y: day la target inventory cho script production; mot so artefact se xuat hien day du hon khi implementation hoan chinh.

## 1. Core and global state

| Artefact | Muc dich |
|---|---|
| `/opt/ops` | core install path |
| `/usr/local/bin/ops` | main entrypoint symlink |
| `/usr/local/bin/ops-dashboard` | dashboard symlink |
| `/etc/ops/ops.conf` | global config |
| `/etc/ops/capacity.conf` or JSON | VPS capacity profile |
| `/var/log/ops/ops.log` | high-level operations log |

## 2. Login and operator access

| Artefact | Muc dich |
|---|---|
| shell rc hook for admin user | auto run dashboard on interactive login |
| `/etc/ssh/sshd_config` | SSH port and admin access policy |
| sudo user config | non-root daily admin path |

## 3. Node and 9router

Node services va 9router deu theo PM2 contract:

| Artefact | Muc dich |
|---|---|
| app dir | Node source/build/runtime files |
| `.env` files | app secrets and runtime env |
| PM2 process list | process supervision |
| PM2 ecosystem config | declarative process config neu dung |
| `/etc/ops/apps/<app>.conf` | app source of truth neu OPS tao |

## 4. Nginx and domains

| Artefact | Muc dich |
|---|---|
| `/etc/nginx/nginx.conf` | global Nginx config |
| `/etc/nginx/sites-available/*` | per-domain configs |
| `/etc/nginx/sites-enabled/*` | enabled site links |
| default deny server | reject unknown hosts |
| `/etc/ops/domains/<domain>.conf` | domain mapping source of truth neu OPS tao |

## 5. SSL

| Artefact | Muc dich |
|---|---|
| certbot config and renewal state | ACME lifecycle |
| live cert paths | active cert/key material |
| Nginx SSL snippets | TLS wiring |

## 6. PHP

| Artefact | Muc dich |
|---|---|
| `/etc/php/<ver>/fpm/php.ini` | PHP runtime config |
| `/etc/php/<ver>/fpm/pool.d/*.conf` | per-pool config |
| PHP CLI alternatives | default CLI version |
| `/etc/ops/php-sites/<site>.conf` | PHP site metadata neu OPS tao |

## 7. Database

| Artefact | Muc dich |
|---|---|
| MySQL/MariaDB service config | DB server tuning |
| DB users and databases | app data access |
| `/etc/ops/database.conf` | optional global DB config for OPS |

## 8. Security

| Artefact | Muc dich |
|---|---|
| UFW rules | inbound access policy |
| `/etc/fail2ban/*` | ban policy |
| default closed ports except approved ones | host exposure contract |

## 9. Verification expectations

Moi artefact quan trong phai co:

- source script/module tao ra no
- verify command
- rollback toi thieu

Neu implementation tao artefact moi ma file nay khong cap nhat, docs dang khong theo kip runtime.
