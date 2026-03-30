// src/http/client.zig
const std = @import("std");
const scenario = @import("../config/scenario.zig");
const buildRequest = @import("request.zig").buildRequest;
const parseFromReader = @import("response.zig").parseFromReader;

pub const ClientError = error{
    ConnectionRefused,
    ConnectionReset,
    Timeout,
    InvalidResponse,
    DnsFailure,
    UnsupportedScheme,
};

pub const SendResult = struct {
    status: u16,
    body_bytes: u32,
    latency_ns: u64,
};

/// stream.read() を GenericReader に包んで readByte() を使えるようにする。
/// Zig 0.15 の stream.reader() は新しい Io.Reader を返し GenericReader.readByte() を持たない。
/// GenericReader を経由することで response.zig の parseFromReader が使え、
/// ヘッダーのみスタックバッファにパースしてボディは逐次読み捨てできる（64KiB 制限を解消）。
const StreamGenericReader = std.io.GenericReader(
    std.net.Stream,
    anyerror,
    struct {
        fn read(s: std.net.Stream, buf: []u8) anyerror!usize {
            return s.read(buf);
        }
    }.read,
);

/// SO_RCVTIMEO / SO_SNDTIMEO でソケットの読み書きタイムアウトを設定する
fn setSocketTimeout(stream: std.net.Stream, timeout_ms: u32) !void {
    const tv = std.c.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
    const opt = std.mem.asBytes(&tv);
    try std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, opt);
    try std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, opt);
}

/// base_url からアドレスを解決して接続 → 送受信 → 切断
pub fn sendRequest(ep: *const scenario.Endpoint, defaults: *const scenario.Defaults) ClientError!SendResult {
    const host = extractHostPort(defaults.base_url);

    // HTTPS は未対応。https:// を検出したら早期に返す。
    if (host.is_https) return error.UnsupportedScheme;

    // DNS 対応: tcpConnectToHost はホスト名 (例: "localhost", "api.example.com") を解決して接続する。
    // スタック上の FixedBufferAllocator でアドレスリストを確保し、ヒープアロケーションを回避する。
    var dns_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&dns_buf);

    const timer_start = std.time.nanoTimestamp();
    const stream = std.net.tcpConnectToHost(fba.allocator(), host.host, host.port) catch |e| return switch (e) {
        error.ConnectionRefused => error.ConnectionRefused,
        error.ConnectionTimedOut => error.Timeout,
        else => error.ConnectionReset,
    };
    defer stream.close();

    // タイムアウト設定: ep.timeout_ms を優先し、未設定なら 30 秒を既定値とする。
    const timeout_ms: u32 = if (ep.timeout_ms > 0) ep.timeout_ms else 30000;
    setSocketTimeout(stream, timeout_ms) catch {};

    var req_buf: [16384]u8 = undefined;
    const req = buildRequest(ep, defaults, &req_buf) catch return error.InvalidResponse;
    stream.writeAll(req) catch return error.ConnectionReset;

    // GenericReader でストリームを直接包み、parseFromReader に渡す。
    // ヘッダーのみスタックバッファにパースし、ボディは Content-Length に基づき逐次読み捨てる。
    const reader = StreamGenericReader{ .context = stream };
    var resp_buf: [8192]u8 = undefined;
    const parsed = parseFromReader(reader, &resp_buf) catch |e| return switch (e) {
        error.WouldBlock => error.Timeout,
        else => error.InvalidResponse,
    };
    const latency_ns: u64 = @intCast(std.time.nanoTimestamp() - timer_start);

    return .{ .status = parsed.status, .body_bytes = parsed.body_bytes, .latency_ns = latency_ns };
}

const HostPort = struct { host: []const u8, port: u16, is_https: bool };

fn extractHostPort(base_url: []const u8) HostPort {
    const is_https = std.mem.startsWith(u8, base_url, "https://");
    const default_port: u16 = if (is_https) 443 else 80;
    const after_scheme = if (std.mem.indexOf(u8, base_url, "://")) |i| base_url[i + 3 ..] else base_url;
    const host_part = if (std.mem.indexOfScalar(u8, after_scheme, '/')) |i| after_scheme[0..i] else after_scheme;
    if (std.mem.lastIndexOfScalar(u8, host_part, ':')) |colon| {
        const port = std.fmt.parseInt(u16, host_part[colon + 1 ..], 10) catch default_port;
        return .{ .host = host_part[0..colon], .port = port, .is_https = is_https };
    }
    return .{ .host = host_part, .port = default_port, .is_https = is_https };
}

test "sendRequest returns 200 from mock server" {
    // テスト用に std.net.Server でローカルサーバーを立てる
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    const port = server.listen_address.in.getPort();

    const t = try std.Thread.spawn(.{}, struct {
        fn serve(s: *std.net.Server) void {
            const conn = s.accept() catch return;
            defer conn.stream.close();
            var tmp: [4096]u8 = undefined;
            _ = conn.stream.read(&tmp) catch return;
            _ = conn.stream.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok") catch return;
        }
    }.serve, .{&server});

    const sc = @import("../config/scenario.zig");
    var ep_headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer ep_headers.deinit();
    const ep = sc.Endpoint{ .name = "t", .method = .GET, .path = "/", .headers = ep_headers, .timeout_ms = 1000 };
    var def_headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer def_headers.deinit();
    const base_url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{port});
    defer std.testing.allocator.free(base_url);
    const defaults = sc.Defaults{ .base_url = base_url, .headers = def_headers };

    const result = try sendRequest(&ep, &defaults);
    t.join();
    try std.testing.expectEqual(@as(u16, 200), result.status);
}

test "sendRequest rejects https scheme" {
    var ep_headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer ep_headers.deinit();
    const ep = scenario.Endpoint{ .name = "t", .method = .GET, .path = "/", .headers = ep_headers, .timeout_ms = 1000 };
    var def_headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer def_headers.deinit();
    const defaults = scenario.Defaults{ .base_url = "https://example.com", .headers = def_headers };

    try std.testing.expectError(error.UnsupportedScheme, sendRequest(&ep, &defaults));
}
