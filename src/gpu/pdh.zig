const std = @import("std");
const win32 = @import("win32");

const PERF = win32.system.performance;
const FOUND = win32.foundation;
const W = win32.zig;
const L = W.L;

const dxgi = @import("dxgi.zig");
const nvml = @import("nvml.zig");

/// 사용률: `\GPU Engine(*)\Utilization Percentage` — 작업관리자와 동일한 카운터.
const util_counter_path = L("\\GPU Engine(*)\\Utilization Percentage");
/// VRAM 사용량: `\GPU Adapter Memory(*)\Dedicated Usage`.
const vram_used_counter_path = L("\\GPU Adapter Memory(*)\\Dedicated Usage");
/// VRAM 총량: `\GPU Adapter Memory(*)\Dedicated Limit` — 작업관리자 "전용 GPU 메모리 총량"과 일치.
/// DXGI DedicatedVideoMemory는 AMD iGPU에서 비정상 값(시스템 RAM 절반) 보고 사례 있음.
const vram_total_counter_path = L("\\GPU Adapter Memory(*)\\Dedicated Limit");

/// 어댑터별 사용률은 엔진 인스턴스 중 _최대_값을 사용 (작업관리자 표기와 일치).
/// VRAM은 LUID로 모든 매칭 인스턴스의 합 (각 LUID에는 보통 인스턴스 1개).
pub const GpuPoll = struct {
    query: isize = 0,
    util_counter: isize = 0,
    vram_used_counter: isize = 0,
    vram_total_counter: isize = 0,
    /// 동적 버퍼 (PdhGetFormattedCounterArrayW용, 카운터 공용).
    buffer: []u8 = &.{},
    /// 어댑터별 사용률 (0..100). count = adapters.count.
    util: [dxgi.max_adapters]f64 = std.mem.zeroes([dxgi.max_adapters]f64),
    /// 어댑터별 VRAM 사용량 (bytes).
    vram_used: [dxgi.max_adapters]u64 = std.mem.zeroes([dxgi.max_adapters]u64),
    /// 어댑터별 VRAM 총량 (bytes).
    vram_total: [dxgi.max_adapters]u64 = std.mem.zeroes([dxgi.max_adapters]u64),
    /// NVIDIA 전력 사용량(밀리와트) — NVML 측정. 비-NVIDIA 어댑터는 0.
    nvml_power_mw: [dxgi.max_adapters]u32 = std.mem.zeroes([dxgi.max_adapters]u32),
    /// NVIDIA GPU 온도(°C) — NVML 측정. 0이면 미보고/비-NVIDIA.
    nvml_temp_c: [dxgi.max_adapters]u32 = std.mem.zeroes([dxgi.max_adapters]u32),

    pub fn init(allocator: std.mem.Allocator) !GpuPoll {
        var p: GpuPoll = .{};
        if (PERF.PdhOpenQueryW(null, 0, &p.query) != 0) return error.PdhOpenQueryFailed;
        errdefer _ = PERF.PdhCloseQuery(p.query);

        if (PERF.PdhAddCounterW(p.query, util_counter_path, 0, &p.util_counter) != 0) {
            return error.PdhAddCounterFailed;
        }
        // 메모리 카운터는 시스템에 따라 없을 수도 있으므로 실패해도 진행.
        _ = PERF.PdhAddCounterW(p.query, vram_used_counter_path, 0, &p.vram_used_counter);
        _ = PERF.PdhAddCounterW(p.query, vram_total_counter_path, 0, &p.vram_total_counter);

        // 첫 PdhCollectQueryData는 차분 카운터의 baseline용. 결과는 무시.
        _ = PERF.PdhCollectQueryData(p.query);

        p.buffer = try allocator.alloc(u8, 16 * 1024);
        return p;
    }

    pub fn deinit(self: *GpuPoll, allocator: std.mem.Allocator) void {
        _ = PERF.PdhCloseQuery(self.query);
        allocator.free(self.buffer);
    }

    /// 1Hz 타이머에서 호출. 사용률(max), VRAM 사용/총량 갱신.
    pub fn poll(self: *GpuPoll, allocator: std.mem.Allocator, adapters: *const dxgi.AdapterSet) !void {
        @memset(&self.util, 0);
        @memset(&self.vram_used, 0);
        @memset(&self.vram_total, 0);
        @memset(&self.nvml_power_mw, 0);
        @memset(&self.nvml_temp_c, 0);

        if (PERF.PdhCollectQueryData(self.query) != 0) return;

        // 사용률 (DOUBLE, max).
        try collectAndApply(self, allocator, self.util_counter, PERF.PDH_FMT_DOUBLE, &applyUtilMax, adapters);
        // VRAM 사용량 (LARGE = i64 bytes, sum).
        if (self.vram_used_counter != 0) {
            try collectAndApply(self, allocator, self.vram_used_counter, PERF.PDH_FMT_LARGE, &applyVramUsedSum, adapters);
        }
        // VRAM 총량 (LARGE bytes, sum).
        if (self.vram_total_counter != 0) {
            try collectAndApply(self, allocator, self.vram_total_counter, PERF.PDH_FMT_LARGE, &applyVramTotalSum, adapters);
        }

        // 사용률 100 클램핑.
        for (&self.util) |*u| {
            if (u.* > 100.0) u.* = 100.0;
        }

        // VRAM 총량 폴백: PDH 카운터가 0이면 DXGI 값 사용.
        for (self.vram_total[0..adapters.count], 0..) |*t, i| {
            if (t.* == 0) t.* = adapters.adapters[i].dedicated_total;
        }

        // NVML로 NVIDIA 어댑터 전력/온도 측정.
        for (adapters.adapters[0..adapters.count], 0..) |*a, i| {
            if (a.nvml_device) |dev| {
                self.nvml_power_mw[i] = nvml.powerUsageMw(dev) orelse 0;
                self.nvml_temp_c[i] = nvml.temperature(dev) orelse 0;
            }
        }
    }
};

