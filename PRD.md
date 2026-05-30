# wgpum — Windows 11 GPU Monitor (PRD, v1 구현 완료 기준)

## 1. Context

Windows 11 작업 관리자(Task Manager)는 GPU 사용량과 메모리 사용량을 보기 위해 켜두기엔 자체 자원 소비가 과도하다. RSS 50–100MB, GPU 가속 UI(WPF/XAML)로 측정 대상에 측정 도구가 영향을 주는 본말전도 상태다.

본 프로젝트의 목표는 **Task Manager가 보여주는 동일한 GPU 정보(사용률 + VRAM)와 추가로 NVIDIA 전력/온도를 1/10 자원**으로 상시 표시하는 단일 실행 파일을 Zig 0.16 + Win32 직접 호출로 구현하는 것이다. 사용자는 본인 1인이며, 환경은 Windows 11 Pro (Build 26200), **작업바 중앙 정렬 + 화면 하단 고정**, GPU 다중(iGPU + dGPU) 구성이다.

핵심 명제: **자원 효율성은 도구 선택의 결과가 아니라 1순위 제약**이다. 이 제약과 충돌하는 모든 옵션(WebView2, Win11 Widgets Board, .NET, Electron)은 사전 차단된다.

본 문서는 v1 구현이 완료된 코드를 그대로 기술한다. "추후 결정" 항목은 모두 결정·반영되었으며, 미구현 항목은 §2.2 Out-of-scope에 명시한다.

---

## 2. Scope

### 2.1 In-scope (v1 — 구현 완료)
- 다중 GPU 동시 모니터링 (iGPU + dGPU 모두, 최대 8개)
- 메트릭:
  - 어댑터별 GPU 엔진 **사용률(%)** — `\GPU Engine(*)\Utilization Percentage`의 max
  - **전용 VRAM 사용량 / 총량(GiB)** — PDH `\GPU Adapter Memory(*)\Dedicated Usage` + `Dedicated Limit`
  - **NVIDIA 전력(W) / 온도(°C)** — NVML 동적 로드 (`nvml.dll` 미설치 시 자동 비활성)
- 1Hz 폴링 갱신 (`SetTimer`)
- 작업바 **내부**에 시작 버튼 그룹 좌측으로 always-on-top 보더리스 미니 창 고정
- 작업바 정렬 + 위치 검증 — 좌/우 정렬 또는 화면 하단이 아닐 시 모달 후 즉시 종료
- 첫 실행 시 자동 시작 자동 등록 + 트레이 컨텍스트 메뉴로 토글
- 트레이 아이콘 (32×32 ARGB DIB, 코드 임베드)
- DPI 변경, 디스플레이 변경, 작업바 이동 시 위치 자동 재계산 (PerMonitorV2)
- 어댑터 hot-plug(`WM_DEVICECHANGE` + 1초 디바운스) 감지 후 어댑터 + PDH 카운터 재구성
- LUID 기반 PDH 인스턴스 ↔ DXGI 어댑터 정확 매칭 (`pid_*_luid_HHHH_LLLL_*` / `luid_HHHH_LLLL_phys_*` 두 형식 파서)
- iGPU를 GPU0으로 항상 끌어올려 작업관리자 표기와 일치

### 2.2 Out-of-scope (v1)
- 팬 RPM, 클럭, 인코더/디코더 별도 표시 (D3DKMT 인프라는 코드에 있으나 UI 미노출)
- AMD/Intel 전력·온도 (벤더 SDK 추가 필요. NVML만 v1)
- 작업바 좌측·우측 정렬 지원
- 작업바 화면 상/좌/우 배치 지원
- 작업바 자동 숨김 활성 모드
- 다크/라이트 테마 자동 추종 (단색 다크 팔레트만 사용)
- INI 설정 파일 (자동 시작 토글만 트레이 메뉴로 노출)
- 데스크톱 위젯, 게임 오버레이
- 기록(로그/CSV)·임계값 알림
- 일반 배포(서명, 설치 패키지, 자동 업데이트)
- `RegNotifyChangeKeyValue` 기반 `TaskbarAl` 런타임 변경 감시 (시작 시 1회 검증만)

