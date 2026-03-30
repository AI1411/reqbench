// src/tui/input.zig
const std = @import("std");

pub const Key = enum { q, p, up, down, r, unknown };

pub fn enableRawMode(fd: std.posix.fd_t) !std.posix.termios {
    const orig = try std.posix.tcgetattr(fd);
    var raw = orig;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 1;
    try std.posix.tcsetattr(fd, .NOW, raw);
    return orig;
}

pub fn disableRawMode(fd: std.posix.fd_t, orig: std.posix.termios) void {
    std.posix.tcsetattr(fd, .NOW, orig) catch {};
}

pub fn readKey(fd: std.posix.fd_t) Key {
    var buf: [4]u8 = undefined;
    const n = std.posix.read(fd, &buf) catch return .unknown;
    if (n == 0) return .unknown;
    return parseKey(buf[0..n]);
}

pub fn readKeyFromReader(reader: anytype) Key {
    var buf: [4]u8 = undefined;
    const n = reader.read(&buf) catch return .unknown;
    if (n == 0) return .unknown;
    return parseKey(buf[0..n]);
}

fn parseKey(buf: []const u8) Key {
    return switch (buf[0]) {
        'q' => .q,
        'p' => .p,
        'r' => .r,
        '\x1b' => if (buf.len >= 3 and buf[1] == '[') switch (buf[2]) {
            'A' => .up,
            'B' => .down,
            else => .unknown,
        } else .unknown,
        else => .unknown,
    };
}

test "readKey from mock fd: q returns .q" {
    var src: [1]u8 = "q".*;
    var fbs = std.io.fixedBufferStream(&src);
    const key = readKeyFromReader(fbs.reader());
    try std.testing.expectEqual(Key.q, key);
}