const ApplyFn = fn (poll: *GpuPoll, idx: usize, item: *const PERF.PDH_FMT_COUNTERVALUE_ITEM_W) void;

fn applyUtilMax(p: *GpuPoll, idx: usize, item: *const PERF.PDH_FMT_COUNTERVALUE_ITEM_W) void {
    const v = item.FmtValue.Anonymous.doubleValue;
    if (v > p.util[idx]) p.util[idx] = v;
}

fn applyVramUsedSum(p: *GpuPoll, idx: usize, item: *const PERF.PDH_FMT_COUNTERVALUE_ITEM_W) void {
    const v = item.FmtValue.Anonymous.largeValue;
    if (v > 0) p.vram_used[idx] += @intCast(v);
}

fn applyVramTotalSum(p: *GpuPoll, idx: usize, item: *const PERF.PDH_FMT_COUNTERVALUE_ITEM_W) void {
    const v = item.FmtValue.Anonymous.largeValue;
    if (v > 0) p.vram_total[idx] += @intCast(v);
}

fn collectAndApply(
    self: *GpuPoll,
    allocator: std.mem.Allocator,
    counter: isize,
    fmt: PERF.PDH_FMT,
    apply: *const ApplyFn,
    adapters: *const dxgi.AdapterSet,
) !void {
    var size: u32 = @intCast(self.buffer.len);
    var item_count: u32 = 0;
    var hr = PERF.PdhGetFormattedCounterArrayW(
        counter,
        fmt,
        &size,
        &item_count,
        @ptrCast(@alignCast(self.buffer.ptr)),
    );
    if (hr == PERF.PDH_MORE_DATA) {
        self.buffer = try allocator.realloc(self.buffer, size);
        size = @intCast(self.buffer.len);
        hr = PERF.PdhGetFormattedCounterArrayW(
            counter,
            fmt,
            &size,
            &item_count,
            @ptrCast(@alignCast(self.buffer.ptr)),
        );
    }
    if (hr != 0) return;

    const items_ptr: [*]PERF.PDH_FMT_COUNTERVALUE_ITEM_W = @ptrCast(@alignCast(self.buffer.ptr));
    const items = items_ptr[0..item_count];
    for (items) |*item| {
        if (item.FmtValue.CStatus != 0) continue;
        const name = item.szName orelse continue;
        const luid = parseInstanceLuid(name) orelse continue;
        const idx = findAdapterIndex(adapters, luid) orelse continue;
        apply(self, idx, item);
    }
}

