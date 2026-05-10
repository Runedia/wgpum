# wgpum

> Windows 11 작업바 안에 들어가는 초경량 GPU 모니터. Zig 0.16 + Win32 직접 호출.

작업관리자(Task Manager)는 GPU 사용량을 보기 위해 켜두기엔 자체 자원 소비가 과도하다 (RSS 50–100MB, GPU 가속 UI). `wgpum`은 동일한 정보(사용률 + VRAM)와 NVIDIA 전력/온도를 **시스템 자원의 1/10**로 상시 표시하는 단일 실행 파일이다.

```
┌────────────────┬────────────────┬────────────────┐
│  GPU0   12 %   │  GPU1   87 %   │  GPU2    3 %   │
│ 0.4 / 1.0 GiB  │ 6.8 / 8.0 GiB  │ 0.2 / 8.0 GiB  │
│  ── W   ── °C  │ 220 W   71 °C  │ 110 W   58 °C  │
└────────────────┴────────────────┴────────────────┘
        ↑                ↑                ↑
     iGPU            dGPU0(NVIDIA)    dGPU1(NVIDIA)
```

위젯은 작업바의 시작 버튼 그룹 좌측에 layered window로 떠 있으며, 컬러키 투명도로 작업바와 시각적으로 일체화된다.

---

## 요구 사항

- **Windows 11** (Build 22000 이상)
- 작업바 정렬: **중앙** (`HKCU\...\Advanced\TaskbarAl == 1`)
- 작업바 위치: **화면 하단**
- 위 두 조건 중 하나라도 어긋나면 모달 후 즉시 종료
- (선택) NVIDIA GPU 전력/온도 표시는 NVIDIA 드라이버에 포함된 `nvml.dll`에 의존. 미설치 시 해당 칸은 `── W   ── °C`로 표시

빌드 요구:
- **Zig 0.16.0** 이상

---

## 빌드

```pwsh
git clone https://github.com/<user>/wgpum
cd wgpum
zig build -Doptimize=ReleaseSmall
.\zig-out\bin\wgpum.exe
```

zigwin32 의존성은 `build.zig.zon`이 자동으로 가져온다.

### 디버그 실행

```pwsh
zig build run
```

---

## 동작 개요

| 메트릭 | 출처 | 비고 |
|---|---|---|
| 사용률 (%) | PDH `\GPU Engine(*)\Utilization Percentage` | 어댑터별 엔진 인스턴스 max (작업관리자 일치) |
| VRAM 사용량 | PDH `\GPU Adapter Memory(*)\Dedicated Usage` | LUID로 어댑터 매핑 |
| VRAM 총량 | PDH `\GPU Adapter Memory(*)\Dedicated Limit` | 0이면 DXGI `DedicatedVideoMemory`로 폴백 |
| 전력 / 온도 | NVML (`nvml.dll`) | NVIDIA 어댑터만. 비-NVIDIA는 `──` |

- 1Hz 폴링
- iGPU는 항상 `GPU0`으로 정렬됨 (작업관리자 표기와 일치)
- 어댑터 hot-plug: `WM_DEVICECHANGE` + 1초 디바운스 후 어댑터/카운터 재구성
- DPI / 디스플레이 변경 시 위치·크기 자동 재계산 (PerMonitorV2)

### 트레이 컨텍스트 메뉴

위젯 본체는 layered window라 클릭이 작업바로 통과한다. 우클릭 메뉴는 **트레이 아이콘**에서 노출된다:

- `Windows 시작 시 자동 실행` (체크박스, 첫 실행 시 자동으로 켜짐)
- `wgpum 정보`
- `종료`

---

## 자원

| 항목 | 목표 | 비고 |
|---|---|---|
| RSS | < 10 MB | Process Explorer 10분 후 |
| CPU 평균 | < 0.5% (1코어) | PerfMon 1시간 평균 |
| GPU 사용률 | 0% | GDI 더블 버퍼 렌더 (Direct2D 미사용) |
| 실행 파일 | < 500 KB | `ReleaseSmall` |
| 동적 의존성 | 시스템 DLL만 | NVML은 선택적 동적 로드 |

`dumpbin /dependents .\zig-out\bin\wgpum.exe`로 시스템 DLL 외 의존성이 없는지 확인.

---

## 트러블슈팅

**모달 "wgpum은 작업바가 중앙 정렬일 때만…"**
설정 → 개인 설정 → 작업 표시줄 → 작업 표시줄 동작 → 정렬을 **가운데**로.

**모달 "wgpum은 작업바가 화면 하단에 있을 때만…"**
v1은 화면 하단 작업바만 지원. 좌/우/상단은 미지원.

**전력/온도 칸이 항상 `── W   ── °C`**
- NVIDIA GPU가 없거나, 드라이버가 NVML을 설치하지 않은 경우.
- 드라이버 설치 위치(`C:\Program Files\NVIDIA Corporation\NVSMI\nvml.dll` 등)에서 `nvml.dll`을 찾지 못하면 비활성화.
- AMD/Intel 전력·온도는 v1 미지원.

**위젯이 안 보인다**
- 시작 버튼 그룹 검출에 실패하면 작업바 우측 - 80px로 폴백. 다른 시스템 트레이 위젯과 겹칠 수 있다.
- 작업관리자에서 `wgpum.exe` 프로세스 존재 확인.

**자동 시작을 끄고 싶다**
트레이 메뉴 → `Windows 시작 시 자동 실행` 체크 해제. 또는:
```pwsh
reg delete HKCU\Software\Microsoft\Windows\CurrentVersion\Run /v wgpum /f
```

---

## 디자인 결정

상세는 [PRD.md](./PRD.md) 참조. 핵심:

- **Direct2D / DirectWrite 미채택**: HW D2D는 자기 측정에 GPU를 보태고, WARP는 추가 RAM/CPU를 쓴다. 작업바 한 줄짜리 텍스트 렌더링에는 GDI 더블 버퍼가 더 가볍다.
- **사용률 max(엔진)**: 작업관리자와 동일 표기. 합 클램핑은 게임 시 한 엔진만 90%여도 100%로 보이는 직관 차이를 만든다.
- **Layered + COLORKEY**: 입력 비활성을 위해 `WS_EX_TRANSPARENT`를 쓰지 않고 컬러키 마젠타로 투명. 메뉴는 트레이로 분리.
- **iGPU = GPU0 강제**: 작업관리자는 enumeration 순서를 따르지만, integrated를 항상 첫 셀로 두는 편이 사용자에게 직관적이다.

---

## 라이선스

MIT
