# CLAUDE.md

이 파일은 Claude Code (claude.ai/code)가 이 저장소에서 작업할 때 알아야 할 컨벤션과 의사결정을 담는다. PRD가 _무엇_을 만드는지를 다룬다면, 이 문서는 _어떻게_ 그리고 _왜_를 다룬다.

## 한 줄 요약

Windows 11 작업바 안에 들어가는 GPU 모니터 위젯. **Zig 0.16 + zigwin32만** 사용해 단일 exe로 빌드. 자원 효율(RSS < 10MB, GPU 0%)이 1순위 제약.

## 빌드

```pwsh
zig build                          # Debug
zig build -Doptimize=ReleaseSmall  # 배포
zig build run                      # 빌드 + 실행
zig build test                     # pdh.zig parseInstanceLuid 테스트
```

산출물: `zig-out/bin/wgpum.exe`. 외부 정적 의존성은 zigwin32뿐 (`build.zig.zon`에 commit hash로 핀).

## 아키텍처 한눈에

```
main.zig
  ├ sys/taskbar.zig    TaskbarAl + ABM_GETTASKBARPOS + 시작 그룹 X 검출
  ├ sys/autostart.zig  HKCU\...\Run\wgpum
  ├ sys/tray.zig       Shell_NotifyIconW (NIM_ADD/DELETE)
  ├ sys/tray_icon.zig  32×32 ARGB DIB → CreateIconIndirect
  ├ gpu/dxgi.zig       AdapterSet (분류, integrated를 GPU0으로 swap, NVML 매칭)
  │   ├ gpu/d3dkmt.zig D3DKMTQueryAdapterInfo (PerfData. 동적 로드, UI 미노출)
  │   └ gpu/nvml.zig   nvmlDeviceGetPowerUsage / Temperature (NVIDIA만)
  ├ gpu/pdh.zig        PDH 쿼리, LUID 매핑, 사용률 max + VRAM sum
  ├ ui/window.zig      WS_EX_LAYERED + COLORKEY, 가로 셀 크기/위치
  └ ui/render.zig      GDI 더블 버퍼, 셀당 3줄
```

데이터 흐름은 **단방향**: `WM_TIMER` → `pdh.poll` → `InvalidateRect` → `WM_PAINT` → `render.paint`. 폴링 외 상태 변경 없음.

## 핵심 의사결정 (변경 시 이 문서도 갱신)

### "왜 Direct2D가 아니라 GDI인가"
HW Direct2D는 자기 측정에 GPU를 보태고, WARP는 추가 RAM/CPU를 쓴다. 작업바 한 줄 크기의 텍스트 렌더에는 `CreateCompatibleDC` + `BitBlt` 더블 버퍼면 충분하다. 새로운 그래픽 효과가 필요하다고 D2D를 끌어들이지 말 것.

### "왜 Layered + COLORKEY인가"
- `WS_EX_TRANSPARENT`는 입력을 통과시키지만 위젯 _본체_의 우클릭 메뉴를 막는다 → 메뉴를 트레이로 옮기고 본체는 입력 통과시킴.
- 알파 합성(`UpdateLayeredWindow`)은 더블 버퍼 + per-pixel alpha를 매 프레임 업데이트해야 해 무겁다. 컬러키 한 줄(`SetLayeredWindowAttributes(... COLORKEY ...)`)이 충분.
- 색상 키는 마젠타 `0x00FF00FF` (BGR로 0xFF, 0x00, 0xFF). 텍스트가 우연히 이 색을 갖지 않게 주의.

### "왜 사용률은 max인가"
작업관리자와 일치시키기 위함. PDH `\GPU Engine(*)\Utilization Percentage`는 엔진별(3D, Compute, Copy, Video Decode 등)로 인스턴스가 분리돼 있어 **합산하면 100%를 넘는다**. max + 100 클램핑이 직관적이고 task manager와 비교 검증이 쉽다.

### "왜 iGPU를 GPU0으로 강제하는가"
DXGI enumeration 순서는 시스템마다 다르다. 사용자 정신 모델(첫 셀 = 내장 GPU)을 고정하기 위해 `enumerate` 끝에서 swap.

### "왜 NVML을 동적 로드하는가"
`nvml.dll`은 NVIDIA 드라이버 패키지에 포함되며, AMD/Intel-only 시스템엔 없다. 정적 링크 시 그런 시스템에서 실행이 막힌다. `LoadLibraryW` 후보를 `nvml.dll` → `nvml64.dll` → `C:\Program Files\NVIDIA Corporation\NVSMI\nvml.dll` 순으로 시도.

### "왜 D3DKMT 코드는 있는데 UI에 없는가"
`D3DKMTQueryAdapterInfo(KMTQAITYPE_ADAPTERPERFDATA)`는 _비공식 ABI_다. 드라이버에 따라 단위가 다르고(Power: 0..1000 vs mW, Temperature: 1/10°C vs °C), 일부 드라이버에선 `STATUS_NOT_SUPPORTED`를 반환한다. 인프라(`open` / `queryPerf`)는 두되, UI에는 NVML(공식 API) 결과만 노출. AMD/Intel 전력은 추후 벤더별 SDK 추가 시 결정.

### "왜 작업바 좌/우/상단을 지원하지 않는가"
`Shell_TrayWnd`의 자식 윈도우 좌표 추론(`taskbar.findStartGroupLeft`)이 가로 작업바 가정에 맞춰져 있다. 세로 작업바 / 다른 정렬은 검증 비용이 크고 사용자(1인)가 쓰지 않는다 → v1 차단.

