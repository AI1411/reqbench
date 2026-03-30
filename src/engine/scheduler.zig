// src/engine/scheduler.zig
const std = @import("std");
const scenario = @import("../config/scenario.zig");

pub const Scheduler = struct {
    endpoints: []const scenario.Endpoint,
    cum_weights: []u32,
    total_weight: u32,
    counter: std.atomic.Value(u64),

    pub fn init(endpoints: []const scenario.Endpoint, allocator: std.mem.Allocator) !Scheduler {
        const cum = try allocator.alloc(u32, endpoints.len);
        var total: u32 = 0;
        for (endpoints, 0..) |ep, i| {
            total += ep.weight;
            cum[i] = total;
        }
        return .{
            .endpoints = endpoints,
            .cum_weights = cum,
            .total_weight = total,
            .counter = .init(0),
        };
    }

    pub fn deinit(self: *Scheduler, allocator: std.mem.Allocator) void {
        allocator.free(self.cum_weights);
    }

    /// スレッドセーフ。atomic counter + 累積和でO(log N)選択。
    pub fn next(self: *Scheduler) *const scenario.Endpoint {
        const n: u32 = @intCast(self.counter.fetchAdd(1, .monotonic) % self.total_weight);
        // lower_bound: n < cum_weights[i] となる最小 i
        var lo: usize = 0;
        var hi: usize = self.cum_weights.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.cum_weights[mid] <= n) lo = mid + 1 else hi = mid;
        }
        return &self.endpoints[lo];
    }
};

test "single endpoint always returns same" {
    const sc = @import("../config/scenario.zig");
    var h = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer h.deinit();
    const eps = [_]sc.Endpoint{.{ .name = "a", .method = .GET, .path = "/", .headers = h, .timeout_ms = 5000, .weight = 1 }};
    var sched = try Scheduler.init(&eps, std.testing.allocator);
    defer sched.deinit(std.testing.allocator);
    for (0..10) |_| try std.testing.expectEqualStrings("a", sched.next().name);
}

test "weight 3:1 distributes proportionally" {
    const sc = @import("../config/scenario.zig");
    var h = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer h.deinit();
    const eps = [_]sc.Endpoint{
        .{ .name = "heavy", .method = .GET, .path = "/a", .headers = h, .timeout_ms = 5000, .weight = 3 },
        .{ .name = "light", .method = .GET, .path = "/b", .headers = h, .timeout_ms = 5000, .weight = 1 },
    };
    var sched = try Scheduler.init(&eps, std.testing.allocator);
    defer sched.deinit(std.testing.allocator);
    var heavy_count: u32 = 0;
    for (0..400) |_| {
        if (std.mem.eql(u8, sched.next().name, "heavy")) heavy_count += 1;
    }
    // 300/400 = 75% ± 5%
    try std.testing.expect(heavy_count >= 280 and heavy_count <= 320);
}
