// src/http/response.zig
const std = @import("std");

pub const ParseResult = struct {
    status: u16,
    body_bytes: u32,
};

pub const ParseError = error{ InvalidResponse, BufferTooSmall };

/// ヘッダーを読み取りステータスとボディサイズを返す。ボディは読み捨て。
pub fn parseFromReader(reader: anytype, buf: *[8192]u8) anyerror!ParseResult {
    // ヘッダーブロックを読む (\r\n\r\n まで)
    var header_end: usize = 0;
    var total_read: usize = 0;
    while (total_read < buf.len) {
        const b = reader.readByte() catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        buf[total_read] = b;
        total_read += 1;
        if (total_read >= 4 and
            buf[total_read - 4] == '\r' and buf[total_read - 3] == '\n' and
            buf[total_read - 2] == '\r' and buf[total_read - 1] == '\n')
        {
            header_end = total_read;
            break;
        }
    }
    if (header_end == 0) return error.InvalidResponse;

    const headers = buf[0..header_end];

    // ステータスライン: "HTTP/1.1 200 OK\r\n"
    const status_line_end = std.mem.indexOf(u8, headers, "\r\n") orelse return error.InvalidResponse;
    const status_line = headers[0..status_line_end];
    if (status_line.len < 12) return error.InvalidResponse;
    const status = std.fmt.parseInt(u16, status_line[9..12], 10) catch return error.InvalidResponse;

    // Content-Length と Transfer-Encoding を探す
    var body_bytes: u32 = 0;
    var lines = std.mem.splitSequence(u8, headers[status_line_end + 2 ..], "\r\n");
    while (lines.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const val = std.mem.trim(u8, line[15..], " ");
            body_bytes = std.fmt.parseInt(u32, val, 10) catch 0;
        } else if (std.ascii.startsWithIgnoreCase(line, "transfer-encoding:")) {
            // chunked など Content-Length 不明なボディは未サポート
            return error.InvalidResponse;
        }
    }

    // ボディ読み捨て
    var discarded: u32 = 0;
    var discard_buf: [4096]u8 = undefined;
    while (discarded < body_bytes) {
        const to_read = @min(discard_buf.len, body_bytes - discarded);
        const n = reader.read(discard_buf[0..to_read]) catch break;
        if (n == 0) break;
        discarded += @intCast(n);
    }
    // ボディが途中で切断された場合はエラー
    if (discarded < body_bytes) return error.InvalidResponse;

    return .{ .status = status, .body_bytes = body_bytes };
}

test "parse status 200 from header" {
    const raw = "HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\nHello, World!";
    var fbs = std.io.fixedBufferStream(raw);
    var buf: [8192]u8 = undefined;
    const result = try parseFromReader(fbs.reader(), &buf);
    try std.testing.expectEqual(@as(u16, 200), result.status);
    try std.testing.expectEqual(@as(u32, 13), result.body_bytes);
}

test "parse status 404" {
    const raw = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";
    var fbs = std.io.fixedBufferStream(raw);
    var buf: [8192]u8 = undefined;
    const result = try parseFromReader(fbs.reader(), &buf);
    try std.testing.expectEqual(@as(u16, 404), result.status);
}

test "truncated body returns InvalidResponse" {
    // Content-Length: 20 だがボディは 5 バイトしかない
    const raw = "HTTP/1.1 200 OK\r\nContent-Length: 20\r\n\r\nHello";
    var fbs = std.io.fixedBufferStream(raw);
    var buf: [8192]u8 = undefined;
    try std.testing.expectError(error.InvalidResponse, parseFromReader(fbs.reader(), &buf));
}

test "transfer-encoding chunked returns InvalidResponse" {
    const raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nHello\r\n0\r\n\r\n";
    var fbs = std.io.fixedBufferStream(raw);
    var buf: [8192]u8 = undefined;
    try std.testing.expectError(error.InvalidResponse, parseFromReader(fbs.reader(), &buf));
}
