# elm-obd2 — Tổng hợp cuối cùng nhóm 3, 4, 5

> Trạng thái: **code đã viết và rà lại, chưa được biên dịch hay chạy** (môi trường của mình không có Flutter SDK). Cần chạy `flutter analyze` và `flutter test` trước khi coi là xong.
> Gói đi kèm: `groups_3_4_5_final.zip` (bản hợp nhất, thay cho 3 zip lẻ trước đó).

---

## 1. Cách áp dụng

1. Commit trạng thái hiện tại của repo (hoặc gắn tag) để có mốc quay lại.
2. Giải nén `groups_3_4_5_final.zip` vào thư mục gốc repo, cho phép ghi đè. Zip này **thay thế** `group3`, `group4`, `group5`; không áp dụng chồng các zip cũ.
3. `flutter pub get` → `flutter analyze` → `flutter test` (xem mục 8 về các test chạy chậm).
4. Chạy tay với OBD Sim Pro theo checklist ở mục 8.

File bị ghi đè trong code hiện có: `elm327_connector.dart`, `obd_service.dart`, `simulated/simulated_elm327_connector.dart`. Ba file này được vá từ đúng phiên bản trong ZIP bạn gửi; nếu bạn đã sửa tay, hãy so sánh bằng git diff trước khi giữ.

---

## 2. Danh sách file

**Mới — `lib/core/obd/`**

| File | Nhóm | Vai trò |
|---|---|---|
| `transport/byte_transport.dart` | 3 | Interface truyền byte (`connect`, `incoming`, `write`, `isConnected`, `disconnect`) |
| `transport/spp_byte_transport.dart` | 3 | Bluetooth SPP, chuyển nguyên từ connector cũ |
| `elm_client.dart` | 3, 4 | Hàng đợi lệnh, khung `>`, timeout, init, trạng thái |
| `elm_init_profile.dart` | 4 | Chuỗi init dạng dữ liệu |
| `elm_timeouts.dart` | 4 | Timeout theo loại lệnh |
| `elm_response.dart` | 4 | Phân loại phản hồi ELM |
| `capability/elm_protocol.dart` | 5 | Giao thức từ `ATDPN` |
| `capability/supported_pids.dart` | 5 | Đọc mặt nạ PID, gộp nhiều ECU |
| `capability/vin_decoder.dart` | 5 | Giải mã VIN (CAN nhiều khung và kiểu mỗi dòng một thông điệp) |
| `capability/capability_profile.dart` | 5 | Mô hình hồ sơ năng lực xe + JSON |
| `capability/capability_probe.dart` | 5 | Dò PID (chuỗi), giao thức, VIN |
| `capability/capability_repository.dart` | 5 | Interface + bản bộ nhớ + bản Hive |
| `capability/capability_service.dart` | 5 | Dò hoặc dùng lại hồ sơ đã lưu theo VIN |

**Thay thế:** `elm327_connector.dart` (còn là lớp con mỏng của `ElmClient`), `obd_service.dart`, `simulated/simulated_elm327_connector.dart`.

**Test (79 test sau khi mở rộng):** `elm_client_test`, `elm_client_reliability_test`, `elm_support_test`, `capability/` (`capability_parsers_test`, `capability_probe_test`, `capability_repository_test`, `simulated_capability_test`) cùng hai file hỗ trợ `fake_byte_transport.dart`, `scripted_transport.dart`.

Không đổi: `ObdTransport`, `connect_provider.dart`, `connect_screen.dart`, mọi provider và UI.

---

## 3. Hành vi theo từng nhóm

### Nhóm 3 — tách transport (giữ nguyên hành vi)
- `Elm327Connector` → `ElmClient` + `SppByteTransport`. Thêm BLE chỉ cần một class cài `ByteTransport`.
- API cũ giữ nguyên: `connect(address)`, `getBondedDevices()`.