## 코드 컨벤션

- **모든 Win32 호출은 zigwin32 경유**. Zig 0.16에서 `std.os.windows`가 대거 제거됐고, 잘 쓰지 않는 ABI는 `extern fn`으로 직접 선언 (예: `d3dkmt.zig`, `nvml.zig`).
- **자원 해제**: `errdefer` + `defer` 조합. `AdapterSet.deinit`, `GpuPoll.deinit`은 main 종료 직전에 호출. `tray.remove`는 `WM_QUIT` 전에 호출.
- **할당자**: `std.heap.page_allocator` 단일. 큰 동적 버퍼는 `pdh.GpuPoll.buffer` (16KB 시작, `PDH_MORE_DATA`에 따라 realloc).
- **single_threaded**: `build.zig`에서 `single_threaded = true`. 멀티스레드를 도입할 때는 page_allocator → ArenaAllocator/스레드 안전 alloc 재검토.
- **에러 모드**: `pub const panic = W.messageBoxThenPanic(...)`. panic은 사용자에게 모달로 보고된 후 종료.
- **문자열**: zigwin32의 `W.L("...")`로 UTF-16 리터럴. 긴 한글 메시지는 `@setEvalBranchQuota(1_000_000)`이 필요할 수 있다 (`taskbar.zig` 참고).
- **인스턴스 이름 파싱**: PDH 인스턴스 이름은 ASCII 범위. `pdh.parseInstanceLuid`는 `pid_*_luid_*` (GPU Engine)와 `luid_*_phys_*` (GPU Adapter Memory) 두 형식 모두 처리. 형식이 추가되면 두 zig test 케이스도 함께 추가.
- **DPI**: `W.scaleDpi(i32, base, dpi)`로 모든 좌표/크기를 스케일. base 값은 96dpi 기준.

## 절대 하지 말 것

- **CRT 의존 추가 금지** — `libc` / `printf` / `malloc` 직링크 금지. `std.heap.page_allocator`만.
- **D2D / DWrite / GDI+ 도입 금지** (자원 예산 위반 위험)
- **추가 스레드 생성 금지** (`single_threaded = true`. 1Hz 폴링은 메시지 루프 + WM_TIMER로 충분)
- **`child_process` API 사용 금지** (사용자 글로벌 정책 — 빌드 스크립트조차 외부 프로세스 실행하지 말 것)
- **WebView2 / Electron / .NET / WPF 의존 금지**
- **세로 작업바 / 좌·우 정렬 / 화면 상·좌·우 작업바 지원 금지** (검증 부담)
- **D3DKMT 결과를 UI에 직접 노출 금지** (ABI 비공식, 단위 불일치)
- **자동 시작 키를 HKLM에 쓰지 말 것** — `HKCU`만. UAC 미요청

## 자주 쓰는 디버그 흐름

**위젯이 안 뜬다**
1. `taskbar.requireCenterAlignmentOrExit` / `requireBottomEdgeOrExit` 통과 여부 (모달 메시지로 알 수 있음)
2. `dxgi.AdapterSet.init` 실패 — 가시 어댑터 0개? `EnumAdapters1` 결과 로그 추가
3. `window.create` 실패 — `GetLastError`

**사용률이 항상 0%**
- `pdh.GpuPoll.init`에서 `PdhAddCounterW(util_counter)` 결과 확인 (성능 카운터 손상)
- `parseInstanceLuid`가 LUID를 못 뽑는 경우 — 인스턴스 이름 형식 변경 가능. zig test 추가 후 패치

**VRAM 0/0**
- PDH 메모리 카운터가 없는 시스템: DXGI 폴백이 동작해야 함. `adapters.adapters[i].dedicated_total`이 0이면 IDXGIAdapter1::GetDesc1 결과 점검

**셀이 작업바 밖에 뜬다**
- `taskbar.findStartGroupLeft`가 잘못된 자식을 잡음. 자식 필터 (높이/너비 임계, 작업바 RECT 내부 검사)를 조정. 작업바 자식 윈도우는 Win11 업데이트마다 미세하게 바뀐다.

## 자주 쓰는 명령

```pwsh
# 카운터 존재 확인
typeperf -q "\GPU Engine(*)\Utilization Percentage" | Select-Object -First 5

# 의존성 확인
dumpbin /dependents .\zig-out\bin\wgpum.exe

# 자동 시작 키 상태
reg query HKCU\Software\Microsoft\Windows\CurrentVersion\Run /v wgpum

# TaskbarAl 강제 변경 (검증용. 1=중앙, 0=좌측)
reg add HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced /v TaskbarAl /t REG_DWORD /d 1 /f
```

## 변경 시 검증 체크리스트

- [ ] `zig build -Doptimize=ReleaseSmall` 통과
- [ ] `zig build test` 통과 (pdh 파서)
- [ ] `dumpbin /dependents`에서 시스템 DLL 외 추가 없음
- [ ] Process Explorer로 RSS < 10MB
- [ ] 작업관리자 GPU 패널과 사용률 ±2%, VRAM ±10MiB
- [ ] `TaskbarAl=0` 설정 후 모달 + 즉시 종료
- [ ] 100% / 150% DPI 양쪽에서 셀 위치 정상
