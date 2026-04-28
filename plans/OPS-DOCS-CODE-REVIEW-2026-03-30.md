# OPS Docs/Code Review - 2026-03-30

- Ngày review: `2026-03-30`
- Phạm vi: so sánh `docs/` với mã nguồn OPS trong `ops/`
- Mục tiêu: tổng hợp các lệch chuẩn, lỗi ẩn, và rủi ro maintainability đã được xác nhận trong phiên review này
- Ghi chú: một số mục bên dưới là **mâu thuẫn tài liệu / lệch spec**, không nhất thiết là runtime bug đang bộc lộ ngay

---

## Executive summary

- Có ít nhất 3 nhóm vấn đề đáng ưu tiên: contract verify/menu chưa khớp spec, xử lý PM2 chưa nhất quán theo runtime user, và Nginx rate limiting chưa khớp tài liệu 9router.
- Mức ảnh hưởng cao nhất nằm ở `verify.sh`: tài liệu yêu cầu verify không được làm menu thoát, nhưng code vẫn `return 1/2`, có nguy cơ tái phát bug thoát menu khi caller không bọc `|| true` đúng chỗ.
- Vấn đề PM2 xuất hiện ở nhiều module, cho thấy drift kiến trúc: một số nơi đã dùng wrapper runtime user đúng cách, nhưng nhiều nơi vẫn gọi `pm2 jlist` trực tiếp.
- Có ít nhất một lệch rõ giữa docs và code ở phần Nginx: docs 9router nói bỏ `limit_req`, nhưng code vẫn khai báo zone và enforce `limit_req` trong vhost.
- Trong phạm vi bằng chứng đã kiểm tra ở phiên này, chưa chốt thêm mâu thuẫn nội bộ docs nào đủ mạnh ngoài các lệch docs-vs-code ở trên.

## Ưu tiên xử lý

- `P0`: Đồng bộ lại verify exit contract để action verify không propagate non-zero ra menu loop.
- `P0`: Chuẩn hóa toàn bộ PM2 status/list sang runtime-user wrapper, tránh false negative khi chạy dưới `root`.
- `P1`: Rà soát và bỏ phần `limit_req` ở các luồng/vhost không còn được phép theo spec 9router.
- `P1`: Giảm lặp logic PM2 giữa `checks.sh`, `monitoring.sh`, `setup-wizard.sh` để tránh drift tiếp diễn.
- `P2`: Sau khi sửa code, cập nhật lại docs liên quan nếu implementation thực tế được giữ khác spec vì lý do vận hành.

## Findings chi tiết

### Lỗi ẩn trong code

| ID | Mức độ | Vấn đề | Bằng chứng | Ảnh hưởng | Review |
|---|---|---|---|---|---|
| `BUG-01` | `P0` | `verify.sh` vẫn trả về non-zero cho `WARN`/`FAIL`, trái với contract tránh thoát menu | `docs/PHASE-02-IMPLEMENTATION-SPEC.md:294`, `docs/PHASE-02-IMPLEMENTATION-SPEC.md:300`, `ops/modules/verify.sh:95`, `ops/modules/verify.sh:99`, `ops/modules/verify.sh:119`, `ops/modules/verify.sh:124`, `ops/modules/verify.sh:134` | Dễ tái phát lỗi menu/submenu bị thoát khi caller dùng `set -e` hoặc quên `|| true` | [x] |
| `BUG-02` | `P0` | Nhiều màn hình/status check PM2 vẫn gọi `pm2 jlist` trực tiếp thay vì qua runtime user | `docs/SECURITY-RULES.md:163`, `docs/KNOWN-RISKS-PATTERNS.md:201`, `ops/modules/setup-wizard.sh:644`, `ops/modules/monitoring.sh:245`, `ops/modules/checks.sh:476`, `ops/modules/checks.sh:717` | Có thể báo sai là không có app PM2 hoặc đếm sai process khi daemon thật chạy dưới user khác | [ ] |

### Lệch giữa docs và code

