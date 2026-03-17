## OPS Design Patterns Extracted

Muc tieu: chot cac pattern control-plane ma script production cua OPS nen tuan theo.

## 1. Small installer, heavy core

- Installer phai ngan, audit duoc.
- Business logic phai nam o `core/` va `modules/`.

## 2. Menu dispatcher -> module -> action

- `bin/ops` chi dieu huong.
- Moi module so huu action cua minh.
- Menu labels la contract public.

## 3. Impact-layer-first

- Moi task phai ghi ro tac dong o layer nao:
  - SSH/security
  - Nginx/proxy
  - Node runtime
  - PHP runtime
  - DB
  - logs/monitoring
  - scheduler/systemd

## 4. Central source-of-truth files

- Khong chi rely vao system inspection.
- Can co config manifests trong `/etc/ops/*` de:
  - provision lai
  - verify
  - rollback
  - debug nhanh

## 5. Backup + syntax test + reload

- Truoc khi sua config quan trong:
  - backup
  - write temp/safe
  - syntax test
  - reload/restart co kiem soat

## 6. Runtime truth beats docs

- Docs la spec.
- Runtime la su that khi debug production.

## 7. Node-first, PHP-secondary

- Node la backend uu tien trong decisions ve menu, process model, dashboard.
- PHP van la citizen hop le, nhung khong duoc ep logic Node len no.

## 8. Public path va private path tach ro

- Public:
  - Nginx 80/443
- Private:
  - Node app localhost
  - 9router localhost
  - PHP-FPM socket/localhost
  - DB local by default

## 9. Verify va rollback la dau ra bat buoc

- Moi action module nen co:
  - state changes
  - verify steps
  - rollback minimum

## 10. Docs as operational memory

- Docs khong chi mo ta tinh nang.
- Docs phai giup AI Agent:
  - triage bug
  - trace runtime
  - nhan dien pattern nguy hiem
  - clone logic sang stack khac