---

## 3. Non-functional Goals

| 항목 | 목표값 | 측정 방법 |
|---|---|---|
| RSS (Working Set) | < 10 MB | Process Explorer, 10분 안정 후 |
| CPU 평균 | < 0.5% (1코어 기준) | PerfMon, 1시간 평균 |
| GPU 사용률 | 0% (자체 측정 대상에서 제외 — GDI 렌더로 달성) | wgpum 자체 측정 |
| 실행 파일 크기 | < 500 KB | `zig build -Doptimize=ReleaseSmall` |
| 외부 동적 의존성 | 시스템 DLL만 (NVML은 선택적) | `dumpbin /dependents` |
| 콜드 스타트 → 첫 프레임 | < 200 ms | QPC 측정 |

---

## 4. UI Specification

### 4.1 형태
- 보더리스, `WS_POPUP | WS_VISIBLE`
- `WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED`
- `SetLayeredWindowAttributes(..., COLORKEY = 0x00FF00FF)` — 배경을 마젠타로 채워 **컬러키 투명** 처리
- 메뉴는 우클릭 시 트레이 아이콘에서 노출 (위젯 본체는 layered + 색상 키로 입력이 작업바로 통과)
- 컨텍스트 메뉴: `Windows 시작 시 자동 실행`(체크박스), `wgpum 정보`, `종료`

### 4.2 레이아웃 (가로 N셀, 셀당 3줄)
```
┌────────────────┬────────────────┬────────────────┐
│ Radeon(TM) 12 %│ RTX 4080   87 %│ RTX 5060    3 %│
│ 0.4 / 1.0 GiB  │ 6.8 / 8.0 GiB  │ 0.2 / 8.0 GiB  │
│  ── W   ── °C  │ 220 W   71 °C  │ 110 W   58 °C  │
└────────────────┴────────────────┴────────────────┘
```
- 셀 폭: `max(200, 155 × N)` × DPI 스케일
- 셀 높이: `max(24, 작업바 높이 - 4)` (작업바 _안에_ 꽉 채움)
- 폰트: Segoe UI, 셀 한 줄 픽셀 높이의 80% (하한 8px)
- 어댑터 라벨: DXGI `description`에서 추출한 친화 이름. NVIDIA는 `RTX`/`GTX` 토큰부터 끝까지에서 `Laptop GPU`/`Max-Q`/`SUPER`/`Ti` 접미사 제거(`RTX 4080 SUPER` → `RTX 4080`), AMD는 `Radeon`부터 ` Graphics` 제거(`Radeon(TM)`), Intel은 `Intel(R) ` 접두사·` Graphics` 접미사 제거(`Arc(TM) A770`). 추출 실패 시 `GPU0`, `GPU1`, …로 폴백 (integrated가 항상 GPU0)
- VRAM 총량은 PDH `Dedicated Limit` 우선 사용. 0이면 DXGI `DedicatedVideoMemory`로 폴백 (AMD iGPU에서 DXGI 값이 시스템 RAM 절반으로 비정상 보고되는 사례 회피)
- 전력/온도는 NVML 결과. 비-NVIDIA 또는 NVML 미동작 시 `── W   ── °C`

### 4.3 위치
- `SHAppBarMessage(ABM_GETTASKBARPOS)`로 작업바 RECT 질의
- X 좌표: `Shell_TrayWnd`의 가시 자식 윈도우 중 작업바 안에 있는 것의 좌측 X 최소값을 시작 버튼 그룹의 왼쪽으로 가정 → `시작 그룹 X - 24px - 위젯 폭`
- 폴백: 시작 그룹 검출 실패 시 `작업바 우측 - 80px - 위젯 폭`
- Y 좌표: 작업바 RECT 안에서 세로 가운데 정렬
- DPI: `DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2` + 매니페스트 `PerMonitorV2`
- 작업바도 TOPMOST이므로 1Hz 타이머마다 `SetWindowPos(HWND_TOPMOST, NOMOVE|NOSIZE|NOACTIVATE)`로 Z-order 유지

