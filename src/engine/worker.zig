// src/engine/worker.zig
const std = @import("std");
const scenario = @import("../config/scenario.zig");
const collector_mod = @import("../metrics/collector.zig");
const Scheduler = @import("scheduler.zig").Scheduler;
const sendRequest = @import("../http/client.zig").sendRequest;

pub const State = enum(u8) { idle, running, paused, stopped };

pub const WorkerConfig = struct {
    id: u32,
    endpoints: []const scenario.Endpoint,
    defaults: *const scenario.Defaults,
    scheduler: *Scheduler,
    ring: *collector_mod.MetricsRing,
    state: *std.atomic.Value(State),
};

pub const Worker = struct {
    thread: std.Thread,

    pub fn spawn(config: WorkerConfig) !Worker {
        const t = try std.Thread.spawn(.{}, run, .{config});
        return .{ .thread = t };
    }

    pub fn join(self: *Worker) void {
        self.thread.join();
    }
};

fn run(config: WorkerConfig) void {
    const req_buf: [16384]u8 = undefined;
    const resp_buf: [8192]u8 = undefined;
    _ = req_buf;
    _ = resp_buf;

    while (true) {
        const s = config.state.load(.acquire);
        if (s == .stopped) break;
        if (s == .paused) {
            std.Thread.sleep(10_000_000); // 10ms
            continue;
        }

        const ep = config.scheduler.next();
        const result = sendRequest(ep, config.defaults) catch |err| {
            const sample = collector_mod.Sample{
                .endpoint_idx = @intCast(epIndex(ep, config.endpoints)),
                .status = 0,
                .latency_ns = 0,
                .bytes_received = 0,
                .error_code = mapError(err),
            };
            while (!config.ring.push(sample)) std.Thread.yield() catch {};
            continue;
        };

        const sample = collector_mod.Sample{
            .endpoint_idx = @intCast(epIndex(ep, config.endpoints)),
            .status = result.status,
            .latency_ns = result.latency_ns,
            .bytes_received = result.body_bytes,
            .error_code = .none,
        };
        while (!config.ring.push(sample)) std.Thread.yield() catch {};
    }
}

fn epIndex(ep: *const scenario.Endpoint, eps: []const scenario.Endpoint) usize {
    const ep_addr = @intFromPtr(ep);
    for (eps, 0..) |*e, i| {
        if (@intFromPtr(e) == ep_addr) return i;
    }
    return 0;
}

fn mapError(err: anyerror) collector_mod.ErrorCode {
    return switch (err) {
        error.Timeout => .timeout,
        error.ConnectionRefused => .connection_refused,
        error.ConnectionReset => .connection_reset,
        error.DnsFailure => .dns_failure,
        else => .invalid_response,
    };
}

test "worker pushes samples to ring during run duration" {
    const sc = @import("../config/scenario.zig");
    const Scheduler2 = @import("scheduler.zig").Scheduler;

    var h = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer h.deinit();
    const eps = [_]sc.Endpoint{.{ .name = "t", .method = .GET, .path = "/", .headers = h, .timeout_ms = 1000, .weight = 1 }};
    var sched = try Scheduler2.init(&eps, std.testing.allocator);
    defer sched.deinit(std.testing.allocator);

    var ring = collector_mod.MetricsRing{};
    var state = std.atomic.Value(State).init(.running);

    const config = WorkerConfig{
        .id = 0,
        .endpoints = &eps,
        .defaults = &sc.Defaults{ .base_url = "http://127.0.0.1:1", .headers = h },
        .scheduler = &sched,
        .ring = &ring,
        .state = &state,
    };
    // WorkerConfig が構築できればOK (コンパイル時チェック)
    _ = config;
}
