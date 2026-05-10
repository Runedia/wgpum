const std = @import("std");
const win32 = @import("win32");

const WAM = win32.ui.windows_and_messaging;
const FOUND = win32.foundation;
const HIDPI = win32.ui.hi_dpi;
const LIB = win32.system.library_loader;
const W = win32.zig;
const L = W.L;

const taskbar = @import("../sys/taskbar.zig");

const class_name = L("wgpumWnd");

/// 100% DPI(96 dpi) 기준 기본 창 크기. 가로 레이아웃.
/// 셀당 ~155px × 최대 3 GPU = 465px (실측 시작 그룹 좌측에 보통 여유 있음).
pub const base_w_per_cell: i32 = 155;
pub const base_w_min: i32 = 200;
pub const base_h_padding: i32 = 2;
/// 작업바와 위젯 사이 가로 여백 (시작 버튼 좌측에서 떨어진 거리).
pub const margin_x: i32 = 24;
/// 폴백 시 작업바 우측에서 시계 영역만큼 안쪽 여백.
pub const fallback_right_margin: i32 = 80;

/// `gpu_count`와 작업바 높이로 창 크기를 결정한다.
/// 높이는 작업바 영역 안에 _꽉_ 들어가도록 작업바 높이 - 패딩.
/// 너비는 가로 레이아웃: 셀 너비 × gpu_count.
pub fn scaledSize(gpu_count: i32, dpi: u32) FOUND.SIZE {
    const tb_h: i32 = if (taskbar.queryPos()) |p| p.rect.bottom - p.rect.top else 48;
    const padding = W.scaleDpi(i32, base_h_padding, dpi);
    const cy = @max(24, tb_h - 2 * padding);
    const n = if (gpu_count <= 0) 1 else gpu_count;
    const base_cx = @max(base_w_min, base_w_per_cell * n);
    return .{ .cx = W.scaleDpi(i32, base_cx, dpi), .cy = cy };
}

/// 위젯의 좌상단 좌표를 계산한다.
/// X = 시작 그룹 좌측 - margin - 위젯 너비 (없으면 작업바 우측 폴백).
/// Y = 작업바 RECT 안에서 가운데 정렬 (작업바 _내부_).
pub fn placement(size: FOUND.SIZE, dpi: u32) FOUND.POINT {
    const tb = taskbar.queryPos() orelse {
        return .{ .x = 100, .y = 100 };
    };

    const margin = W.scaleDpi(i32, margin_x, dpi);
    const x = if (taskbar.findStartGroupLeft()) |start_left|
        start_left - margin - size.cx
    else
        tb.rect.right - W.scaleDpi(i32, fallback_right_margin, dpi) - size.cx;

    const y = tb.rect.top + @divTrunc((tb.rect.bottom - tb.rect.top) - size.cy, 2);
    return .{ .x = x, .y = y };
}

pub fn registerClass(hinstance: ?FOUND.HINSTANCE, wnd_proc: WAM.WNDPROC) !void {
    const wcex = WAM.WNDCLASSEXW{
        .cbSize = @sizeOf(WAM.WNDCLASSEXW),
        .style = .{},
        .lpfnWndProc = wnd_proc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        // hCursor=null이면 OS가 부모 커서를 상속해 로딩(busy) 커서로 보일 수 있다. 표준 화살표 명시.
        .hCursor = WAM.LoadCursorW(null, WAM.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name,
        .hIconSm = null,
    };
    if (WAM.RegisterClassExW(&wcex) == 0) return error.RegisterClassFailed;
}

/// 보더리스 always-on-top 미니 창을 생성한다. `gpu_count`는 초기 행 수.
pub fn create(hinstance: ?FOUND.HINSTANCE, gpu_count: i32) !FOUND.HWND {
    // DPI는 창 생성 후에야 GetDpiForWindow로 정확히 알 수 있다.
    // 1차 생성 시점에는 시스템 DPI를 사용하고, 생성 후 재배치한다.
    const sys_dpi = HIDPI.GetDpiForSystem();
    const size = scaledSize(gpu_count, sys_dpi);
    const pos = placement(size, sys_dpi);

    const hwnd = WAM.CreateWindowExW(
        WAM.WINDOW_EX_STYLE{ .TOPMOST = 1, .TOOLWINDOW = 1, .NOACTIVATE = 1, .LAYERED = 1 },
        class_name,
        L("wgpum"),
        WAM.WINDOW_STYLE{ .POPUP = 1, .VISIBLE = 1 },
        pos.x,
        pos.y,
        size.cx,
        size.cy,
        null,
        null,
        hinstance,
        null,
    ) orelse return error.CreateWindowFailed;

    // 마젠타(0xFF00FF)를 색상 키로 지정해 투명 처리. 렌더 시 배경을 이 색으로 채운다.
    _ = WAM.SetLayeredWindowAttributes(hwnd, color_key, 0, .{ .COLORKEY = 1 });
    return hwnd;
}

/// 색상 키로 사용할 RGB. 화면에 거의 등장하지 않을 강한 마젠타.
pub const color_key: u32 = 0x00FF00FF; // BGR: 0xFF, 0x00, 0xFF

/// 작업바/DPI 변경 후 창을 재배치한다.
pub fn reposition(hwnd: FOUND.HWND, gpu_count: i32) void {
    const dpi = W.dpiFromHwnd(hwnd);
    const size = scaledSize(gpu_count, dpi);
    const pos = placement(size, dpi);
    _ = WAM.SetWindowPos(
        hwnd,
        null,
        pos.x,
        pos.y,
        size.cx,
        size.cy,
        WAM.SET_WINDOW_POS_FLAGS{ .NOACTIVATE = 1, .NOZORDER = 1 },
    );
}
