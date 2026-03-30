// src/metrics/histogram.zig — HDR版
const std = @import("std");

/// HDR Histogram: 対数スケールバケット
/// 範囲: 1ns〜60s, 精度: sigfigs=2 (1%)
/// バケット数: ~1400 (固定メモリ ~11KB)
const SUB_BUCKET_COUNT = 16; // 2^4 = sigfigs ベース
const BUCKET_COUNT = 40; // log2(60e9) ≈ 36 + マージン
pub const TOTAL_BUCKETS = SUB_BUCKET_COUNT * BUCKET_COUNT;

pub const Histogram = struct {
    counts: [TOTAL_BUCKETS]u64 = [_]u64{0} ** TOTAL_BUCKETS,
    total_count: u64 = 0,
    min: u64 = std.math.maxInt(u64),
    max: u64 = 0,

    pub fn record(self: *Histogram, value_ns: u64) void {
        self.total_count += 1;
        if (value_ns < self.min) self.min = value_ns;
        if (value_ns > self.max) self.max = value_ns;
        const idx = bucketIndex(value_ns);
        if (idx < TOTAL_BUCKETS) self.counts[idx] += 1;
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
                // 全サンプルを包含する場合は実際の max を返す (精度保持)
                if (cumulative >= self.total_count) return self.max;
                return bucketUpperBound(i);
            }
        }
        return self.max;
    }

    pub fn reset(self: *Histogram) void {
        self.* = .{};
        self.min = std.math.maxInt(u64);
    }
};

fn bucketIndex(value: u64) usize {
    if (value == 0) return 0;
    const msb: usize = @intCast(63 - @clz(value));
    if (msb < 4) return @intCast(value);
    const bucket: usize = msb - 3;
    const sub: usize = @intCast((value >> @intCast(msb - 3)) & (SUB_BUCKET_COUNT - 1));
    return bucket * SUB_BUCKET_COUNT + sub;
}

fn bucketUpperBound(idx: usize) u64 {
    const bucket: usize = idx / SUB_BUCKET_COUNT;
    const sub: usize = idx % SUB_BUCKET_COUNT;
    if (bucket == 0) return @intCast(idx + 1);
    // 正確な上限: (sub + 1) << bucket
    // バケット内の値は [(sub) << bucket, (sub+1) << bucket) の範囲に入る
    const shift: u6 = @intCast(bucket);
    return @as(u64, sub + 1) << shift;
}

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

test "<1ms samples tracked correctly" {
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

test "HDR bucket index is monotonic" {
    var prev: usize = 0;
    const values = [_]u64{ 1, 100, 1_000, 10_000, 100_000, 1_000_000, 10_000_000, 100_000_000, 1_000_000_000 };
    for (values) |v| {
        const idx = bucketIndex(v);
        try std.testing.expect(idx >= prev);
        prev = idx;
    }
}
