const std = @import("std");
const win32 = @import("win32");

const GDI = win32.graphics.gdi;
const WAM = win32.ui.windows_and_messaging;

const icon_size: i32 = 32;

// SVG와 동일한 색상 팔레트 (BGRA 메모리 순서, 0xAARRGGBB).
const argb_card: u32 = 0xFF1F2937;
const argb_pin: u32 = 0xFFD97706;
const argb_fan_dark: u32 = 0xFF0E7490;
const argb_fan: u32 = 0xFF06B6D4;
const argb_fan_hub: u32 = 0xFFF0F9FF;
const argb_bar1: u32 = 0xFF10B981; // 그린 (낮음)
const argb_bar2: u32 = 0xFFF59E0B; // 앰버 (중간)
const argb_bar3: u32 = 0xFFEF4444; // 레드 (높음)

/// 32×32 ARGB DIB에 GPU + 막대그래프 아이콘을 직접 그려 HICON으로 반환한다.
/// 외부 ICO 파일/이미지 변환 도구 없이 빌드 시점에 코드로 임베드.
pub fn create() ?WAM.HICON {
    var bmi = std.mem.zeroes(GDI.BITMAPINFO);
    bmi.bmiHeader.biSize = @sizeOf(GDI.BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = icon_size;
    bmi.bmiHeader.biHeight = -icon_size; // top-down
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = GDI.BI_RGB;

    var bits_raw: ?*anyopaque = null;
    const color_bmp = GDI.CreateDIBSection(null, &bmi, GDI.DIB_RGB_COLORS, &bits_raw, null, 0) orelse return null;
    defer _ = GDI.DeleteObject(color_bmp);

    const bits: [*]u32 = @ptrCast(@alignCast(bits_raw.?));
    drawIcon(bits, icon_size);

    // 1-bit 마스크 비트맵 (모두 0). ARGB color bitmap의 알파 채널이 실제 투명도 결정.
    var mask_bytes = [_]u8{0} ** ((icon_size * icon_size) / 8);
    const mask_bmp = GDI.CreateBitmap(icon_size, icon_size, 1, 1, &mask_bytes);
    defer {
        if (mask_bmp) |b| _ = GDI.DeleteObject(b);
    }

    var info = WAM.ICONINFO{
        .fIcon = 1,
        .xHotspot = 0,
        .yHotspot = 0,
        .hbmMask = mask_bmp,
        .hbmColor = color_bmp,
    };
    return WAM.CreateIconIndirect(&info);
}

fn drawIcon(bits: [*]u32, size: i32) void {
    // 투명 배경 (alpha=0).
    @memset(bits[0..@as(usize, @intCast(size * size))], 0);

    // GPU 카드 본체 (좌측 영역 꽉 채움).
    fillRect(bits, size, 2, 10, 18, 25, argb_card);
    // PCIe 브래킷 (보드 좌측 위/아래로 튀어나옴).
    fillRect(bits, size, 0, 9, 2, 11, argb_card);
    fillRect(bits, size, 0, 24, 2, 26, argb_card);
    // PCIe 골드 핀 (보드 하단).
    fillRect(bits, size, 4, 26, 14, 27, argb_pin);

    // 팬 (카드 안): 외곽 어두운 + 안쪽 시안.
    fillCircle(bits, size, 10, 17, 5, argb_fan_dark);
    fillCircle(bits, size, 10, 17, 4, argb_fan);

    // 회전 블레이드 3개 (120도 간격, 카드 색 음각).
    // 12시, 4시, 8시 방향에 각각 짧은 라인.
    fillRect(bits, size, 10, 13, 10, 14, argb_card); // 12시 끝
    fillRect(bits, size, 11, 15, 11, 15, argb_card); // 12시 휨
    fillRect(bits, size, 13, 19, 13, 19, argb_card); // 4시 끝
    fillRect(bits, size, 12, 18, 12, 18, argb_card); // 4시 휨
    fillRect(bits, size, 7, 19, 7, 19, argb_card); // 8시 끝
    fillRect(bits, size, 8, 18, 8, 18, argb_card); // 8시 휨

    // 중심 허브.
    fillCircle(bits, size, 10, 17, 1, argb_card);

    // 사용률 막대 (우측 영역 꽉 채움, 낮음 → 높음).
    fillRect(bits, size, 20, 21, 22, 25, argb_bar1);
    fillRect(bits, size, 24, 14, 26, 25, argb_bar2);
    fillRect(bits, size, 28, 6, 30, 25, argb_bar3);
}

fn fillRect(bits: [*]u32, w: i32, x0: i32, y0: i32, x1: i32, y1: i32, argb: u32) void {
    var y = y0;
    while (y <= y1) : (y += 1) {
        var x = x0;
        while (x <= x1) : (x += 1) {
            if (x >= 0 and x < w and y >= 0 and y < w) {
                bits[@intCast(y * w + x)] = argb;
            }
        }
    }
}

fn fillCircle(bits: [*]u32, w: i32, cx: i32, cy: i32, r: i32, argb: u32) void {
    var y: i32 = cy - r;
    while (y <= cy + r) : (y += 1) {
        var x: i32 = cx - r;
        while (x <= cx + r) : (x += 1) {
            const dx = x - cx;
            const dy = y - cy;
            if (dx * dx + dy * dy <= r * r) {
                if (x >= 0 and x < w and y >= 0 and y < w) {
                    bits[@intCast(y * w + x)] = argb;
                }
            }
        }
    }
}