### Nhóm 4 — độ tin cậy ELM327
1. **Phản hồi trễ:** sau timeout, lệnh kế tiếp chưa được gửi cho đến khi `>` của phản hồi trễ về; byte trễ bị bỏ.
2. **Adapter treo:** không có `>` trong `drainTimeout` (mặc định 4 giây) → lệnh đang chờ báo lỗi, link đóng, trạng thái `error`.
3. **Init theo profile:** `ElmInitProfile.standard` giữ 6 lệnh cũ; bước bắt buộc không có `OK` → `ElmInitException` (nêu lệnh và phản hồi), đóng link.
4. **Timeout theo lệnh:** `ATZ` 5 giây; AT khác và PID thường 2,5 giây; lệnh OBD đầu tiên 10 giây (dò giao thức); DTC và mode 09 là 5 giây.
5. Ngắt kết nối làm các lệnh đang chờ báo lỗi (trước đây treo mãi).
6. `classifyElmReply` nhận diện: `OK`, `?`, `NO DATA`, `BUFFER FULL`, `BUS BUSY`, `CAN ERROR`, `BUS ERROR`/`FB ERROR`/`BUS INIT … ERROR`, `UNABLE TO CONNECT`, `STOPPED`, `DATA ERROR`, `LV RESET`, `ERROR` chung. So khớp bỏ khoảng trắng.

### Nhóm 5 — capability profile
- **Chuỗi PID:** `0100` → `0120` → … tối đa `01E0`, chỉ đi tiếp khi bit 0 báo còn dải.
- **Nhiều ECU:** mặt nạ các dòng được OR với nhau.
- **Thứ tự dò:** PID trước, rồi `ATDPN` (phải có lệnh OBD thành công thì mới dò được giao thức), rồi VIN (kiểm tra `0900`, chỉ hỏi `0902` khi xe báo hỗ trợ).
- **VIN:** cắt theo độ dài khai báo ở dòng đầu (`014` = 20 byte); chấp nhận nhãn khung bắt đầu từ 0 hoặc 1; kiểm tra ký tự hợp lệ (không I, O, Q); **không** kiểm tra chữ số kiểm tra (chỉ bắt buộc ở Bắc Mỹ).
- **Lưu và dùng lại:** theo VIN, hạn 30 ngày; xe **không có VIN** luôn được dò lại; lần dò không đọc được PID nào **không ghi đè** hồ sơ tốt đã lưu.
- **Simulator:** sửa bit 0 của mặt nạ cho đúng ECU thật; thêm `ATDPN` → `A6`, `0900`, `0902` (VIN giả `ZZZ00000000000001`).
- `ObdService`: `readSupportedPIDs()` giữ API cũ nhưng dùng chuỗi mới; thêm `probeCapabilities()`, `applyCapability()`, `capability`.

---

## 4. Kết quả đối chiếu với ba nguồn

| Nguồn | Đã làm | Kết quả |
|---|---|---|
| `elm-obd2` | Nền của cả 3 nhóm | Giữ API, công thức bit-mask, hàng đợi lệnh, simulator |
| `Flutter-OBD2` (MPL-2.0) | Đối chiếu thiết kế | Chỉ lấy hình dạng interface 4 thành viên của `AdapterOBD2`. Không có mode 09 nên **không có gì để đối chiếu VIN**. Bộ lập lịch EDF **chưa dùng** (thuộc nhóm 9) |
| `obd-droid` (MIT) | Đọc sau khi viết, chỉ để đối chiếu | Xem bên dưới |

