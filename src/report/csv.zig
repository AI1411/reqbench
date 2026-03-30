// src/report/csv.zig
const std = @import("std");
const collector_mod = @import("../metrics/collector.zig");
const scenario = @import("../config/scenario.zig");

pub fn writeHeader(w: anytype) !void {
    try w.writeAll("timestamp_ns,endpoint,method,status,latency_us,bytes,error\n");
}

pub fn writeSample(w: anytype, s: collector_mod.Sample, sc: scenario.Scenario, ts_ns: u64) !void {
    const ep = &sc.endpoints[s.endpoint_idx];
    try w.print("{d},{s},{s},{d},{d},{d},{s}\n", .{
        ts_ns,
        ep.name,
        @tagName(ep.method),
        s.status,
        s.latency_ns / 1000,
        s.bytes_received,
        @tagName(s.error_code),
    });
}

test "writeHeader produces correct columns" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeHeader(fbs.writer());
    try std.testing.expectEqualStrings(
        "timestamp_ns,endpoint,method,status,latency_us,bytes,error\n",
        fbs.getWritten(),
    );
}

test "writeSample formats correctly" {
    const sc = @import("../config/scenario.zig");
    var h = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer h.deinit();
    var eps = [_]sc.Endpoint{.{
        .name = "test",
        .method = .GET,
        .path = "/",
        .headers = h,
        .timeout_ms = 5000,
    }};
    const scc = sc.Scenario{
        .name = "t",
        .defaults = .{ .base_url = "http://x", .headers = h },
        .endpoints = eps[0..],
    };
    const sample = collector_mod.Sample{
        .endpoint_idx = 0,
        .status = 200,
        .latency_ns = 5_000_000,
        .bytes_received = 1024,
        .error_code = .none,
    };

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeSample(fbs.writer(), sample, scc, 1711700000000000);
    const line = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, line, "test,GET,200,5000,1024,none") != null);
}