| ID | Mức độ | Vấn đề | Bằng chứng | Ảnh hưởng | Review |
|---|---|---|---|---|---|
| `DOC-CODE-01` | `P1` | Docs 9router nói đã bỏ Nginx `limit_req`, nhưng code vẫn khai báo zone và enforce tại vhost | `docs/NINE-ROUTER-SPEC.md:226`, `docs/PROMPTS-TEMPLATES.md:288`, `ops/modules/nginx.sh:115`, `ops/modules/nginx.sh:383`, `ops/modules/nginx.sh:517` | Tài liệu review/deploy không phản ánh đúng implementation; có nguy cơ tái sinh lỗi `429` giả hoặc hiểu sai behavior thực tế | [ ] |
| `DOC-CODE-02` | `P1` | Docs yêu cầu mọi PM2 status/list trong OPS phải chạy qua runtime user, nhưng một số code path vẫn gọi bare PM2 | `docs/SECURITY-RULES.md:163`, `docs/MENU-REFERENCE.md:89`, `ops/modules/setup-wizard.sh:644`, `ops/modules/monitoring.sh:245`, `ops/modules/checks.sh:476`, `ops/modules/checks.sh:717` | Reviewer/operator tin docs nhưng gặp output sai trên thực tế, làm chẩn đoán Node service lệch hướng | [ ] |

### Mâu thuẫn ngay trong docs

Chưa có mục nào được xác nhận đủ bằng chứng trong phiên này để kết luận là mâu thuẫn nội bộ giữa các file trong `docs/`.

| ID | Mức độ | Vấn đề | Bằng chứng | Ảnh hưởng | Review |
|---|---|---|---|---|---|
| `DOC-INT-00` | `P2` | Chưa ghi nhận finding đủ chứng cứ; cần review riêng nếu muốn chốt mâu thuẫn docs-vs-docs | Phạm vi phiên này mới xác nhận chắc chắn các lệch `docs` ↔ `code` và lỗi ẩn trong `ops/` | Tránh kết luận quá tay khi chưa có chứng cứ đối chiếu đầy đủ giữa nhiều tài liệu | [ ] |

### Rủi ro kiến trúc / maintainability

| ID | Mức độ | Vấn đề | Bằng chứng | Ảnh hưởng | Review |
|---|---|---|---|---|---|
| `ARCH-01` | `P1` | Logic PM2 status bị copy ra nhiều module với contract không đồng nhất | `ops/modules/setup-wizard.sh:644`, `ops/modules/monitoring.sh:245`, `ops/modules/checks.sh:476`, `ops/modules/checks.sh:717`, đối chiếu với wrapper đúng ở `ops/modules/node.sh:339`, `ops/modules/verify.sh:272` | Sửa một nơi không đủ; bug drift dễ quay lại ở menu khác và làm hành vi quan sát hệ thống không nhất quán | [ ] |
| `ARCH-02` | `P2` | Spec verify có contract rõ, nhưng enforcement đang phụ thuộc caller nhớ bọc `|| true` thay vì có abstraction an toàn mặc định | `docs/PHASE-02-IMPLEMENTATION-SPEC.md:294`, `docs/PHASE-02-IMPLEMENTATION-SPEC.md:298`, `ops/modules/verify.sh:95`, `ops/modules/verify.sh:119`, `ops/modules/verify.sh:134` | Maintainability thấp: chỉ cần một caller mới quên wrap là bug menu-exit quay lại | [ ] |

## Checklist xác nhận sửa

### Verify / menu flow

- [ ] Chuẩn hóa `verify.sh` để `WARN` và `FAIL` không làm action verify propagate non-zero ra menu loop
- [ ] Kiểm tra tất cả caller của verify/submenu đã không còn phụ thuộc vào `|| true` như biện pháp vá tạm
- [ ] Chạy lại luồng verify khi có `PASS`, `WARN`, `FAIL` để xác nhận menu không bị thoát ngoài ý muốn

### PM2 / Node runtime

- [ ] Thay mọi lệnh PM2 status/list trong OPS sang wrapper runtime user
- [ ] Kiểm tra `setup-wizard`, `monitoring`, `checks`, `verify`, `node`, `nine-router` cho contract PM2 nhất quán
- [ ] Xác nhận khi chạy dưới `root`, màn hình OPS vẫn nhìn thấy đúng app PM2 của runtime user

### Nginx / 9router

- [ ] Xác nhận policy chính thức cho `limit_req`: bỏ hẳn hay chỉ bỏ cho domain/flow 9router
- [ ] Nếu bỏ theo spec, xóa zone/enforcement liên quan trong vhost tương ứng và retest `nginx -t`
- [ ] Verify lại không còn false-positive `429` ở luồng 9router được mô tả trong docs

### Docs đồng bộ sau sửa

- [ ] Cập nhật `docs/` nếu implementation cuối cùng khác spec hiện tại
- [ ] Giữ một nguồn sự thật rõ cho PM2 runtime-user contract và verify exit contract
- [ ] Ghi chú rõ mục nào là “mâu thuẫn tài liệu” và mục nào là “runtime bug” để reviewer sau không gom chung mức độ
