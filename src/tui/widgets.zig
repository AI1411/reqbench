// src/tui/widgets.zig
const std = @import("std");

pub fn moveTo(w: anytype, row: u16, col: u16) !void {
    try w.print("\x1b[{d};{d}H", .{ row, col });
}

pub fn clearScreen(w: anytype) !void {
    try w.writeAll("\x1b[2J\x1b[H");
}

pub fn hideCursor(w: anytype) !void {
    try w.writeAll("\x1b[?25l");
}

pub fn showCursor(w: anytype) !void {
    try w.writeAll("\x1b[?25h");
}

/// value/max の割合を width 文字で描画 ('▓' で塗りつぶし)
pub fn barChart(w: anytype, value: f64, max: f64, width: u16) !void {
    const filled: u16 = if (max <= 0.0) 0 else @intFromFloat(@round(value / max * @as(f64, @floatFromInt(width))));
    const safe_filled = @min(filled, width);
    for (0..safe_filled) |_| try w.writeAll("▓");
    for (safe_filled..width) |_| try w.writeByte(' ');
}

/// テーブル行: cells を widths 幅で左揃え出力
pub fn tableRow(w: anytype, cells: []const []const u8, widths: []const u16) !void {
    for (cells, 0..) |cell, i| {
        const ww = if (i < widths.len) widths[i] else 10;
        try w.print("{s:<[1]}", .{ cell, ww });
        try w.writeByte(' ');
    }
    try w.writeAll("\r\n");
}

/// ASCII 折れ線グラフ (data: RPS値の配列, rows/cols: 描画領域サイズ)
pub fn lineGraph(w: anytype, data: []const f64, rows: u16, cols: u16, start_row: u16, start_col: u16) !void {
    if (data.len == 0 or rows == 0 or cols == 0) return;
    var max_val: f64 = 1.0;
    for (data) |v| if (v > max_val) {
        max_val = v;
    };

    // 描画用グリッド
    var grid = try std.heap.page_allocator.alloc(u8, rows * cols);
    defer std.heap.page_allocator.free(grid);
    @memset(grid, ' ');

    const step = if (data.len > cols) data.len / cols else 1;
    var col_i: u16 = 0;
    var di: usize = 0;
    while (di < data.len and col_i < cols) : ({
        di += step;
        col_i += 1;
    }) {
        const normalized = data[di] / max_val;
        const row_i: u16 = @intFromFloat(@round((1.0 - normalized) * @as(f64, @floatFromInt(rows - 1))));
        grid[@as(usize, row_i) * cols + col_i] = '*';
    }

    for (0..rows) |r| {
        try moveTo(w, start_row + @as(u16, @intCast(r)), start_col);
        try w.writeAll(grid[r * cols .. r * cols + cols]);
    }
}

test "barChart 50% of width 10 produces 5 filled chars" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try barChart(fbs.writer(), 50.0, 100.0, 10);
    const written = fbs.getWritten();
    // '▓' は 3バイト (UTF-8)、5個 = 15バイト、残り5個はスペース
    try std.testing.expectEqual(@as(usize, 15 + 5), written.len);
}

test "moveTo writes correct escape sequence" {
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try moveTo(fbs.writer(), 5, 10);
    try std.testing.expectEqualStrings("\x1b[5;10H", fbs.getWritten());
}
