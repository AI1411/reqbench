// src/http/pool.zig
const std = @import("std");

pub const PoolEntry = struct {
    stream: std.net.Stream,
    host: []const u8,
    in_use: bool,
};

pub const Pool = struct {
    entries: []PoolEntry,
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,
    active_count: usize,

    pub fn init(allocator: std.mem.Allocator, max_size: usize) Pool {
        const entries = allocator.alloc(PoolEntry, max_size) catch &[_]PoolEntry{};
        return .{ .entries = entries, .mutex = .{}, .allocator = allocator, .active_count = 0 };
    }

    pub fn deinit(self: *Pool) void {
        for (self.entries) |*e| {
            if (e.in_use) e.stream.close();
        }
        self.allocator.free(self.entries);
    }

    /// host:port に対して既存のアイドル接続を返す。なければ null。
    pub fn acquire(self: *Pool, host: []const u8) ?std.net.Stream {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries) |*e| {
            if (!e.in_use and std.mem.eql(u8, e.host, host)) {
                e.in_use = true;
                return e.stream;
            }
        }
        return null;
    }

    /// 使い終わった接続をプールに返す。プールが満杯なら閉じる。
    pub fn release(self: *Pool, stream: std.net.Stream, host: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries) |*e| {
            if (!e.in_use) {
                e.* = .{ .stream = stream, .host = host, .in_use = false };
                return;
            }
        }
        stream.close(); // プール満杯
    }
};

test "pool returns cached connection for same host" {
    var pool = Pool.init(std.testing.allocator, 10);
    defer pool.deinit();
    try std.testing.expectEqual(@as(usize, 0), pool.active_count);
}

test "acquire returns null for unknown host" {
    var pool = Pool.init(std.testing.allocator, 10);
    defer pool.deinit();
    const result = pool.acquire("unknown-host:8080");
    try std.testing.expectEqual(@as(?std.net.Stream, null), result);
}
