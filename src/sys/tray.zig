const std = @import("std");
const win32 = @import("win32");

const SHELL = win32.ui.shell;
const WAM = win32.ui.windows_and_messaging;
const FOUND = win32.foundation;
const GDI = win32.graphics.gdi;
const W = win32.zig;
const L = W.L;

const tray_icon = @import("tray_icon.zig");

pub const callback_msg: u32 = WAM.WM_APP + 1;
pub const icon_uid: u32 = 1;

var current_hicon: ?WAM.HICON = null;

pub fn add(hwnd: FOUND.HWND) bool {
    current_hicon = tray_icon.create();

    var data: SHELL.NOTIFYICONDATAW = std.mem.zeroes(SHELL.NOTIFYICONDATAW);
    data.cbSize = @sizeOf(SHELL.NOTIFYICONDATAW);
    data.hWnd = hwnd;
    data.uID = icon_uid;
    data.uFlags = .{ .MESSAGE = 1, .ICON = 1, .TIP = 1 };
    data.uCallbackMessage = callback_msg;
    data.hIcon = current_hicon orelse WAM.LoadIconW(null, WAM.IDI_APPLICATION);

    const tip_src = L("wgpum");
    var i: usize = 0;
    while (i < tip_src.len and i < data.szTip.len - 1) : (i += 1) {
        data.szTip[i] = tip_src[i];
    }
    data.szTip[i] = 0;

    return SHELL.Shell_NotifyIconW(SHELL.NIM_ADD, &data) != 0;
}

pub fn remove(hwnd: FOUND.HWND) void {
    var data: SHELL.NOTIFYICONDATAW = std.mem.zeroes(SHELL.NOTIFYICONDATAW);
    data.cbSize = @sizeOf(SHELL.NOTIFYICONDATAW);
    data.hWnd = hwnd;
    data.uID = icon_uid;
    _ = SHELL.Shell_NotifyIconW(SHELL.NIM_DELETE, &data);

    if (current_hicon) |h| _ = WAM.DestroyIcon(h);
    current_hicon = null;
}
