const std = @import("std");
const win32 = @import("win32");

const DXGI = win32.graphics.dxgi;
const FOUND = win32.foundation;
const W = win32.zig;

const d3dkmt = @import("d3dkmt.zig");
const nvml = @import("nvml.zig");

pub const max_adapters = 8;

pub const AdapterRole = enum { integrated, discrete, software, remote };

pub const Adapter = struct {
    luid: FOUND.LUID,
    label: [16:0]u8, // 짧은 라벨: GPU0, GPU1, ...
    description: [128]u16, // GetDesc1 원본
    dedicated_total: u64, // bytes (DXGI 폴백용)
    vendor_id: u32,
    role: AdapterRole,
    /// IDXGIAdapter3 인터페이스 (메모리 질의용).
    adapter3: *DXGI.IDXGIAdapter3,
    /// D3DKMT 어댑터 핸들 (전력/온도/팬 측정용). open 실패 시 0.
    kmt_handle: d3dkmt.KMT_HANDLE = 0,
    /// NVML 디바이스 핸들 (NVIDIA 전력/온도 측정용). 비-NVIDIA 어댑터는 null.
    nvml_device: ?nvml.Device = null,

    pub fn release(self: *Adapter) void {
        if (self.kmt_handle != 0) d3dkmt.close(self.kmt_handle);
        _ = self.adapter3.IUnknown.Release();
    }

    pub fn perf(self: *const Adapter) ?d3dkmt.PerfData {
        if (self.kmt_handle == 0) return null;
        return d3dkmt.queryPerf(self.kmt_handle);
    }
};

pub const AdapterSet = struct {
    factory: *DXGI.IDXGIFactory1,
    adapters: [max_adapters]Adapter = undefined,
    count: usize = 0,

    pub fn init() !AdapterSet {
        var factory_raw: ?*anyopaque = null;
        const hr = DXGI.CreateDXGIFactory1(DXGI.IID_IDXGIFactory1, @ptrCast(&factory_raw));
        if (W.FAILED(hr)) return error.CreateDXGIFactory1Failed;

        var set: AdapterSet = .{ .factory = @ptrCast(@alignCast(factory_raw.?)) };
        try set.enumerate();
        return set;
    }

    pub fn deinit(self: *AdapterSet) void {
        for (self.adapters[0..self.count]) |*a| a.release();
        _ = self.factory.IUnknown.Release();
    }

    /// IDXGIFactory1에서 어댑터를 다시 열거하고 IDXGIAdapter3 캐시를 갱신한다.
    /// 작업관리자 표기와 일치하도록: integrated를 항상 GPU0에 둔다.
    pub fn enumerate(self: *AdapterSet) !void {
        for (self.adapters[0..self.count]) |*a| a.release();
        self.count = 0;

        var i: u32 = 0;
        var igpu_seen: bool = false;
        while (self.count < max_adapters) : (i += 1) {
            var adapter1_raw: *DXGI.IDXGIAdapter1 = undefined;
            const hr = self.factory.EnumAdapters1(i, &adapter1_raw);
            if (W.FAILED(hr)) break;
            defer _ = adapter1_raw.IUnknown.Release();

            var desc: DXGI.DXGI_ADAPTER_DESC1 = undefined;
            if (W.FAILED(adapter1_raw.GetDesc1(&desc))) continue;

            const role = classifyAdapter(&desc, &igpu_seen);
            // 소프트웨어(Microsoft Basic Render Driver) / 원격 어댑터는 제외.
            if (role == .software or role == .remote) continue;

            // QueryInterface for IDXGIAdapter3
            var adapter3_raw: ?*anyopaque = null;
            if (W.FAILED(adapter1_raw.IUnknown.QueryInterface(DXGI.IID_IDXGIAdapter3, @ptrCast(&adapter3_raw)))) continue;
            const adapter3: *DXGI.IDXGIAdapter3 = @ptrCast(@alignCast(adapter3_raw.?));

            self.adapters[self.count] = .{
                .luid = desc.AdapterLuid,
                .label = std.mem.zeroes([16:0]u8),
                .description = desc.Description,
                .dedicated_total = desc.DedicatedVideoMemory,
                .vendor_id = desc.VendorId,
                .role = role,
                .adapter3 = adapter3,
                .kmt_handle = d3dkmt.open(desc.AdapterLuid) orelse 0,
            };
            self.count += 1;
        }

        // integrated를 0번으로 끌어올린다.
        for (self.adapters[0..self.count], 0..) |a, idx| {
            if (a.role == .integrated and idx > 0) {
                std.mem.swap(Adapter, &self.adapters[0], &self.adapters[idx]);
                break;
            }
        }

        // 라벨링: GPU0, GPU1, GPU2, ...
        for (self.adapters[0..self.count], 0..) |*a, idx| {
            _ = std.fmt.bufPrint(&a.label, "GPU{d}", .{idx}) catch {};
        }

        // NVIDIA 어댑터에 NVML device 매칭 (PCI 정렬 가정으로 단순 인덱싱).
        if (nvml.ensureInit()) {
            const nvidia_vendor: u32 = 0x10DE;
            const nvml_count = nvml.deviceCount();
            var nvml_idx: u32 = 0;
            for (self.adapters[0..self.count]) |*a| {
                if (a.vendor_id == nvidia_vendor and nvml_idx < nvml_count) {
                    a.nvml_device = nvml.deviceHandle(nvml_idx);
                    nvml_idx += 1;
                }
            }
        }
    }

    pub fn slice(self: *AdapterSet) []Adapter {
        return self.adapters[0..self.count];
    }

    pub fn findByLuid(self: *AdapterSet, luid: FOUND.LUID) ?*Adapter {
        for (self.adapters[0..self.count]) |*a| {
            if (a.luid.LowPart == luid.LowPart and a.luid.HighPart == luid.HighPart) return a;
        }
        return null;
    }
};