fn findAdapterIndex(adapters: *const dxgi.AdapterSet, luid: FOUND.LUID) ?usize {
    for (adapters.adapters[0..adapters.count], 0..) |a, i| {
        if (a.luid.LowPart == luid.LowPart and a.luid.HighPart == luid.HighPart) return i;
    }
    return null;
}

/// PDH 인스턴스 이름 (UTF-16 0-terminated)에서 LUID를 추출한다.
/// 형식 예: `pid_8228_luid_0x00000000_0x0000844A_phys_0_eng_0_engtype_3D`
fn parseInstanceLuid(name: [*:0]const u16) ?FOUND.LUID {
    // 일단 ASCII 변환. 인스턴스 이름은 모두 ASCII 범위.
    var ascii_buf: [256]u8 = undefined;
    var n: usize = 0;
    while (n < ascii_buf.len) : (n += 1) {
        const c = name[n];
        if (c == 0) break;
        ascii_buf[n] = if (c < 128) @intCast(c) else '?';
    }
    const ascii: []const u8 = ascii_buf[0..n];

    // GPU Engine 인스턴스: `pid_*_luid_HHHH_LLLL_phys_*_eng_*_engtype_*` (앞에 _luid_)
    // GPU Adapter Memory 인스턴스: `luid_HHHH_LLLL_phys_*` (시작이 luid_)
    // 둘 다 매칭되도록 `luid_`만으로 검색.
    const tag = "luid_";
    const start = std.mem.indexOf(u8, ascii, tag) orelse return null;
    var rest: []const u8 = ascii[start + tag.len ..];

    // 두 16진수 토큰을 `_` 구분자로 읽는다. 0x 접두사는 선택적.
    const hi = parseHexToken(&rest) orelse return null;
    if (rest.len == 0 or rest[0] != '_') return null;
    rest = rest[1..];
    const lo = parseHexToken(&rest) orelse return null;

    return .{
        .HighPart = @bitCast(@as(u32, @truncate(hi))),
        .LowPart = @truncate(lo),
    };
}

fn parseHexToken(rest: *[]const u8) ?u64 {
    var s = rest.*;
    if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) s = s[2..];

    var value: u64 = 0;
    var consumed: usize = 0;
    while (consumed < s.len) : (consumed += 1) {
        const c = s[consumed];
        const digit: u8 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => break,
        };
        value = (value << 4) | digit;
    }
    if (consumed == 0) return null;
    rest.* = s[consumed..];
    return value;
}

test "parseInstanceLuid - GPU Engine format with pid prefix" {
    const wide = std.unicode.utf8ToUtf16LeStringLiteral(
        "pid_8228_luid_0x00000000_0x0000844A_phys_0_eng_0_engtype_3D",
    );
    const luid = parseInstanceLuid(wide).?;
    try std.testing.expectEqual(@as(u32, 0x844A), luid.LowPart);
    try std.testing.expectEqual(@as(i32, 0), luid.HighPart);
}

test "parseInstanceLuid - GPU Adapter Memory format starts with luid" {
    const wide = std.unicode.utf8ToUtf16LeStringLiteral(
        "luid_0x00000000_0x0000844A_phys_0",
    );
    const luid = parseInstanceLuid(wide).?;
    try std.testing.expectEqual(@as(u32, 0x844A), luid.LowPart);
    try std.testing.expectEqual(@as(i32, 0), luid.HighPart);
}
