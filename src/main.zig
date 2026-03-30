// src/main.zig
const std = @import("std");
const parser = @import("config/parser.zig");
const Scheduler = @import("engine/scheduler.zig").Scheduler;
const Worker = @import("engine/worker.zig").Worker;
const worker_mod = @import("engine/worker.zig");
const collector_mod = @import("metrics/collector.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: reqbench <scenario.toml>\n", .{});
        std.process.exit(1);
    }

    const toml_src = try std.fs.cwd().readFileAlloc(allocator, args[1], 1024 * 1024);
    defer allocator.free(toml_src);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const sc = parser.parseScenario(toml_src, arena.allocator()) catch |e| {
        std.debug.print("Error parsing {s}: {}\n", .{ args[1], e });
        std.process.exit(1);
    };

    var sched = try Scheduler.init(sc.endpoints, allocator);
    defer sched.deinit(allocator);

    var ring = collector_mod.MetricsRing{};
    const stats = try allocator.alloc(collector_mod.EndpointStats, sc.endpoints.len);
    defer allocator.free(stats);
    for (stats) |*s| s.* = .{};

    var coll = collector_mod.Collector.init(&ring, stats);
    const coll_thread = try coll.spawn();

    var state = std.atomic.Value(worker_mod.State).init(.running);
    const n = sc.defaults.concurrency;
    const workers = try allocator.alloc(Worker, n);
    defer allocator.free(workers);
    for (workers, 0..) |*w, i| {
        w.* = try Worker.spawn(.{
            .id = @intCast(i),
            .endpoints = sc.endpoints,
            .defaults = &sc.defaults,
            .scheduler = &sched,
            .ring = &ring,
            .state = &state,
        });
    }

    const duration_ns = sc.defaults.duration_ns orelse 10 * std.time.ns_per_s;
    std.Thread.sleep(duration_ns);
    state.store(.stopped, .release);
    for (workers) |*w| w.join();
    coll.stop();
    coll_thread.join();

    // stdout サマリー
    const stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.print("\n=== {s} ===\n\n", .{sc.name});
    try stdout.print("{s:<20} {s:>8} {s:>8} {s:>8} {s:>8} {s:>8}\n", .{ "Endpoint", "Count", "RPS", "p50", "p95", "p99" });
    const elapsed_sec = @as(f64, @floatFromInt(duration_ns)) / 1e9;
    for (sc.endpoints, 0..) |ep, i| {
        const st = &stats[i];
        const rps = @as(f64, @floatFromInt(st.count)) / elapsed_sec;
        const p50 = st.histogram.percentile(50.0) / 1_000_000;
        const p95 = st.histogram.percentile(95.0) / 1_000_000;
        const p99 = st.histogram.percentile(99.0) / 1_000_000;
        try stdout.print("{s:<20} {d:>8} {d:>8.1} {d:>7}ms {d:>7}ms {d:>7}ms\n", .{ ep.name, st.count, rps, p50, p95, p99 });
    }
}

test {
    _ = @import("config/scenario.zig");
    _ = @import("utils/ring_buffer.zig");
    _ = @import("utils/time.zig");
    _ = @import("metrics/histogram.zig");
    _ = @import("metrics/collector.zig");
    _ = @import("metrics/timeseries.zig");
    _ = @import("http/request.zig");
    _ = @import("http/response.zig");
    _ = @import("http/client.zig");
    _ = @import("engine/scheduler.zig");
    _ = @import("engine/controller.zig");
    _ = @import("config/env.zig");
    _ = @import("config/parser.zig");
    _ = @import("engine/worker.zig");
    _ = @import("tui/input.zig");
    _ = @import("tui/widgets.zig");
    _ = @import("tui/layout.zig");
    _ = @import("tui/render.zig");
    _ = @import("report/json.zig");
    _ = @import("report/csv.zig");
    _ = @import("report/compare.zig");
}
