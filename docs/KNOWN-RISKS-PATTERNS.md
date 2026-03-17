## OPS Known Risks Patterns

Muc tieu: liet ke cac pattern de AI Agent san loi tiem an va review thay doi an toan hon.

## 1) Installer va runtime drift

- **Pattern**:
  - installer setup mot kieu, runtime bi sua tay sau do
- **Rui ro**:
  - doc docs dung nhung production van sai
- **Safe action**:
  - debug bang runtime truth, khong chi docs

## 2) SSH transition lockout

- **Pattern**:
  - doi port SSH va dong port 22 qua som
- **Rui ro**:
  - mat truy cap VPS
- **Safe action**:
  - mo ca 2 port trong transition, verify login moi truoc khi dong 22

## 3) Nginx la public entrypoint duy nhat

- **Pattern**:
  - Node app hoac 9router bi expose thang ra public
- **Rui ro**:
  - bo qua TLS, rate limit, host validation, default deny
- **Safe action**:
  - app chi bind localhost hoac unix socket

## 4) PM2 ownership drift cho Node services

- **Pattern**:
  - Node services duoc quan ly mot phan bang PM2, mot phan bang script tay hoac wrappers khong ro contract
- **Rui ro**:
  - restart loop, status sai, startup state kho truy vet
- **Safe action**:
  - PM2 la process manager duy nhat cho Node services
  - docs phai ghi app nao duoc PM2 quan ly

## 5) Node runtime va app runtime mismatch

- **Pattern**:
  - CLI Node version khac version ma app service dang chay
- **Rui ro**:
  - test bang shell thay on, nhung service van loi
- **Safe action**:
  - verify ca runtime cua process manager va shell

## 6) PHP CLI va PHP-FPM mismatch

- **Pattern**:
  - PHP CLI version khac PHP-FPM version cua site
- **Rui ro**:
  - debug sai huong
- **Safe action**:
  - verify ca CLI, pool, fastcgi mapping

## 7) Config rewrite lam vo syntax

- **Pattern**:
  - `sed`/append vao Nginx, PHP-FPM, sshd, systemd config
- **Rui ro**:
  - duplicate block, line sai vi tri, service fail to reload
- **Safe action**:
  - backup truoc
  - syntax test sau
  - diff va rollback ro rang

## 8) DB secure setup/tuning gay outage

- **Pattern**:
  - secure setup hoac tuning doi qua nhieu trong 1 lan
- **Rui ro**:
  - app mat ket noi DB
- **Safe action**:
  - doi tung nhom setting
  - verify app ket noi sau moi thay doi quan trong

## 9) Secrets leak qua logs/docs

- **Pattern**:
  - in password/token ra terminal hoac log
- **Rui ro**:
  - lo secret production
- **Safe action**:
  - chi ghi vi tri secret
  - file secret permission chat

## 10) Login hooks gay hong shell path

- **Pattern**:
  - dashboard/login hook chen vao shell rc mot cach khong guard interactive shell
- **Rui ro**:
  - scp/non-interactive shell bi hong
- **Safe action**:
  - guard interactive shell ro rang
  - co rollback hook nhanh

## 11) Node-first nhung PHP phu bi bo quen

- **Pattern**:
  - toi uu he thong cho Node app nhung khong giu contract cho PHP sites phu
- **Rui ro**:
  - PHP sites bi nghet pool, wrong fastcgi, wrong file perms
- **Safe action**:
  - tach global defaults va per-backend overrides

## 12) Clone logic theo syntax thay vi theo capability

- **Pattern**:
  - copy setup tu project khac theo lenh/syntax cu the
- **Rui ro**:
  - mang theo phu thuoc stack cu, script kho maintain
- **Safe action**:
  - clone capability, source of truth, verify/rollback discipline
