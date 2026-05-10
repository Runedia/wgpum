const std = @import("std");
const win32 = @import("win32");

const REG = win32.system.registry;
const FOUND = win32.foundation;
const LIB = win32.system.library_loader;
const W = win32.zig;
const L = W.L;

const run_subkey = L("Software\\Microsoft\\Windows\\CurrentVersion\\Run");
const value_name = L("wgpum");

pub fn isEnabled() bool {
    var hkey: ?REG.HKEY = null;
    if (REG.RegOpenKeyExW(REG.HKEY_CURRENT_USER, run_subkey, 0, REG.KEY_READ, &hkey) != FOUND.ERROR_SUCCESS) return false;
    defer _ = REG.RegCloseKey(hkey);

    var size: u32 = 0;
    var rtype: REG.REG_VALUE_TYPE = REG.REG_SZ;
    return REG.RegQueryValueExW(hkey, value_name, null, &rtype, null, &size) == FOUND.ERROR_SUCCESS;
}

pub fn enable() bool {
    var hkey: ?REG.HKEY = null;
    if (REG.RegOpenKeyExW(REG.HKEY_CURRENT_USER, run_subkey, 0, REG.KEY_WRITE, &hkey) != FOUND.ERROR_SUCCESS) return false;
    defer _ = REG.RegCloseKey(hkey);

    var path: [windows_max_path:0]u16 = undefined;
    path[windows_max_path - 1] = 0;
    const len = LIB.GetModuleFileNameW(null, &path, path.len);
    if (len == 0 or len >= path.len) return false;

    // 따옴표로 감싼 절대 경로.
    var quoted: [windows_max_path + 4]u16 = undefined;
    quoted[0] = '"';
    @memcpy(quoted[1 .. 1 + len], path[0..len]);
    quoted[1 + len] = '"';
    quoted[2 + len] = 0;

    const byte_size: u32 = @intCast((2 + len + 1) * @sizeOf(u16));
    return REG.RegSetValueExW(
        hkey,
        value_name,
        0,
        REG.REG_SZ,
        @ptrCast(&quoted),
        byte_size,
    ) == FOUND.ERROR_SUCCESS;
}

pub fn disable() bool {
    var hkey: ?REG.HKEY = null;
    if (REG.RegOpenKeyExW(REG.HKEY_CURRENT_USER, run_subkey, 0, REG.KEY_WRITE, &hkey) != FOUND.ERROR_SUCCESS) return false;
    defer _ = REG.RegCloseKey(hkey);

    return REG.RegDeleteValueW(hkey, value_name) == FOUND.ERROR_SUCCESS;
}

const windows_max_path: usize = 260;
