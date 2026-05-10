const std = @import("std");
const win32 = @import("win32");

pub const UNICODE = true;

const WAM = win32.ui.windows_and_messaging;
const FOUND = win32.foundation;
const HIDPI = win32.ui.hi_dpi;
const GDI = win32.graphics.gdi;
const LIB = win32.system.library_loader;
const W = win32.zig;

const taskbar = @import("sys/taskbar.zig");
const autostart = @import("sys/autostart.zig");
const tray = @import("sys/tray.zig");
const window = @import("ui/window.zig");
const render = @import("ui/render.zig");
const dxgi = @import("gpu/dxgi.zig");
const pdh = @import("gpu/pdh.zig");
const nvml = @import("gpu/nvml.zig");

pub const panic = W.messageBoxThenPanic(.{ .title = "wgpum panic" });

/// 단일 스레드, 작은 할당 (PDH 버퍼 ~16KB) — page_allocator로 충분.
const allocator = std.heap.page_allocator;

/// 모든 윈도우 메시지에서 접근 가능한 전역 상태.
const App = struct {
    adapters: dxgi.AdapterSet,
    pdh_poll: pdh.GpuPoll,
    renderer: render.Renderer,
    gpu_count: i32,
};
var app: App = undefined;

const timer_poll: usize = 1;
const timer_device_debounce: usize = 2;
const DBT_DEVNODES_CHANGED: u32 = 7;

const id_menu_autostart: usize = 100;
const id_menu_exit: usize = 101;
const id_menu_about: usize = 102;

pub fn main() !void {
    _ = HIDPI.SetProcessDpiAwarenessContext(HIDPI.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    taskbar.requireCenterAlignmentOrExit();
    taskbar.requireBottomEdgeOrExit();

    app.adapters = try dxgi.AdapterSet.init();
    app.pdh_poll = try pdh.GpuPoll.init(allocator);
    app.renderer = .{};
    app.gpu_count = @intCast(app.adapters.count);
    if (app.gpu_count == 0) app.gpu_count = 1; // 어댑터 0개여도 창은 띄운다.

    const hinstance = LIB.GetModuleHandleW(null);
    try window.registerClass(hinstance, wndProc);
    const hwnd = try window.create(hinstance, app.gpu_count);
    window.reposition(hwnd, app.gpu_count);

    // 첫 실행 시 자동 시작 등록 (기본 활성).
    if (!autostart.isEnabled()) _ = autostart.enable();

    // 트레이 아이콘 등록 (위젯이 layered window라 투명 영역에서 클릭 통과되어
    // 우클릭 메뉴 접근이 어려움. 트레이로 메뉴를 통합).
    _ = tray.add(hwnd);

    // 1Hz 폴링 타이머. WM_TIMER에서 PDH/VRAM 재수집 후 InvalidateRect.
    _ = WAM.SetTimer(hwnd, timer_poll, 1000, null);

    var msg: WAM.MSG = undefined;
    while (WAM.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = WAM.TranslateMessage(&msg);
        _ = WAM.DispatchMessageW(&msg);
    }

    tray.remove(hwnd);
    app.renderer.deinit();
    app.pdh_poll.deinit(allocator);
    app.adapters.deinit();
    nvml.shutdown();
}

fn showContextMenu(hwnd: FOUND.HWND) void {
    const menu = WAM.CreatePopupMenu() orelse return;
    defer _ = WAM.DestroyMenu(menu);

    const checked: WAM.MENU_ITEM_FLAGS = if (autostart.isEnabled()) WAM.MF_CHECKED else WAM.MF_UNCHECKED;
    _ = WAM.AppendMenuW(menu, checked, id_menu_autostart, W.L("Windows 시작 시 자동 실행"));
    _ = WAM.AppendMenuW(menu, WAM.MF_SEPARATOR, 0, null);
    _ = WAM.AppendMenuW(menu, WAM.MF_STRING, id_menu_about, W.L("wgpum 정보"));
    _ = WAM.AppendMenuW(menu, WAM.MF_STRING, id_menu_exit, W.L("종료"));

    var pt: FOUND.POINT = undefined;
    _ = WAM.GetCursorPos(&pt);
    _ = WAM.SetForegroundWindow(hwnd);
    _ = WAM.TrackPopupMenu(
        menu,
        .{ .RIGHTBUTTON = 1 },
        pt.x,
        pt.y,
        0,
        hwnd,
        null,
    );
}

fn wndProc(hwnd: FOUND.HWND, umsg: u32, wparam: FOUND.WPARAM, lparam: FOUND.LPARAM) callconv(.winapi) FOUND.LRESULT {
    switch (umsg) {
        WAM.WM_DESTROY => {
            WAM.PostQuitMessage(0);
            return 0;
        },
        WAM.WM_PAINT => {
            app.renderer.paint(hwnd, &app.adapters, &app.pdh_poll);
            return 0;
        },
        WAM.WM_TIMER => {
            if (wparam == timer_poll) {
                app.pdh_poll.poll(allocator, &app.adapters) catch {};
                _ = GDI.InvalidateRect(hwnd, null, 0);
                // Z-order 유지: 작업바도 TOPMOST이므로 주기적으로 위로 끌어올림.
                _ = WAM.SetWindowPos(hwnd, WAM.HWND_TOPMOST, 0, 0, 0, 0, .{ .NOMOVE = 1, .NOSIZE = 1, .NOACTIVATE = 1 });
            } else if (wparam == timer_device_debounce) {
                _ = WAM.KillTimer(hwnd, timer_device_debounce);
                app.adapters.enumerate() catch {};
                app.gpu_count = @intCast(app.adapters.count);
                if (app.gpu_count == 0) app.gpu_count = 1;
                window.reposition(hwnd, app.gpu_count);
                _ = GDI.InvalidateRect(hwnd, null, 0);
            }
            return 0;
        },
        WAM.WM_DPICHANGED, WAM.WM_DISPLAYCHANGE, WAM.WM_SETTINGCHANGE => {
            // 작업바 정렬이 좌/우로 바뀌었는지 검사 (무한 모달 회피 위해 시작 시에만 종료).
            window.reposition(hwnd, app.gpu_count);
            return 0;
        },
        WAM.WM_DEVICECHANGE => {
            if (wparam == DBT_DEVNODES_CHANGED) {
                // 디바운스 1초.
                _ = WAM.SetTimer(hwnd, timer_device_debounce, 1000, null);
            }
            return 0;
        },
        tray.callback_msg => {
            // 트레이 아이콘 우클릭 시 컨텍스트 메뉴 표시.
            const ev: u32 = @truncate(@as(usize, @bitCast(lparam)));
            if (ev == WAM.WM_RBUTTONUP or ev == WAM.WM_CONTEXTMENU) {
                showContextMenu(hwnd);
            }
            return 0;
        },
        WAM.WM_COMMAND => {
            const cmd: usize = W.loword(wparam);
            switch (cmd) {
                id_menu_autostart => {
                    if (autostart.isEnabled()) {
                        _ = autostart.disable();
                    } else {
                        _ = autostart.enable();
                    }
                },
                id_menu_about => {
                    _ = WAM.MessageBoxW(hwnd, W.L("wgpum — Windows 11 GPU Monitor\nZig 0.16 + Win32"), W.L("wgpum"), .{ .ICONASTERISK = 1 });
                },
                id_menu_exit => _ = WAM.DestroyWindow(hwnd),
                else => {},
            }
            return 0;
        },
        else => return WAM.DefWindowProcW(hwnd, umsg, wparam, lparam),
    }
}
