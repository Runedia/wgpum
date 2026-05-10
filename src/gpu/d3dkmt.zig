//! D3DKMT (Display Driver Kernel Mode Thunks). 비공식 ABI지만 작업관리자도 사용.
//! D3DKMT_ADAPTER_PERFDATA 구조체로 어댑터별 전력/온도/팬 RPM 측정.

const std = @import("std");
const win32 = @import("win32");
const FOUND = win32.foundation;

pub const KMT_HANDLE = u32;

/// KMTQUERYADAPTERINFOTYPE 열거 중 PerfData 인덱스.
const KMTQAITYPE_ADAPTERPERFDATA: u32 = 76;

const OpenAdapterFromLuid = extern struct {
    AdapterLuid: FOUND.LUID,
    hAdapter: KMT_HANDLE,
};

const CloseAdapter = extern struct {
    hAdapter: KMT_HANDLE,
};

const QueryAdapterInfo = extern struct {
    hAdapter: KMT_HANDLE,
    InfoType: u32,
    pPrivateDriverData: ?*anyopaque,
    PrivateDriverDataSize: u32,
};

/// 단위 — 드라이버에 따라 약간 다름이 보고됨:
/// - Power: 0..1000 = 0.0..100.0% (TDP 비율) 또는 mW (드라이버 의존)
/// - Temperature: 1/10 °C (예: 650 = 65.0°C) 또는 그대로 °C
/// - FanRPM: RPM
pub const PerfData = extern struct {
    PhysicalAdapterIndex: u32,
    MemoryFrequency: u64,
    MaxMemoryFrequency: u64,
    MaxMemoryFrequencyOC: u64,
    MemoryBandwidth: u64,
    PCIEBandwidth: u64,
    FanRPM: u32,
    Power: u32,
    Temperature: u32,
    PowerStateOverride: u8,
};

// gdi32.dll 정적 링크는 일부 환경에서 entry-point-not-found.
// LoadLibrary + GetProcAddress로 동적 로드해 견고하게 처리.
const LIB = win32.system.library_loader;
const W = win32.zig;

const FnOpen = *const fn (pData: *OpenAdapterFromLuid) callconv(.winapi) i32;
const FnClose = *const fn (pData: *CloseAdapter) callconv(.winapi) i32;
const FnQuery = *const fn (pData: *QueryAdapterInfo) callconv(.winapi) i32;

var fn_open: ?FnOpen = null;
var fn_close: ?FnClose = null;
var fn_query: ?FnQuery = null;
var loaded: bool = false;
/// 마지막 D3DKMTQueryAdapterInfo 호출의 NTSTATUS. 0=성공, 음수=오류.
pub var last_query_status: i32 = 0;
/// 라이브러리 로드 단계 진단.
pub var dll_loaded: bool = false;
pub var open_resolved: bool = false;
pub var query_resolved: bool = false;

fn ensureLoaded() bool {
    if (loaded) return fn_open != null and fn_close != null and fn_query != null;
    loaded = true;

    const dll = LIB.LoadLibraryW(W.L("gdi32.dll")) orelse return false;
    dll_loaded = true;

    if (LIB.GetProcAddress(dll, "D3DKMTOpenAdapterFromLuid")) |p| {
        fn_open = @ptrCast(p);
        open_resolved = true;
    }
    if (LIB.GetProcAddress(dll, "D3DKMTCloseAdapter")) |p| {
        fn_close = @ptrCast(p);
    }
    if (LIB.GetProcAddress(dll, "D3DKMTQueryAdapterInfo")) |p| {
        fn_query = @ptrCast(p);
        query_resolved = true;
    }
    return fn_open != null and fn_close != null and fn_query != null;
}

pub fn open(luid: FOUND.LUID) ?KMT_HANDLE {
    if (!ensureLoaded()) return null;
    var data = OpenAdapterFromLuid{ .AdapterLuid = luid, .hAdapter = 0 };
    if (fn_open.?(&data) < 0) return null;
    return data.hAdapter;
}

pub fn close(handle: KMT_HANDLE) void {
    if (fn_close) |f| {
        var data = CloseAdapter{ .hAdapter = handle };
        _ = f(&data);
    }
}

pub fn queryPerf(handle: KMT_HANDLE) ?PerfData {
    const f = fn_query orelse return null;
    var perf: PerfData = std.mem.zeroes(PerfData);
    var query = QueryAdapterInfo{
        .hAdapter = handle,
        .InfoType = KMTQAITYPE_ADAPTERPERFDATA,
        .pPrivateDriverData = &perf,
        .PrivateDriverDataSize = @sizeOf(PerfData),
    };
    last_query_status = f(&query);
    if (last_query_status < 0) return null;
    return perf;
}
