## OPS Porting Map -- Node.js First, PHP Secondary

Muc tieu: dung logic OPS de xay control plane production cho VPS uu tien Node.js apps, nhung van phuc vu PHP websites phu.

## Mapping logic

| Logic loi | Node-first path | PHP-secondary path |
|---|---|---|
| App instance | Node service/app | PHP site/docroot |
| Runtime binding | Node version + PM2 | PHP version + PHP-FPM pool |
| Public entrypoint | Nginx reverse proxy | Nginx fastcgi/vhost |
| App config | `.env`, ecosystem, service env | `php.ini`, pool config, app env |
| Health verification | localhost health endpoint, service status | PHP response, FPM status, Nginx fastcgi test |
| Performance tuning | Node memory/process model | PHP-FPM pool sizing + opcache |
| Data layer | app DB or external service | MySQL/MariaDB |

## Porting rule tu wptangtoc-ols sang OPS

### Copy duoc

- impact-layer-first thinking
- central state/source-of-truth thinking
- verify/rollback contract
- inventory tu runtime artefacts
- backup-first voi destructive ops
- runtime truth > template truth

### Khong copy may moc

- OLS/vhost syntax
- `.htaccess`
- wp-cli flows
- PHP-centric assumptions cho moi app

## Node-first production control plane nen co

1. App bootstrap
   - create app dir
   - create env file
   - install deps/build
   - register PM2
   - bind localhost port
2. Reverse proxy bind
   - create Nginx site
   - upstream localhost target
   - HTTP -> HTTPS redirect when ready
3. TLS bind
   - issue cert
   - wire cert vao site config
4. Verify
   - app process ok
   - Nginx ok
   - domain ok
5. Rollback
   - disable site
   - stop new process
   - restore previous config

## PHP-secondary contract

PHP support trong OPS khong nen chiem trung tam, nhung van phai co:

- install/remove versions
- pool config per site khi can
- Nginx fastcgi wiring
- verify CLI va FPM tach biet
- backup config truoc khi doi php.ini/pool

## De xay script production hoan chinh, OPS nen tao source of truth nao

- global:
  - `/etc/ops/ops.conf`
  - `/etc/ops/capacity.conf` hoac JSON
- node apps:
  - `/etc/ops/apps/<app>.conf`
- domains:
  - `/etc/ops/domains/<domain>.conf`
- php sites:
  - `/etc/ops/php-sites/<site>.conf`
- codex/ai:
  - `/etc/ops/codex-cli.conf`

Neu khong co source-of-truth files nay, control plane se kho idempotent va kho rollback.
