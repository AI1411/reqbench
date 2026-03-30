// src/tui/render.zig
const std = @import("std");
const widgets = @import("widgets.zig");
const layout_mod = @import("layout.zig");
const collector_mod = @import("../metrics/collector.zig");
const scenario = @import("../config/scenario.zig");

const REFRESH_NS = std.time.ns_per_s / 10; // 10Hz

pub const RenderContext = struct {
    stats: []const collector_mod.EndpointStats,
    endpoints: []const scenario.Endpoint,
    running: *std.atomic.Value(bool),
    elapsed_ns: *std.atomic.Value(u64),
    total_duration_ns: u64,
    selected_ep: usize = 0,
};

pub fn spawn(ctx: *RenderContext) !std.Thread {
    return std.Thread.spawn(.{}, loop, .{ctx});
}

fn loop(ctx: *RenderContext) void {
    const stdout = std.io.getStdOut();
    var bw = std.io.bufferedWriter(stdout.writer());
    const w = bw.writer();

    widgets.hideCursor(w) catch {};

    while (ctx.running.load(.acquire)) {
        widgets.clearScreen(w) catch {};
        draw(w, ctx) catch {};
        bw.flush() catch {};
        std.Thread.sleep(REFRESH_NS);
    }

    widgets.showCursor(w) catch {};
    bw.flush() catch {};
}

fn draw(w: anytype, ctx: *RenderContext) !void {
    const ts = layout_mod.getTermSize();
    const elapsed = ctx.elapsed_ns.load(.monotonic);
    const pct = @min(100.0, @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(ctx.total_duration_ns)) * 100.0);

    // ヘッダー
    try widgets.moveTo(w, 1, 1);
    try w.print("reqbench  Elapsed: {d:.1}s  [{d:.0}%]", .{
        @as(f64, @floatFromInt(elapsed)) / 1e9, pct,
    });

    // エンドポイントテーブル
    try widgets.moveTo(w, 3, 1);
    try w.print("{s:<20} {s:>8} {s:>8} {s:>8} {s:>8} {s:>6}\n", .{
        "Endpoint", "RPS", "p50", "p95", "p99", "Err%",
    });
    try w.writeAll("─" ** 60 ++ "\r\n");

    const elapsed_sec = @as(f64, @floatFromInt(@max(elapsed, 1))) / 1e9;
    for (ctx.endpoints, 0..) |ep, i| {
        const st = &ctx.stats[i];
        const rps = @as(f64, @floatFromInt(st.count)) / elapsed_sec;
        const err_pct = if (st.count > 0)
            @as(f64, @floatFromInt(st.error_count)) / @as(f64, @floatFromInt(st.count)) * 100.0
        else
            0.0;
        const marker: u8 = if (i == ctx.selected_ep) '>' else ' ';
        try w.print("{c}{s:<19} {d:>8.1} {d:>7}ms {d:>7}ms {d:>7}ms {d:>5.1}%\r\n", .{
            marker,
            ep.name,
            rps,
            st.histogram.percentile(50.0) / 1_000_000,
            st.histogram.percentile(95.0) / 1_000_000,
            st.histogram.percentile(99.0) / 1_000_000,
            err_pct,
        });
    }

    // フッター
    try widgets.moveTo(w, ts.rows, 1);
    try w.writeAll("[q] 終了  [p] 一時停止  [↑↓] 選択  [r] リセット");
}

test "render context can be constructed" {
    const sc = @import("../config/scenario.zig");
    var h = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer h.deinit();
    const eps = [_]sc.Endpoint{.{
        .name = "test",
        .method = .GET,
        .path = "/",
        .headers = h,
        .timeout_ms = 5000,
    }};
    var stats = [_]collector_mod.EndpointStats{.{}};
    var running = std.atomic.Value(bool).init(false);
    var elapsed_ns = std.atomic.Value(u64).init(0);

    const ctx = RenderContext{
        .stats = &stats,
        .endpoints = &eps,
        .running = &running,
        .elapsed_ns = &elapsed_ns,
        .total_duration_ns = 10 * std.time.ns_per_s,
    };
    try std.testing.expectEqual(@as(usize, 0), ctx.selected_ep);
}