/// VendorId + description 기반 어댑터 분류.
/// DedicatedVideoMemory는 AMD iGPU에서 비정상 보고되므로 임계치로 사용 불가.
fn classifyAdapter(desc: *const DXGI.DXGI_ADAPTER_DESC1, igpu_seen: *bool) AdapterRole {
    // DXGI_ADAPTER_FLAG_SOFTWARE = 2
    if ((desc.Flags & 0x2) != 0) return .software;
    if (looksLikeRemote(&desc.Description)) return .remote;

    const vendor_intel: u32 = 0x8086;
    const vendor_amd: u32 = 0x1002;
    const vendor_nvidia: u32 = 0x10DE;

    // Intel: 거의 모두 iGPU (UHD Graphics, Iris Xe, Arc는 예외이나 보통 description으로 식별).
    if (desc.VendorId == vendor_intel) {
        if (descContains(&desc.Description, "Arc") and !igpu_seen.*) {
            // Intel Arc는 dedicated. iGPU 미존재 시에도 discrete로.
            return .discrete;
        }
        if (!igpu_seen.*) {
            igpu_seen.* = true;
            return .integrated;
        }
        return .discrete;
    }

    // AMD: APU(Radeon Graphics, Vega 8) vs dedicated(RX, R9). description 키워드.
    if (desc.VendorId == vendor_amd) {
        const is_dedicated = descContains(&desc.Description, "RX ") or
            descContains(&desc.Description, "R9 ") or
            descContains(&desc.Description, "R7 ") or
            descContains(&desc.Description, "FirePro");
        if (!is_dedicated and !igpu_seen.*) {
            igpu_seen.* = true;
            return .integrated;
        }
        return .discrete;
    }

    // NVIDIA: 거의 모두 dedicated.
    if (desc.VendorId == vendor_nvidia) return .discrete;

    return .discrete;
}

fn descContains(desc: *const [128]u16, ascii_needle: []const u8) bool {
    var i: usize = 0;
    while (i + ascii_needle.len <= desc.len) : (i += 1) {
        var match = true;
        for (ascii_needle, 0..) |c, k| {
            if (desc[i + k] != c) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn looksLikeRemote(desc: *const [128]u16) bool {
    // "Remote" / "Microsoft Remote Display" 등을 감지.
    const needle = "Remote";
    var i: usize = 0;
    while (i + needle.len <= desc.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |c, k| {
            if (desc[i + k] != c) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}
