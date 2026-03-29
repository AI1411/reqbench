// src/utils/ring_buffer.zig
const std = @import("std");

/// SPSC ロックフリーリングバッファ。capacity は 2^N であること。
/// head: producer側の書き込みカーソル (単調増加)
/// tail: consumer側の読み取りカーソル (単調増加)
pub fn RingBuffer(comptime T: type, comptime capacity: usize) type {
    if (!std.math.isPowerOfTwo(capacity)) @compileError("capacity must be power of 2");
    return struct {
        const Self = @This();
        const mask: usize = capacity - 1;

        buf: [capacity]T align(std.atomic.cache_line) = undefined,
        head: std.atomic.Value(usize) align(std.atomic.cache_line) = .init(0),
        tail: std.atomic.Value(usize) align(std.atomic.cache_line) = .init(0),

        /// Producer が呼ぶ。満杯なら false を返す。
        pub fn push(self: *Self, item: T) bool {
            const h = self.head.load(.monotonic);
            const t = self.tail.load(.acquire);
            if (h - t == capacity - 1) return false; // full (one slot reserved)
            self.buf[h & mask] = item;
            self.head.store(h + 1, .release);
            return true;
        }

        /// Consumer が呼ぶ。空なら null を返す。
        pub fn pop(self: *Self) ?T {
            const t = self.tail.load(.monotonic);
            const h = self.head.load(.acquire);
            if (h == t) return null; // empty
            const item = self.buf[t & mask];
            self.tail.store(t + 1, .release);
            return item;
        }

        pub fn len(self: *Self) usize {
            const h = self.head.load(.acquire);
            const t = self.tail.load(.acquire);
            return h - t;
        }
    };
}

test "push and pop single item" {
    var rb = RingBuffer(u32, 4){};
    try std.testing.expect(rb.push(42));
    try std.testing.expectEqual(@as(?u32, 42), rb.pop());
    try std.testing.expectEqual(@as(?u32, null), rb.pop());
}
test "full buffer rejects push" {
    var rb = RingBuffer(u32, 4){};
    try std.testing.expect(rb.push(1));
    try std.testing.expect(rb.push(2));
    try std.testing.expect(rb.push(3));
    try std.testing.expect(!rb.push(4));
}
test "push pop maintains FIFO order" {
    var rb = RingBuffer(u32, 8){};
    for (0..5) |i| _ = rb.push(@intCast(i));
    for (0..5) |i| try std.testing.expectEqual(@as(?u32, @intCast(i)), rb.pop());
}