**Đối chiếu với `obd-droid` đã đổi gì trong code:**
- Từ vựng thông báo ELM của họ rộng hơn bản của mình → thêm loại `error` chung, thêm `LV RESET` (mình biết từ tài liệu ELM327, họ không liệt kê), và so khớp thông báo **bỏ khoảng trắng**.
- Mẫu VIN trong code demo của họ có **nhãn khung từ 1** và **dư 1 byte** so với độ dài khai báo → thêm cắt theo độ dài khai báo, và thêm test mẫu này (kết quả đúng `4JGDA5HB7JB158144`).
- Mẫu mode 09 trả lời từ **3 ECU** (`49 00 55 40 10 00`) → thêm test; parser OR mặt nạ cho ra `02, 04, 06, 08, 0A, 14`.
- Họ dùng `ATAT`/`ATST` (định thời thích ứng) → không bật mặc định, nhưng đưa vào được như bước tùy chọn của init profile.

---

## 5. Cảnh báo giấy phép mới (cần quyết định)

Khi đọc `obd-droid`, mình thấy nhiều dấu hiệu phần lõi của nó **dẫn xuất từ AndrOBD**, trong khi file LICENSE của nó là MIT và NOTICE **không liệt kê AndrOBD**:

- `ElmProt.java:1073`, `:1084`, `:1086`: ghi chú "test case for issue AndrOBD/#61", "#60", "AndrOBD-Plugin/#10".
- `StreamHandler.java:57`: "[$Fix #AndrOBD-27]".
- `MainActivity.java:130`: "Main Activity for AndrOBD app"; `TAG = "AndrOBD"`.
- `UsbCommService.java:190`: "workaround for AndrOBD#285".
- Cấu trúc `ElmProt` (enum lệnh `RESET("Z")`, `ECHO("E")`…, `ObdProt`, `EcuDataItem`, `Conversion`) cũng trùng kiểu thiết kế của AndrOBD.

Theo hiểu biết của mình AndrOBD là GPL-3.0 (**chưa kiểm chứng trong phiên làm việc này**), và đây là nhận xét kỹ thuật, không phải kết luận pháp lý. Hệ quả thực tế:

- Nhóm 3, 4, 5 **không chứa code sao chép hay dịch từ `obd-droid`**. Mình viết từ đặc tả ELM327/OBD-II và đối chiếu sau; phần đọc `obd-droid` chỉ dùng để tìm ca bị bỏ sót.
- Với phần còn lại của kế hoạch, nên **hạ mức** các mục lấy từ phần lõi này: `ElmProt`, `ObdProt`, `ecu/*`, `pids.csv`, `conversions.csv`, `PidFormulaParser` → chỉ **THAM KHẢO ý tưởng**, không PORT LOGIC hay COPY DATA, cho đến khi làm rõ nguồn gốc với tác giả hoặc có tư vấn pháp lý.
- Các phần ở lớp `services/` (`ObdServiceCoordinator`, `RequestPriority`, `RemoteTelemetryManager`, `GpsTelemetryManager`, `EcuCacheManager`) mình **chưa thấy** dấu hiệu dẫn xuất tương tự, nhưng cũng chưa chứng minh được là code gốc.
- DTC: dùng trực tiếp repo MIT riêng `Wal33D/dtc-database` (được khai trong NOTICE như submodule) thay vì file `dtc_codes.db` trong app, và vẫn xác minh nguồn gốc dữ liệu của nó.

---

## 6. Giới hạn đã biết

- Bộ giải mã VIN và parser PID **giả định `ATH0`** (không có header). Profile chuẩn đặt `ATH0`; nếu bạn bật `ATH1` cho việc khác thì VIN nhiều khung sẽ bị cắt (và trả về null, không trả VIN sai).
- Hai ECU cùng trả VIN nhiều khung xen kẽ có thể trộn khung; kết quả sẽ không hợp lệ và trả về null. Hiếm gặp vì thường chỉ ECM trả VIN.
- Mặt nạ ECU ghép theo OR: xe có nhiều ECU báo PID khác nhau sẽ cho hồ sơ gộp, không phân biệt ECU nào hỗ trợ.
- Chỉ SPP, chỉ Android (`flutter_bluetooth_serial ^0.4.0`, ít được bảo trì); BLE cần thêm một `ByteTransport` mới và kiểm tra điều khoản `flutter_blue_plus`.
- Hồ sơ năng lực đang lưu bằng Hive (tạm), sẽ thay bằng bảng SQLite ở nhóm 7 sau interface `CapabilityRepository`.
- Điều gì xảy ra khi adapter tự reset do tụt áp (`LV RESET`): đã **nhận diện** được, nhưng chưa có hành động phục hồi (cần nhóm 6).
- `CapabilityService` chưa được nối vào `session_provider`; code cũ chạy như trước.

