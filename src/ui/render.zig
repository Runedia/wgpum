const std = @import("std");
const win32 = @import("win32");

const GDI = win32.graphics.gdi;
const FOUND = win32.foundation;
const WAM = win32.ui.windows_and_messaging;
const W = win32.zig;

const dxgi = @import("../gpu/dxgi.zig");
const pdh = @import("../gpu/pdh.zig");
const window = @import("window.zig");

/// 가로 셀 레이아웃: GPU0 좌측, GPU1/2 우측. 각 셀은 2줄 (라벨+사용률, VRAM).
pub const Renderer = struct {
    font: ?GDI.HFONT = null,
    font_px_height: i32 = 0,
    mem_dc: ?GDI.HDC = null,
    mem_bmp: ?GDI.HBITMAP = null,
    mem_w: i32 = 0,
    mem_h: i32 = 0,
    bg_brush: ?GDI.HBRUSH = null,

    pub fn deinit(self: *Renderer) void {
        if (self.font) |f| _ = GDI.DeleteObject(f);
        if (self.mem_bmp) |b| _ = GDI.DeleteObject(b);
        if (self.mem_dc) |d| _ = GDI.DeleteDC(d);
        if (self.bg_brush) |b| _ = GDI.DeleteObject(b);
        self.* = .{};
    }

    fn ensureFont(self: *Renderer, line_px: i32) void {
        // 한 줄 높이의 80%를 폰트 픽셀 높이로 사용. 너무 작으면 8px 하한.
        const px_height: i32 = @max(8, @divTrunc(line_px * 80, 100));
        if (self.font != null and self.font_px_height == px_height) return;
        if (self.font) |f| _ = GDI.DeleteObject(f);

        const face = W.L("Segoe UI");
        self.font = GDI.CreateFontW(
            -px_height,
            0,
            0,
            0,
            @intFromEnum(GDI.FW_NORMAL),
            0,
            0,
            0,
            @intFromEnum(GDI.DEFAULT_CHARSET),
            .DEFAULT_PRECIS,
            .{},
            .CLEARTYPE_QUALITY,
            .DONTCARE,
            face,
        );
        self.font_px_height = px_height;
    }

    fn ensureBackBuffer(self: *Renderer, hdc: GDI.HDC, w: i32, h: i32) void {
        if (self.mem_dc != null and self.mem_w == w and self.mem_h == h) return;
        if (self.mem_bmp) |b| _ = GDI.DeleteObject(b);
        if (self.mem_dc) |d| _ = GDI.DeleteDC(d);
        self.mem_dc = GDI.CreateCompatibleDC(hdc);
        self.mem_bmp = GDI.CreateCompatibleBitmap(hdc, w, h);
        if (self.mem_dc != null and self.mem_bmp != null) {
            _ = GDI.SelectObject(self.mem_dc, @ptrCast(self.mem_bmp));
        }
        self.mem_w = w;
        self.mem_h = h;
    }

    fn ensureBgBrush(self: *Renderer) void {
        if (self.bg_brush != null) return;
        // 색상 키와 동일한 색으로 채우면 layered window가 투명 처리.
        self.bg_brush = GDI.CreateSolidBrush(window.color_key);
    }

    /// WM_PAINT 핸들러에서 호출. 어댑터별 사용률(0..100) + VRAM을 가로 셀로 표시.
    pub fn paint(
        self: *Renderer,
        hwnd: FOUND.HWND,
        adapters: *const dxgi.AdapterSet,
        poll_data: *const pdh.GpuPoll,
    ) void {
        var ps: GDI.PAINTSTRUCT = undefined;
        const hdc = GDI.BeginPaint(hwnd, &ps) orelse return;
        defer _ = GDI.EndPaint(hwnd, &ps);

        self.ensureBgBrush();
        const size = W.getClientSize(hwnd);
        self.ensureBackBuffer(hdc, size.cx, size.cy);
        const dst_dc = self.mem_dc orelse hdc;

        // 배경 = 색상 키 마젠타. layered window가 투명 처리.
        var rect: FOUND.RECT = .{ .left = 0, .top = 0, .right = size.cx, .bottom = size.cy };
        if (self.bg_brush) |br| _ = GDI.FillRect(dst_dc, &rect, br);

        const n: i32 = @intCast(adapters.count);
        if (n <= 0) {
            if (self.mem_dc) |mdc| _ = GDI.BitBlt(hdc, 0, 0, size.cx, size.cy, mdc, 0, 0, GDI.SRCCOPY);
            return;
        }

        // 셀당 3줄: 라벨+사용률 / VRAM / 전력.
        const line_h = @divTrunc(size.cy, 3);
        self.ensureFont(line_h);
        if (self.font) |f| _ = GDI.SelectObject(dst_dc, @ptrCast(f));
        _ = GDI.SetBkMode(dst_dc, GDI.TRANSPARENT);

        const text_color_normal = rgb(0xF0, 0xF0, 0xF0);
        const text_color_warn = rgb(0xFF, 0xC0, 0x4D);
        const text_color_crit = rgb(0xFF, 0x60, 0x60);

        const cell_w = @divTrunc(size.cx, n);

        var buf1: [64]u8 = undefined;
        var buf2: [64]u8 = undefined;
        var buf3: [64]u8 = undefined;
        var wbuf: [64]u16 = undefined;

        for (adapters.adapters[0..adapters.count], 0..) |a, i| {
            if (i >= poll_data.util.len) break;
            const u: f64 = poll_data.util[i];
            const used_bytes = poll_data.vram_used[i];
            const total_bytes = if (poll_data.vram_total[i] != 0) poll_data.vram_total[i] else a.dedicated_total;
            const used_gib: f64 = @as(f64, @floatFromInt(used_bytes)) / (1024.0 * 1024.0 * 1024.0);
            const total_gib: f64 = @as(f64, @floatFromInt(total_bytes)) / (1024.0 * 1024.0 * 1024.0);

            const label_z = std.mem.sliceTo(&a.label, 0);
            const line1 = std.fmt.bufPrint(&buf1, "{s}  {d:>3.0}%", .{ label_z, u }) catch continue;
            const line2 = std.fmt.bufPrint(&buf2, "{d:>4.1} / {d:.1} GiB", .{ used_gib, total_gib }) catch continue;
            const line3 = formatPowerLine(&buf3, poll_data.nvml_power_mw[i], poll_data.nvml_temp_c[i]);

            const color = if (u >= 90.0) text_color_crit else if (u >= 70.0) text_color_warn else text_color_normal;
            const cell_left = @as(i32, @intCast(i)) * cell_w;
            const cell_right = cell_left + cell_w;

            // 1줄: 라벨 + 사용률 (색상 동적).
            _ = GDI.SetTextColor(dst_dc, color);
            drawCenteredLine(dst_dc, line1, &wbuf, cell_left, 0, cell_right, line_h);

            // 2줄: VRAM.
            _ = GDI.SetTextColor(dst_dc, text_color_normal);
            drawCenteredLine(dst_dc, line2, &wbuf, cell_left, line_h, cell_right, line_h * 2);

            // 3줄: 전력 + 온도.
            drawCenteredLine(dst_dc, line3, &wbuf, cell_left, line_h * 2, cell_right, size.cy);
        }

        if (self.mem_dc) |mdc| {
            _ = GDI.BitBlt(hdc, 0, 0, size.cx, size.cy, mdc, 0, 0, GDI.SRCCOPY);
        }
    }
};

