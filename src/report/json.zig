// src/report/json.zig
const std = @import("std");
const scenario = @import("../config/scenario.zig");
const collector_mod = @import("../metrics/collector.zig");

pub fn write(
    sc: scenario.Scenario,
    stats: []const collector_mod.EndpointStats,
    elapsed_ns: u64,
    writer: anytype,
) !void {
    const elapsed_sec = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    var total_req: u64 = 0;
    var total_err: u64 = 0;
    for (stats) |s| {
        total_req += s.count;
        total_err += s.error_count;
    }

    try writer.writeAll("{\n");
    try writer.print("  \"scenario\": \"{s}\",\n", .{sc.name});
    try writer.print("  \"elapsed_sec\": {d:.2},\n", .{elapsed_sec});
    try writer.print(
        "  \"summary\": {{\n    \"total_requests\": {d},\n    \"total_errors\": {d},\n    \"error_rate\": {d:.4}\n  }},\n",
        .{
            total_req,
            total_err,
            if (total_req > 0) @as(f64, @floatFromInt(total_err)) / @as(f64, @floatFromInt(total_req)) else 0.0,
        },
    );

    try writer.writeAll("  \"endpoints\": [\n");
    for (sc.endpoints, 0..) |ep, i| {
        const st = &stats[i];
        const rps = @as(f64, @floatFromInt(st.count)) / elapsed_sec;
        try writer.print(
            "    {{\n      \"name\": \"{s}\",\n      \"method\": \"{s}\",\n      \"path\": \"{s}\",\n" ++
                "      \"count\": {d},\n      \"rps\": {d:.2},\n" ++
                "      \"latency\": {{\"p50_ms\": {d}, \"p95_ms\": {d}, \"p99_ms\": {d}}}\n    }}{s}\n",
            .{
                ep.name,
                @tagName(ep.method),
                ep.path,
                st.count,
                rps,
                st.histogram.percentile(50.0) / 1_000_000,
                st.histogram.percentile(95.0) / 1_000_000,
                st.histogram.percentile(99.0) / 1_000_000,
                if (i < sc.endpoints.len - 1) "," else "",
            },
        );
    }
    try writer.writeAll("  ]\n}\n");
}

test "write produces valid json with endpoint stats" {
    const sc = @import("../config/scenario.zig");
    const collector = @import("../metrics/collector.zig");
    var h = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer h.deinit();
    var endpoints = [_]sc.Endpoint{.{
        .name = "users",
        .method = .GET,
        .path = "/users",
        .headers = h,
        .timeout_ms = 5000,
    }};
    var stats = [_]collector.EndpointStats{.{}};
    stats[0].count = 100;
    stats[0].histogram.record(2_000_000);

    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(std.testing.allocator);
    try write(
        .{
            .name = "test",
            .defaults = .{ .base_url = "http://localhost", .headers = h },
            .endpoints = endpoints[0..],
        },
        &stats,
        10 * std.time.ns_per_s,
        buf.writer(std.testing.allocator),
    );

    const json_str = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"users\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"count\"") != null);
}
