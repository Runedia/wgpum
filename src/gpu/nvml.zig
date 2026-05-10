//! NVML (NVIDIA Management Library) — 동적 로드.
//! NVIDIA 드라이버 설치 시 nvml.dll(또는 nvml64.dll)이 함께 설치된다.
//! 외장 NVIDIA GPU의 전력(mW)과 온도(°C) 측정에 사용.

const std = @import("std");
const win32 = @import("win32");

const LIB = win32.system.library_loader;
const W = win32.zig;

pub const Device = ?*anyopaque; // nvmlDevice_t = struct nvmlDevice_st*

const NVML_SUCCESS: i32 = 0;
const NVML_TEMPERATURE_GPU: u32 = 0;

const FnInit = *const fn () callconv(.winapi) i32;
const FnShutdown = *const fn () callconv(.winapi) i32;
const FnGetCount = *const fn (count: *u32) callconv(.winapi) i32;
const FnGetHandle = *const fn (index: u32, device: *Device) callconv(.winapi) i32;
const FnGetPower = *const fn (device: Device, power_mw: *u32) callconv(.winapi) i32;
const FnGetTemp = *const fn (device: Device, sensor: u32, temp: *u32) callconv(.winapi) i32;

var fn_init: ?FnInit = null;
var fn_shutdown: ?FnShutdown = null;
var fn_count: ?FnGetCount = null;
var fn_handle: ?FnGetHandle = null;
var fn_power: ?FnGetPower = null;
var fn_temp: ?FnGetTemp = null;

var initialized: bool = false;
var init_attempted: bool = false;

pub fn ensureInit() bool {
    if (init_attempted) return initialized;
    init_attempted = true;

    // NVIDIA 드라이버는 시스템 PATH에 nvml.dll을 등록.
    const candidates = [_][:0]const u16{
        W.L("nvml.dll"),
        W.L("nvml64.dll"),
        W.L("C:\\Program Files\\NVIDIA Corporation\\NVSMI\\nvml.dll"),
    };

    var dll: ?win32.foundation.HINSTANCE = null;
    for (candidates) |name| {
        if (LIB.LoadLibraryW(name)) |h| {
            dll = h;
            break;
        }
    }
    const handle = dll orelse return false;

    fn_init = @ptrCast(LIB.GetProcAddress(handle, "nvmlInit_v2") orelse LIB.GetProcAddress(handle, "nvmlInit"));
    fn_shutdown = @ptrCast(LIB.GetProcAddress(handle, "nvmlShutdown"));
    fn_count = @ptrCast(LIB.GetProcAddress(handle, "nvmlDeviceGetCount_v2") orelse LIB.GetProcAddress(handle, "nvmlDeviceGetCount"));
    fn_handle = @ptrCast(LIB.GetProcAddress(handle, "nvmlDeviceGetHandleByIndex_v2") orelse LIB.GetProcAddress(handle, "nvmlDeviceGetHandleByIndex"));
    fn_power = @ptrCast(LIB.GetProcAddress(handle, "nvmlDeviceGetPowerUsage"));
    fn_temp = @ptrCast(LIB.GetProcAddress(handle, "nvmlDeviceGetTemperature"));

    if (fn_init == null or fn_count == null or fn_handle == null) return false;
    if (fn_init.?() != NVML_SUCCESS) return false;

    initialized = true;
    return true;
}

pub fn shutdown() void {
    if (initialized) {
        if (fn_shutdown) |f| _ = f();
    }
    initialized = false;
}

pub fn deviceCount() u32 {
    if (!initialized) return 0;
    var count: u32 = 0;
    if (fn_count.?(&count) != NVML_SUCCESS) return 0;
    return count;
}

pub fn deviceHandle(index: u32) ?Device {
    if (!initialized) return null;
    var dev: Device = null;
    if (fn_handle.?(index, &dev) != NVML_SUCCESS) return null;
    return dev;
}

/// 전력 사용량 (밀리와트). 실패 시 null.
pub fn powerUsageMw(dev: Device) ?u32 {
    if (!initialized or fn_power == null) return null;
    var p: u32 = 0;
    if (fn_power.?(dev, &p) != NVML_SUCCESS) return null;
    return p;
}

/// GPU 코어 온도 (°C). 실패 시 null.
pub fn temperature(dev: Device) ?u32 {
    if (!initialized or fn_temp == null) return null;
    var t: u32 = 0;
    if (fn_temp.?(dev, NVML_TEMPERATURE_GPU, &t) != NVML_SUCCESS) return null;
    return t;
}
