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
};

pub const SendResult = struct {
    status: u16,
    body_bytes: u32,
    latency_ns: u64,
};

/// base_url からアドレスを解決して接続 → 送受信 → 切断
pub fn sendRequest(ep: *const scenario.Endpoint, defaults: *const scenario.Defaults) !SendResult {
    const host = extractHostPort(defaults.base_url);
    const addr = std.net.Address.resolveIp(host.host, host.port) catch
        std.net.Address.parseIp(host.host, host.port) catch
        return error.DnsFailure;

    const timer_start = std.time.nanoTimestamp();
    const stream = std.net.tcpConnectToAddress(addr) catch |e| return switch (e) {
        error.ConnectionRefused => error.ConnectionRefused,
        else => error.ConnectionReset,
    };
    defer stream.close();

    var req_buf: [16384]u8 = undefined;
    const req = buildRequest(ep, defaults, &req_buf) catch return error.InvalidResponse;
    stream.writeAll(req) catch return error.ConnectionReset;

    // Connection: close なのでサーバーはレスポンス送信後に接続を閉じる。
    // Zig 0.15 の stream.reader() は GenericReader の readByte を持たないため、
    // deprecated の stream.read() で生データを読み取り fixedBufferStream 経由でパースする。
    var resp_raw: [65536]u8 = undefined;
    var total_read: usize = 0;
    while (total_read < resp_raw.len) {
        const n = stream.read(resp_raw[total_read..]) catch break;
        if (n == 0) break;
        total_read += n;
    }
    var fbs = std.io.fixedBufferStream(resp_raw[0..total_read]);
    var resp_buf: [8192]u8 = undefined;
    const parsed = parseFromReader(fbs.reader(), &resp_buf) catch return error.InvalidResponse;
    const latency_ns: u64 = @intCast(std.time.nanoTimestamp() - timer_start);

    return .{ .status = parsed.status, .body_bytes = parsed.body_bytes, .latency_ns = latency_ns };
}

const HostPort = struct { host: []const u8, port: u16 };

fn extractHostPort(base_url: []const u8) HostPort {
    const after_scheme = if (std.mem.indexOf(u8, base_url, "://")) |i| base_url[i + 3 ..] else base_url;
    const host_part = if (std.mem.indexOfScalar(u8, after_scheme, '/')) |i| after_scheme[0..i] else after_scheme;
    if (std.mem.lastIndexOfScalar(u8, host_part, ':')) |colon| {
        const port = std.fmt.parseInt(u16, host_part[colon + 1 ..], 10) catch 80;
        return .{ .host = host_part[0..colon], .port = port };
    }
    return .{ .host = host_part, .port = 80 };
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