### 4.4 색상
- 단색 다크 팔레트 (다크/라이트 자동 추종 미구현)
- 일반 텍스트: `0xF0F0F0`
- 사용률 ≥ 70% → `0xFFC04D` (주황)
- 사용률 ≥ 90% → `0xFF6060` (빨강)
- 배경: 컬러키 마젠타 → 작업바 위에 텍스트만 떠 보임

---

## 5. Architecture

### 5.1 Stack
- **Zig 0.16**, `exe.subsystem = .Windows`, `single_threaded = true`, `pub fn main() !void`
- **zigwin32** (`marlersoft/zigwin32`, commit `ec98bb4d`) — Win32 바인딩 단일 출처
- **GDI / GDI+ 더블 버퍼** — 렌더링 (Direct2D/DirectWrite **미사용**)
- **DXGI 1.4** — 어댑터 열거 + LUID + `IDXGIAdapter3`
- **PDH** — 사용률 + VRAM 카운터
- **D3DKMT** (gdi32.dll의 `D3DKMTOpenAdapterFromLuid` / `D3DKMTQueryAdapterInfo`) — 동적 로드, PerfData 인프라 (UI 미노출)
- **NVML** (nvml.dll) — 동적 로드, NVIDIA 전력/온도
- **Advapi32** — 레지스트리 (TaskbarAl 검증, 자동 시작)
- **Shell32** — `SHAppBarMessage`, `Shell_NotifyIconW`
- **User32 / Gdi32** — 창, 메시지, GDI

> Direct2D / DirectWrite를 의도적으로 채택하지 않았다: HW D2D는 자기 측정에 GPU를 보태고, WARP는 추가 RAM/CPU를 쓴다. 작업바 한 줄 크기의 텍스트 렌더링에는 GDI 더블 버퍼가 더 가볍다.

### 5.2 모듈
| 파일 | 책임 |
|---|---|
| `build.zig` | Windows 타깃, single_threaded, win32 모듈 import |
| `build.zig.zon` | zigwin32 의존성 핀 |
| `app.manifest` | DPI PerMonitorV2, UTF-8, supportedOS |
| `app.rc` | 매니페스트 임베드 (현재 빌드는 매니페스트를 코드 호출로 적용) |
| `src/main.zig` | 진입점, DPI, 사전 검증, 메시지 루프, 컨텍스트 메뉴 |
| `src/sys/taskbar.zig` | `ABM_GETTASKBARPOS`, `TaskbarAl`, 시작 그룹 X 추출(`EnumChildWindows`) |
| `src/sys/autostart.zig` | `HKCU\...\Run\wgpum` 등록/해제, 절대 경로 따옴표 처리 |
| `src/sys/tray.zig` | `Shell_NotifyIconW(NIM_ADD/DELETE)`, 콜백 메시지 라우팅 |
| `src/sys/tray_icon.zig` | 32×32 ARGB DIB로 GPU 아이콘 직접 그리기 → `CreateIconIndirect` |
| `src/gpu/dxgi.zig` | `IDXGIFactory1::EnumAdapters1`, 분류(integrated/discrete/software/remote), iGPU를 GPU0으로 swap |
| `src/gpu/pdh.zig` | PDH 쿼리, 카운터 추가, LUID 매핑, `PdhGetFormattedCounterArrayW` |
| `src/gpu/d3dkmt.zig` | `D3DKMTOpenAdapterFromLuid` + `D3DKMTQueryAdapterInfo(PerfData)` 동적 로드 |
| `src/gpu/nvml.zig` | `nvml.dll` 동적 로드, `nvmlDeviceGetPowerUsage` / `nvmlDeviceGetTemperature` |
| `src/ui/window.zig` | 클래스 등록, 보더리스 layered 창, 가로 셀 크기/위치 계산 |
| `src/ui/render.zig` | 더블 버퍼(`CreateCompatibleDC` + `BitBlt`), 폰트/색상, 셀당 3줄 렌더 |

미구현 (PRD 초안 대비): `src/sys/theme.zig`, `src/config.zig`.

