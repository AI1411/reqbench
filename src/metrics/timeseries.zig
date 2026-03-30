// src/metrics/timeseries.zig
const std = @import("std");

/// 直近 N 秒分の RPS を記録するリングバッファ
pub const HISTORY_SEC = 60;
pub const TimeSeries = struct {
    buckets: [HISTORY_SEC]u64 = [_]u64{0} ** HISTORY_SEC,
    current_sec: u64 = 0,
    current_count: u64 = 0,
    mutex: std.Thread.Mutex = .{},

    pub fn record(self: *TimeSeries) void {
        const now_sec = @as(u64, @intCast(std.time.timestamp()));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (now_sec != self.current_sec) {
            self.buckets[self.current_sec % HISTORY_SEC] = self.current_count;
            self.current_sec = now_sec;
            self.current_count = 0;
        }
        self.current_count += 1;
    }

    pub fn snapshot(self: *TimeSeries, out: *[HISTORY_SEC]f64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.buckets, 0..) |v, i| out[i] = @floatFromInt(v);
    }
};

test "record increments count" {
    var ts = TimeSeries{};
    ts.record();
    ts.record();
    try std.testing.expect(ts.current_count == 2);
}
