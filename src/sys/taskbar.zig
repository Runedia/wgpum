const std = @import("std");
const win32 = @import("win32");

const REG = win32.system.registry;
const FOUND = win32.foundation;
const SHELL = win32.ui.shell;
const W = win32.zig;
const L = W.L;

pub const Edge = enum(u32) {
    left = 0,
    top = 1,
    right = 2,
    bottom = 3,
    _,
};

pub const Pos = struct {
    edge: Edge,
    rect: FOUND.RECT,
};

pub const Alignment = enum(u32) {
    left = 0,
    center = 1,
    right = 2,
    _,
};

const advanced_subkey = L("Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced");
const value_name = L("TaskbarAl");

/// `TaskbarAl` 값을 읽는다. 키나 값이 없으면 Win11 기본값(.center)으로 간주한다.
pub fn readAlignment() Alignment {
    var hkey: ?REG.HKEY = null;
    const open = REG.RegOpenKeyExW(REG.HKEY_CURRENT_USER, advanced_subkey, 0, REG.KEY_READ, &hkey);
    if (open != FOUND.ERROR_SUCCESS) return .center;
    defer _ = REG.RegCloseKey(hkey);

    var value: u32 = 1;
    var size: u32 = @sizeOf(u32);
    var rtype: REG.REG_VALUE_TYPE = REG.REG_DWORD;
    const q = REG.RegQueryValueExW(
        hkey,
        value_name,
        null,
        &rtype,
        @ptrCast(&value),
        &size,
    );
    if (q != FOUND.ERROR_SUCCESS or rtype != REG.REG_DWORD) return .center;
    return @enumFromInt(value);
}

const msg_left = blk: {
    @setEvalBranchQuota(1_000_000);
    break :blk L("wgpum은 작업바가 중앙 정렬일 때만 동작합니다.\n현재 정렬: 왼쪽.\n\n작업바 설정에서 정렬을 '가운데'로 변경한 뒤 다시 실행하십시오.");
};
const msg_right = blk: {
    @setEvalBranchQuota(1_000_000);
    break :blk L("wgpum은 작업바가 중앙 정렬일 때만 동작합니다.\n현재 정렬: 오른쪽.\n\n작업바 설정에서 정렬을 '가운데'로 변경한 뒤 다시 실행하십시오.");
};
const msg_other = blk: {
    @setEvalBranchQuota(1_000_000);
    break :blk L("wgpum은 작업바가 중앙 정렬일 때만 동작합니다.\n알 수 없는 정렬 값.\n작업바 설정을 확인하십시오.");
};

/// `SHAppBarMessage(ABM_GETTASKBARPOS)`로 작업바 위치를 질의한다.
pub fn queryPos() ?Pos {
    var data: SHELL.APPBARDATA = std.mem.zeroes(SHELL.APPBARDATA);
    data.cbSize = @sizeOf(SHELL.APPBARDATA);
    if (SHELL.SHAppBarMessage(SHELL.ABM_GETTASKBARPOS, &data) == 0) return null;
    return .{ .edge = @enumFromInt(data.uEdge), .rect = data.rc };
}

const WAM = win32.ui.windows_and_messaging;

const EnumCtx = struct {
    tray_rect: FOUND.RECT,
    min_left: i32,
};

/// `Shell_TrayWnd` 자식 윈도우 중 가시 자식의 좌측 X 최소값을 반환.
/// 작업바 중앙 정렬 시 시작 버튼이 가운데 그룹의 가장 왼쪽이므로
/// 이 값이 시작 버튼 좌측 X 좌표에 가깝다.
pub fn findStartGroupLeft() ?i32 {
    const tray = WAM.FindWindowW(L("Shell_TrayWnd"), null) orelse return null;
    var ctx = EnumCtx{
        .tray_rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .min_left = std.math.maxInt(i32),
    };
    if (WAM.GetWindowRect(tray, &ctx.tray_rect) == 0) return null;
    _ = WAM.EnumChildWindows(tray, enumChildProc, @bitCast(@intFromPtr(&ctx)));
    if (ctx.min_left == std.math.maxInt(i32)) return null;
    return ctx.min_left;
}

fn enumChildProc(hwnd: FOUND.HWND, lparam: FOUND.LPARAM) callconv(.winapi) FOUND.BOOL {
    const ctx_ptr: *EnumCtx = @ptrFromInt(@as(usize, @bitCast(lparam)));
    if (WAM.IsWindowVisible(hwnd) == 0) return 1;

    var rect: FOUND.RECT = undefined;
    if (WAM.GetWindowRect(hwnd, &rect) == 0) return 1;

    // 작업바 RECT 안에 들어오는 자식만 (다른 모니터의 자손 회피).
    if (rect.left < ctx_ptr.tray_rect.left or rect.right > ctx_ptr.tray_rect.right) return 1;
    if (rect.top < ctx_ptr.tray_rect.top - 10 or rect.bottom > ctx_ptr.tray_rect.bottom + 10) return 1;

    // 1×1 placeholder, 0-크기 자식 제외.
    const w = rect.right - rect.left;
    const h = rect.bottom - rect.top;
    if (w < 16 or h < 16) return 1;

    // 작업바 좌측 끝에 붙은 거대 자식 (전체 너비 자식) 제외.
    const tray_w = ctx_ptr.tray_rect.right - ctx_ptr.tray_rect.left;
    if (w > @divFloor(tray_w * 3, 4)) return 1;

    if (rect.left < ctx_ptr.min_left) ctx_ptr.min_left = rect.left;
    return 1;
}

/// 작업바가 화면 하단에 있지 않으면 모달을 띄우고 종료한다.
pub fn requireBottomEdgeOrExit() void {
    const p = queryPos() orelse return;
    if (p.edge == .bottom) return;
    _ = WAM.MessageBoxW(null, msg_not_bottom, L("wgpum"), .{ .ICONHAND = 1 });
    std.process.exit(1);
}

const msg_not_bottom = blk: {
    @setEvalBranchQuota(1_000_000);
    break :blk L("wgpum은 작업바가 화면 하단에 있을 때만 동작합니다.\n작업바를 하단으로 이동한 뒤 다시 실행하십시오.");
};

/// 중앙 정렬이 아니면 모달을 띄우고 종료한다.
pub fn requireCenterAlignmentOrExit() void {
    const a = readAlignment();
    if (a == .center) return;

    const text = switch (a) {
        .left => msg_left,
        .right => msg_right,
        else => msg_other,
    };
    _ = WAM.MessageBoxW(null, text, L("wgpum"), .{ .ICONHAND = 1 });
    std.process.exit(1);
}