### 5.3 데이터 흐름
**T = 0 (시작)**
1. `SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2)`
2. `taskbar.requireCenterAlignmentOrExit()` — `HKCU\...\Advanced\TaskbarAl == 1` 검증, 아니면 모달 후 `exit(1)`
3. `taskbar.requireBottomEdgeOrExit()` — 작업바 edge가 bottom이 아니면 모달 후 `exit(1)`
4. `dxgi.AdapterSet.init()` — `CreateDXGIFactory1` → `EnumAdapters1` → 분류 → `IDXGIAdapter3` QI → integrated를 GPU0으로 swap → 라벨링 → D3DKMT 핸들 오픈 → NVML 디바이스 매칭(NVIDIA만 PCI 인덱스 순서)
5. `pdh.GpuPoll.init()` — `PdhOpenQueryW` → util/vram_used/vram_total 카운터 추가(메모리 카운터는 실패 허용) → 첫 `PdhCollectQueryData` (baseline)
6. `window.registerClass` + `window.create` — `WS_EX_LAYERED`, 컬러키 마젠타
7. `autostart.enable()` — 첫 실행 시 자동 등록
8. `tray.add()` — 트레이 아이콘 등록, 콜백 메시지 = `WM_APP+1`
9. `SetTimer(timer_poll, 1000ms)`

**T = N (1Hz 타이머)**
1. `pdh.GpuPoll.poll()`:
   - `PdhCollectQueryData`
   - 사용률: 모든 엔진 인스턴스를 LUID로 어댑터에 귀속 후 어댑터별 **max**, 100 클램핑
   - VRAM 사용량: LUID 매칭 인스턴스 합산
   - VRAM 총량: PDH 카운터 합산, 0이면 DXGI 폴백
   - NVIDIA 어댑터마다 NVML로 power_mw / temp_c 갱신
2. `InvalidateRect` → `WM_PAINT`에서 GDI 더블 버퍼로 가로 셀 N개 렌더
3. `SetWindowPos(HWND_TOPMOST, NOMOVE|NOSIZE|NOACTIVATE)` — Z-order 유지

**이벤트**
- `WM_DPICHANGED` / `WM_DISPLAYCHANGE` / `WM_SETTINGCHANGE` → `window.reposition` 재계산
- `WM_DEVICECHANGE` (`DBT_DEVNODES_CHANGED = 7`) → `SetTimer(timer_device_debounce, 1000ms)` 디바운스
- `timer_device_debounce` 발화 → `AdapterSet.enumerate` 재실행, 창 재배치
- 트레이 콜백 (`WM_APP+1`)에서 `WM_RBUTTONUP` / `WM_CONTEXTMENU` → `TrackPopupMenu`
- `WM_COMMAND` → 자동 시작 토글 / 정보 모달 / 종료

---

## 6. Edge Cases & 차단 로직

| 상황 | 동작 |
|---|---|
| `TaskbarAl ≠ 1` (시작 시) | 모달 "wgpum은 작업바가 중앙 정렬일 때만 동작합니다…" → `exit(1)` |
| 작업바가 화면 하단이 아님 (시작 시) | 모달 "wgpum은 작업바가 화면 하단에 있을 때만…" → `exit(1)` |
| `TaskbarAl` 런타임 변경 | v1 미감지 (재시작 시 검증) |
| 작업바 자동 숨김 활성 | v1 미지원 (위치는 계산되지만 숨김 시 위젯이 함께 가려지지 않음) |
| 어댑터 hot-plug | `WM_DEVICECHANGE` 1초 디바운스 후 `AdapterSet` + PDH 풀 재구성 |
| PDH 메모리 카운터 부재 | DXGI `DedicatedVideoMemory`로 폴백 (사용률은 정상) |
| PDH 사용률 카운터 부재 | `PdhAddCounterW` 단계에서 init 실패 → 프로그램 종료. 시스템에 GPU 카운터가 없으면 실행 불가 |
| `nvml.dll` 미설치 | `init_attempted` 처리. 전력/온도 영역 `── W   ── °C`로 표시, 나머지는 정상 |
| 어댑터가 software / remote | `enumerate`에서 스킵 (Microsoft Basic Render Driver, Remote Display 등) |
| `IDXGIAdapter3` QI 실패 | 해당 어댑터 스킵 (Win10 1607 미만 환경. Win11 전제이므로 방어 코드) |
| 권한 | 일반 사용자. 매니페스트 `asInvoker` |

