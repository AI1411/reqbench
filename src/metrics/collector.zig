// src/metrics/collector.zig
const std = @import("std");
const RingBuffer = @import("../utils/ring_buffer.zig").RingBuffer;
const Histogram = @import("histogram.zig").Histogram;

pub const ErrorCode = enum(u8) {
    none = 0,
    timeout,
    connection_refused,
    connection_reset,
    dns_failure,
    tls_error,
    invalid_response,
};

pub const Sample = struct {
    endpoint_idx: u16,
    status: u16,
    latency_ns: u64,
    bytes_received: u32,
    error_code: ErrorCode,
    _pad: [6]u8 = undefined,

    comptime {
        // 64バイト境界に収まることを確認
        std.debug.assert(@sizeOf(Sample) <= 64);
    }
};

pub const EndpointStats = struct {
    count: u64 = 0,
    error_count: u64 = 0,
    bytes_total: u64 = 0,
    histogram: Histogram = .{},
    status_codes: [600]u32 = [_]u32{0} ** 600,
};

pub const MetricsRing = RingBuffer(Sample, 65536);

pub const Collector = struct {
    ring: *MetricsRing,
    stats: []EndpointStats,
    running: std.atomic.Value(bool),

    pub fn init(ring: *MetricsRing, stats: []EndpointStats) Collector {
        return .{
            .ring = ring,
            .stats = stats,
            .running = .init(false),
        };
    }

    pub fn spawn(self: *Collector) !std.Thread {
        self.running.store(true, .release);
        return std.Thread.spawn(.{}, loop, .{self});
    }

    pub fn stop(self: *Collector) void {
        self.running.store(false, .release);
    }

    fn loop(self: *Collector) void {
        while (self.running.load(.acquire)) {
            while (self.ring.pop()) |sample| processOne(self.stats, sample);
            std.Thread.yield() catch {};
        }
        while (self.ring.pop()) |sample| processOne(self.stats, sample);
    }
};

pub fn processOne(stats: []EndpointStats, s: Sample) void {
    const st = &stats[s.endpoint_idx];
    st.count += 1;
    if (s.error_code != .none) st.error_count += 1;
    st.bytes_total += s.bytes_received;
    st.histogram.record(s.latency_ns);
    if (s.status < 600) st.status_codes[s.status] += 1;
}

test "process increments count" {
    var stats = [1]EndpointStats{.{}};
    const sample = Sample{ .endpoint_idx = 0, .status = 200, .latency_ns = 5_000_000, .bytes_received = 1024, .error_code = .none };
    processOne(&stats, sample);
    try std.testing.expectEqual(@as(u64, 1), stats[0].count);
    try std.testing.expectEqual(@as(u64, 0), stats[0].error_count);
}

test "process counts errors" {
    var stats = [1]EndpointStats{.{}};
    const sample = Sample{ .endpoint_idx = 0, .status = 0, .latency_ns = 1_000_000, .bytes_received = 0, .error_code = .timeout };
    processOne(&stats, sample);
    try std.testing.expectEqual(@as(u64, 1), stats[0].error_count);
}
