## OPS Platform-Agnostic Capabilities

Muc tieu: tach logic loi OPS ra khoi implementation Node.js, PHP, Nginx, PM2, MySQL/MariaDB cu the.

OPS nen duoc xem la mot production control plane voi cac capability sau:

1. Host bootstrap
2. Operator access bootstrap
3. Global reverse proxy and routing
4. App provisioning
5. Runtime binding per app
6. Domain and TLS binding
7. Data services and data lifecycle
8. Security hardening
9. Performance tuning
10. Monitoring, audit, and rollback

## Capability contract

Moi capability trong OPS nen duoc dinh nghia boi:

- **Intent**: giai bai toan gi
- **Inputs**: user cung cap gi
- **State**: file/service/resource nao la source of truth
- **Apply flow**: tao/sua cai gi
- **Verify**: thanh cong duoc do bang gi
- **Rollback**: quay lai toi thieu nhu the nao

## Capability mapping cho OPS

### Host bootstrap

- **Intent**:
  - dua VPS moi vao trang thai san sang production
- **State**:
  - `/opt/ops`
  - `/etc/ops/*`
  - base packages
- **Verify**:
  - core installed, symlink dung, dashboard/login flow hoat dong

### Operator access bootstrap

- **Intent**:
  - tao non-root admin path, SSH transition an toan, login UX ro rang
- **State**:
  - `/etc/ssh/sshd_config`
  - sudo user
  - shell rc hooks
- **Verify**:
  - login bang user moi va port moi

### Global reverse proxy and routing

- **Intent**:
  - Nginx la public entrypoint duy nhat
- **State**:
  - `/etc/nginx/*`
- **Verify**:
  - `nginx -t`
  - unknown host bi reject

### App provisioning

- **Intent**:
  - tao app instance moi
- **Node-first implementation**:
  - tao Node app/service, reverse proxy, env, process manager
- **PHP-secondary implementation**:
  - tao PHP site, docroot, fastcgi pool wiring, domain

### Runtime binding per app

- **Intent**:
  - moi app duoc gan vao runtime dung
- **Node-first**:
  - Node version + PM2
- **PHP-secondary**:
  - PHP version + PHP-FPM pool

### Domain and TLS binding

- **Intent**:
  - attach domain va SSL vao app/backend dung

### Data services and data lifecycle

- **Intent**:
  - install/secure/tune DB
  - create DB/user
  - backup/restore guidance

### Security hardening

- **Intent**:
  - harden host + proxy + app path

### Performance tuning

- **Intent**:
  - tuning theo RAM/CPU cho Nginx, Node, PHP-FPM, DB

### Monitoring, audit, and rollback

- **Intent**:
  - moi thay doi co verify va rollback
  - co ops log va service status overview

## Rule

Neu 1 module khong map ro vao 1 capability, thiet ke dang bi mo ho hoac tro nen application-specific qua muc.
