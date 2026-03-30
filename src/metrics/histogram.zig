// src/metrics/histogram.zig
const std = @import("std");

/// シンプルな線形バケットヒストグラム (Phase 1用)
/// バケット: 0-1ms, 1-2ms, 2-5ms, 5-10ms, 10-20ms, 20-50ms, 50-100ms, 100ms+
/// 精度より実装シンプルさを優先。Phase 4でHDR Histogramに置換。
pub const BUCKET_COUNT = 8;
const BUCKET_BOUNDS_NS = [BUCKET_COUNT - 1]u64{
    1_000_000, // 1ms
    2_000_000, // 2ms
    5_000_000, // 5ms
    10_000_000, // 10ms
    20_000_000, // 20ms
    50_000_000, // 50ms
    100_000_000, // 100ms
    // 最後のバケットは 100ms+
};

pub const Histogram = struct {
    counts: [BUCKET_COUNT]u64 = [_]u64{0} ** BUCKET_COUNT,
    total_count: u64 = 0,
    min: u64 = std.math.maxInt(u64),
    max: u64 = 0,

    pub fn record(self: *Histogram, value_ns: u64) void {
        self.total_count += 1;
        if (value_ns < self.min) self.min = value_ns;
        if (value_ns > self.max) self.max = value_ns;
        for (BUCKET_BOUNDS_NS, 0..) |bound, i| {
            if (value_ns < bound) {
                self.counts[i] += 1;
                return;
            }
        }
        self.counts[BUCKET_COUNT - 1] += 1;
    }

    /// p: 0.0〜100.0
    pub fn percentile(self: *const Histogram, p: f64) u64 {
        std.debug.assert(p >= 0.0 and p <= 100.0);
        if (self.total_count == 0) return 0;
        const target = @as(u64, @intFromFloat(@ceil(p / 100.0 * @as(f64, @floatFromInt(self.total_count)))));
        var cumulative: u64 = 0;
        for (self.counts, 0..) |count, i| {
            cumulative += count;
            if (cumulative >= target) {
                // 端点処理: <1ms バケットは min を、100ms+ バケットは max を返す
                if (i == 0) return self.min;
                if (i == BUCKET_COUNT - 1) return self.max;
                return BUCKET_BOUNDS_NS[i - 1];
            }
        }
        return self.max;
    }

    pub fn reset(self: *Histogram) void {
        self.* = .{};
        self.min = std.math.maxInt(u64);
    }
};

test "p50 of uniform distribution" {
    var h = Histogram{};
    for (0..100) |i| h.record(@as(u64, i + 1) * 1_000_000);
    const p50 = h.percentile(50.0);
    try std.testing.expect(p50 >= 45_000_000 and p50 <= 55_000_000);
}

test "min and max are tracked" {
    var h = Histogram{};
    h.record(1_000_000);
    h.record(100_000_000);
    try std.testing.expectEqual(@as(u64, 1_000_000), h.min);
    try std.testing.expectEqual(@as(u64, 100_000_000), h.max);
}

test "reset clears all counts" {
    var h = Histogram{};
    h.record(5_000_000);
    h.reset();
    try std.testing.expectEqual(@as(u64, 0), h.total_count);
}

test "<1ms samples return min not zero" {
    var h = Histogram{};
    h.record(200_000); // 0.2ms
    h.record(500_000); // 0.5ms
    const p50 = h.percentile(50.0);
    try std.testing.expect(p50 > 0);
    try std.testing.expectEqual(@as(u64, 200_000), h.min);
}

test ">100ms samples return max for p99" {
    var h = Histogram{};
    h.record(500_000_000); // 500ms
    const p99 = h.percentile(99.0);
    try std.testing.expectEqual(@as(u64, 500_000_000), p99);
}