---

## 7. Quyết định thiết kế cần nhớ

1. Chọn **báo lỗi rõ** khi adapter treo thay vì đoán tiếp (chỉnh được bằng `drainTimeout`).
2. Xe không có VIN **luôn dò lại**, vì không biết dongle có vừa được cắm sang xe khác không.
3. Hồ sơ rỗng không bao giờ ghi đè hồ sơ tốt.
4. `mustSucceed: false` là lối thoát khi một dongle hoặc app giả lập không trả `OK` cho một lệnh init.
5. Hàng đợi ưu tiên (xóa lỗi > quét > polling nền) **chưa làm**; thuộc nhóm 9.

---

## 8. Kiểm tra

**Test tự động** (79 test): `flutter test test/core/obd`. Hai nhóm chạy chậm hơn: `elm_client_test` (mỗi lần kết nối chờ 0,6 giây sau `ATZ`) và `simulated_capability_test` (khoảng 2 giây).

**Checklist chạy tay với OBD Sim Pro**
1. Kết nối SPP: trạng thái đi qua connecting → initializing → connected.
2. Nếu `connect` lỗi `ElmInitException`: ghi lại lệnh và phản hồi trong thông báo, rồi chuyển bước đó sang `mustSucceed: false` trong profile.
3. Monitor: đọc RPM, speed, coolant bình thường.
4. Một bài Diagnostic Test chạy hết.
5. Tắt app giả lập giữa chừng: app phải báo mất kết nối, lệnh đang chờ báo lỗi, không treo.
6. Kết nối lại: chạy lại bình thường.
7. (Nếu đã nối) `CapabilityService.load()`: lần đầu dò đủ PID, lần hai chỉ hỏi VIN.
8. Thử với dongle thật nếu có (simulator "sạch" hơn dongle clone).

---

## 9. Đầu vào cho nhóm 6 và nhóm 9 (rút ra từ đối chiếu)

- `obd-droid` có cơ chế **hồi phục khi kẹt NO DATA**: từ 5 lần liên tiếp hoặc quá 3 giây thì tự phục hồi. Ý tưởng đáng cân nhắc cho tự kết nối lại và cho scheduler.
- Sau `LV RESET` cần chạy lại init profile (adapter về cài đặt gốc).
- Reconnect nên dùng backoff và tiếp tục lịch đọc sau khi nối lại; lỗi `error` do adapter treo (nhóm 4) là một trong những tín hiệu kích hoạt reconnect.
- Hàng đợi ưu tiên và bộ lập lịch EDF (Flutter-OBD2, viết lại bằng code của mình) thuộc nhóm 9.

---

## 10. Điều chỉnh bảng kế hoạch v2

| Dòng v2 | Điều chỉnh |
|---|---|
| 4. ELM327 reliability | Nguồn `obd-droid`: THAM KHẢO ý tưởng, không PORT LOGIC |
| 5. Capability | Lưu bằng Hive tạm thời, SQLite ở nhóm 7 |
| 14. PID definitions | Tạm dừng COPY DATA `pids.csv`/`conversions.csv` đến khi xác minh nguồn gốc (mục 5) |
| 15. DTC | Ưu tiên repo MIT `Wal33D/dtc-database`, không dùng file trong app |
| Ma trận giấy phép | Thêm dòng cảnh báo dẫn xuất từ AndrOBD (mục 5) |