/// NVML 결과(전력 mW, 온도 °C)를 표시. 비-NVIDIA 또는 NVML 미동작 시 "—— W —— °C".
fn formatPowerLine(buf: []u8, power_mw: u32, temp_c: u32) []const u8 {
    if (power_mw == 0 and temp_c == 0) {
        return std.fmt.bufPrint(buf, "—— W   —— °C", .{}) catch return buf[0..0];
    }
    const w: f64 = @as(f64, @floatFromInt(power_mw)) / 1000.0;
    return std.fmt.bufPrint(buf, "{d:>3.0} W   {d:>2} °C", .{ w, temp_c }) catch buf[0..0];
}

fn drawCenteredLine(dc: GDI.HDC, utf8: []const u8, wbuf: []u16, left: i32, top: i32, right: i32, bottom: i32) void {
    const wlen = std.unicode.utf8ToUtf16Le(wbuf, utf8) catch return;
    if (wlen >= wbuf.len) return;
    wbuf[wlen] = 0;
    var rect: FOUND.RECT = .{ .left = left, .top = top, .right = right, .bottom = bottom };
    _ = GDI.DrawTextW(
        dc,
        @ptrCast(wbuf.ptr),
        @intCast(wlen),
        &rect,
        .{ .CENTER = 1, .VCENTER = 1, .SINGLELINE = 1 },
    );
}

inline fn rgb(r: u8, g: u8, b: u8) u32 {
    return @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16);
}