---

## 7. Configuration

v1은 INI 파일이 없다. 사용자가 토글 가능한 항목은 트레이 컨텍스트 메뉴의 **자동 시작** 한 가지뿐이다.

자동 시작 키:
- `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\wgpum` = `"<exe 절대 경로>"`
- 첫 실행 시 자동 등록. 이후 트레이 메뉴로 토글.

---

## 8. Verification

1. **빌드**
   ```pwsh
   zig build -Doptimize=ReleaseSmall
   .\zig-out\bin\wgpum.exe
   ```
2. **자원 측정** — Process Explorer 10분 후 RSS, Private Bytes 기록
3. **메트릭 정확도**
   - 사용률: 작업관리자 GPU 패널과 ±2% (max 방식이므로 작업관리자 표기와 직접 비교)
   - VRAM: 작업관리자 "전용 GPU 메모리"와 ±10 MiB
   - 전력/온도(NVIDIA): MSI Afterburner / `nvidia-smi`와 비교 (NVML이 동일 출처)
4. **차단 로직**
   ```pwsh
   reg add HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced /v TaskbarAl /t REG_DWORD /d 0 /f
   .\zig-out\bin\wgpum.exe   # 모달 + 즉시 종료 확인
   reg add HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced /v TaskbarAl /t REG_DWORD /d 1 /f
   ```
5. **자동 시작** — 트레이 메뉴 토글 후 `reg query HKCU\Software\Microsoft\Windows\CurrentVersion\Run /v wgpum`. 재부팅 시 wgpum 자동 실행
6. **DPI 변경** — 100 → 150% 시 폰트/위치 즉시 재계산
7. **Hot-plug** — eGPU 또는 디바이스 관리자에서 dGPU 비활성/활성 → 1초 후 셀 수 변경
8. **장기 안정성** — 24h 연속 실행 후 RSS 증가 < 1MB, 핸들 누수 0

테스트 코드:
- `src/gpu/pdh.zig`의 `parseInstanceLuid` 두 형식(`pid_*_luid_*` / `luid_*_phys_*`) zig test 포함

---

## 9. Critical Files

- `build.zig`, `build.zig.zon`
- `app.manifest`, `app.rc`
- `assets/icon.svg` (디자인 원본 — 코드 트레이 아이콘이 동일 팔레트로 재현)
- `src/main.zig`
- `src/sys/taskbar.zig`, `src/sys/autostart.zig`, `src/sys/tray.zig`, `src/sys/tray_icon.zig`
- `src/gpu/dxgi.zig`, `src/gpu/pdh.zig`, `src/gpu/d3dkmt.zig`, `src/gpu/nvml.zig`
- `src/ui/window.zig`, `src/ui/render.zig`

---

## 10. References

- DXGI VRAM: <https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_4/nf-dxgi1_4-idxgiadapter3-queryvideomemoryinfo>
- PDH: <https://learn.microsoft.com/en-us/windows/win32/perfctrs/using-the-pdh-functions-to-consume-counter-data>
- Task Manager 내부: <https://devblogs.microsoft.com/directx/gpus-in-the-task-manager>
- AppBar: <https://learn.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-shappbarmessage>
- DPI Awareness V2: <https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setprocessdpiawarenesscontext>
- Layered Windows: <https://learn.microsoft.com/en-us/windows/win32/winmsg/window-features#layered-windows>
- D3DKMT (비공식): <https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/d3dkmthk/>
- NVML: <https://docs.nvidia.com/deploy/nvml-api/>
- zigwin32: <https://github.com/marlersoft/zigwin32>
- Zig 0.16: <https://ziglang.org/download/0.16.0/release-notes.html>
