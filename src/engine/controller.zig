// src/engine/controller.zig
const std = @import("std");
const worker_mod = @import("worker.zig");
const collector_mod = @import("../metrics/collector.zig");
const Scheduler = @import("scheduler.zig").Scheduler;
const scenario = @import("../config/scenario.zig");

pub const State = worker_mod.State;

pub const Controller = struct {
    state: std.atomic.Value(State),
    scenario: *const scenario.Scenario,
    sched: Scheduler,
    workers: []worker_mod.Worker,
    collector: collector_mod.Collector,
    coll_thread: std.Thread,
    allocator: std.mem.Allocator,

    pub fn init(
        sc: *const scenario.Scenario,
        ring: *collector_mod.MetricsRing,
        stats: []collector_mod.EndpointStats,
        allocator: std.mem.Allocator,
    ) !Controller {
        const sched = try Scheduler.init(sc.endpoints, allocator);
        const workers = try allocator.alloc(worker_mod.Worker, sc.defaults.concurrency);
        const coll = collector_mod.Collector.init(ring, stats);
        return .{
            .state = .init(.idle),
            .scenario = sc,
            .sched = sched,
            .workers = workers,
            .collector = coll,
            .coll_thread = undefined,
            .allocator = allocator,
        };
    }

    pub fn start(self: *Controller) !void {
        self.coll_thread = try self.collector.spawn();
        self.state.store(.running, .release);
        for (self.workers, 0..) |*w, i| {
            w.* = try worker_mod.Worker.spawn(.{
                .id = @intCast(i),
                .endpoints = self.scenario.endpoints,
                .defaults = &self.scenario.defaults,
                .scheduler = &self.sched,
                .ring = self.collector.ring,
                .state = &self.state,
            });
        }
    }

    pub fn pause(self: *Controller) void {
        self.state.store(.paused, .release);
    }

    pub fn resume_(self: *Controller) void {
        self.state.store(.running, .release);
    }

    pub fn stop(self: *Controller) void {
        self.state.store(.stopped, .release);
        for (self.workers) |*w| w.join();
        self.collector.stop();
        self.coll_thread.join();
    }

    pub fn deinit(self: *Controller) void {
        self.sched.deinit(self.allocator);
        self.allocator.free(self.workers);
    }
};

test "controller init succeeds" {
    const sc = @import("../config/scenario.zig");
    var h = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer h.deinit();
    var eps = [_]sc.Endpoint{.{
        .name = "test",
        .method = .GET,
        .path = "/",
        .headers = h,
        .timeout_ms = 5000,
        .weight = 1,
    }};
    const scenario_val = sc.Scenario{
        .name = "test",
        .defaults = .{
            .base_url = "http://localhost:8080",
            .headers = h,
            .concurrency = 1,
        },
        .endpoints = eps[0..],
    };

    var ring = collector_mod.MetricsRing{};
    const stats = try std.testing.allocator.alloc(collector_mod.EndpointStats, eps.len);
    defer std.testing.allocator.free(stats);
    for (stats) |*s| s.* = .{};

    var ctrl = try Controller.init(&scenario_val, &ring, stats, std.testing.allocator);
    defer ctrl.deinit();

    try std.testing.expectEqual(State.idle, ctrl.state.load(.acquire));
}
