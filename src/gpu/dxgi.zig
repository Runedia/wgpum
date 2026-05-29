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
    label: [24:0]u8, // 표시 이름: "RTX 4080 SUPER", "Radeon(TM)" (실패 시 GPU0, GPU1, ...)
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
                .label = std.mem.zeroes([24:0]u8),
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

        // 라벨링: description에서 친화 이름 추출 ("RTX 4080 SUPER", "Radeon(TM)").
        // 추출 실패(빈 문자열) 시 GPU0, GPU1, ... 폴백.
        for (self.adapters[0..self.count], 0..) |*a, idx| {
            buildLabel(a, idx);
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

const vendor_intel: u32 = 0x8086;
const vendor_amd: u32 = 0x1002;
const vendor_nvidia: u32 = 0x10DE;

/// description(UTF-16)에서 작업바용 짧은 이름을 뽑아 a.label에 쓴다.
/// 추출 결과가 비면 "GPU{idx}"로 폴백. (검증: test_label.zig)
fn buildLabel(a: *Adapter, idx: usize) void {
    var u8desc: [256]u8 = undefined;
    const dlen = std.mem.indexOfScalar(u16, &a.description, 0) orelse a.description.len;
    const dn = std.unicode.utf16LeToUtf8(&u8desc, a.description[0..dlen]) catch 0;

    var name: [24]u8 = undefined;
    const nl = friendlyName(a.vendor_id, u8desc[0..dn], &name);

    if (nl == 0) {
        _ = std.fmt.bufPrint(&a.label, "GPU{d}", .{idx}) catch {};
        return;
    }
    @memcpy(a.label[0..nl], name[0..nl]);
    a.label[nl] = 0;
}

/// vendor + UTF-8 description에서 짧은 이름 추출. out에 쓰고 길이 반환.
/// - NVIDIA "NVIDIA GeForce RTX 4080 SUPER" -> "RTX 4080 SUPER"
/// - AMD    "AMD Radeon(TM) Graphics"       -> "Radeon(TM)"
/// - Intel  "Intel(R) Arc(TM) A770 Graphics" -> "Arc(TM) A770"
fn friendlyName(vendor: u32, utf8: []const u8, out: []u8) usize {
    var s = utf8;

    if (vendor == vendor_nvidia) {
        if (std.mem.indexOf(u8, s, "RTX")) |i| {
            s = s[i..];
        } else if (std.mem.indexOf(u8, s, "GTX")) |i| {
            s = s[i..];
        } else if (std.mem.indexOf(u8, s, "GeForce")) |i| {
            s = trimLeadingSpace(s["GeForce".len + i ..]);
        }
        s = stripSuffix(s, " Laptop GPU");
        s = stripSuffix(s, " with Max-Q Design");
        // 모델 등급 접미사 축약: "RTX 4080 SUPER" -> "RTX 4080", "RTX 5060 Ti" -> "RTX 5060".
        // "RTX 4070 Ti SUPER"처럼 둘 다 붙는 경우를 위해 SUPER -> Ti 순으로 제거.
        s = stripSuffix(s, " SUPER");
        s = stripSuffix(s, " Ti");
    } else if (vendor == vendor_amd) {
        if (std.mem.indexOf(u8, s, "Radeon")) |i| s = s[i..];
        s = stripSuffix(s, " Graphics");
    } else if (vendor == vendor_intel) {
        s = stripPrefix(s, "Intel(R) ");
        s = stripPrefix(s, "Intel ");
        s = stripSuffix(s, " Graphics");
    }

    const n = @min(s.len, out.len);
    @memcpy(out[0..n], s[0..n]);
    return n;
}

fn trimLeadingSpace(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and s[i] == ' ') : (i += 1) {}
    return s[i..];
}

fn stripSuffix(s: []const u8, suffix: []const u8) []const u8 {
    if (std.mem.endsWith(u8, s, suffix)) return s[0 .. s.len - suffix.len];
    return s;
}

fn stripPrefix(s: []const u8, prefix: []const u8) []const u8 {
    if (std.mem.startsWith(u8, s, prefix)) return s[prefix.len..];
    return s;
}

/// VendorId + description 기반 어댑터 분류.
/// DedicatedVideoMemory는 AMD iGPU에서 비정상 보고되므로 임계치로 사용 불가.
fn classifyAdapter(desc: *const DXGI.DXGI_ADAPTER_DESC1, igpu_seen: *bool) AdapterRole {
    // DXGI_ADAPTER_FLAG_SOFTWARE = 2
    if ((desc.Flags & 0x2) != 0) return .software;
    if (looksLikeRemote(&desc.Description)) return .remote;

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
