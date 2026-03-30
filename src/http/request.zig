// src/http/request.zig
const std = @import("std");
const scenario = @import("../config/scenario.zig");

pub const BuildError = error{BufferTooSmall};

/// host:port を base_url から抽出 ("http://localhost:8080" → "localhost:8080")
pub fn extractHost(base_url: []const u8) []const u8 {
    const after_scheme = if (std.mem.indexOf(u8, base_url, "://")) |i| base_url[i + 3 ..] else base_url;
    if (std.mem.indexOfScalar(u8, after_scheme, '/')) |i| return after_scheme[0..i];
    return after_scheme;
}

/// Host / Content-Length / Connection は自動生成するため、ユーザー指定ヘッダから除外する
fn isReservedHeader(key: []const u8) bool {
    return std.ascii.eqlIgnoreCase(key, "host") or
        std.ascii.eqlIgnoreCase(key, "content-length") or
        std.ascii.eqlIgnoreCase(key, "connection");
}

/// ep.headers に同名キー（大小無視）が存在するか確認する
fn epHasKey(ep_headers: *const std.StringHashMap([]const u8), key: []const u8) bool {
    var it = ep_headers.iterator();
    while (it.next()) |kv| {
        if (std.ascii.eqlIgnoreCase(kv.key_ptr.*, key)) return true;
    }
    return false;
}

pub fn buildRequest(
    ep: *const scenario.Endpoint,
    defaults: *const scenario.Defaults,
    buf: []u8,
) BuildError![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();

    w.print("{s} {s} HTTP/1.1\r\n", .{ @tagName(ep.method), ep.path }) catch return error.BufferTooSmall;
    w.print("Host: {s}\r\n", .{extractHost(defaults.base_url)}) catch return error.BufferTooSmall;
    w.writeAll("Connection: close\r\n") catch return error.BufferTooSmall;

    // defaults.headers を出力。ただし予約ヘッダおよび ep.headers に同名キーがある場合はスキップ
    var it = defaults.headers.iterator();
    while (it.next()) |kv| {
        if (isReservedHeader(kv.key_ptr.*)) continue;
        if (epHasKey(&ep.headers, kv.key_ptr.*)) continue;
        w.print("{s}: {s}\r\n", .{ kv.key_ptr.*, kv.value_ptr.* }) catch return error.BufferTooSmall;
    }
    // ep.headers を出力。予約ヘッダはスキップ
    var it2 = ep.headers.iterator();
    while (it2.next()) |kv| {
        if (isReservedHeader(kv.key_ptr.*)) continue;
        w.print("{s}: {s}\r\n", .{ kv.key_ptr.*, kv.value_ptr.* }) catch return error.BufferTooSmall;
    }

    if (ep.body) |body| {
        w.print("Content-Length: {d}\r\n\r\n", .{body.data.len}) catch return error.BufferTooSmall;
        w.writeAll(body.data) catch return error.BufferTooSmall;
    } else {
        w.writeAll("\r\n") catch return error.BufferTooSmall;
    }

    return fbs.getWritten();
}

test "buildRequest: GET with no body ends with CRLF" {
    var headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer headers.deinit();
    const ep = scenario.Endpoint{
        .name = "test",
        .method = .GET,
        .path = "/api/v1/users",
        .headers = headers,
        .timeout_ms = 5000,
    };
    var defaults_headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer defaults_headers.deinit();
    const defaults = scenario.Defaults{
        .base_url = "http://localhost:8080",
        .headers = defaults_headers,
    };
    var buf: [4096]u8 = undefined;
    const req = try buildRequest(&ep, &defaults, &buf);
    try std.testing.expect(std.mem.endsWith(u8, req, "\r\n\r\n"));
    try std.testing.expect(std.mem.startsWith(u8, req, "GET /api/v1/users HTTP/1.1\r\n"));
}

test "buildRequest: POST with body includes Content-Length" {
    var headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer headers.deinit();
    const ep = scenario.Endpoint{
        .name = "test",
        .method = .POST,
        .path = "/api/v1/users",
        .headers = headers,
        .body = scenario.Body{ .type = .json, .data = "{\"name\":\"alice\"}" },
        .timeout_ms = 5000,
    };
    var defaults_headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer defaults_headers.deinit();
    const defaults = scenario.Defaults{
        .base_url = "http://localhost:8080",
        .headers = defaults_headers,
    };
    var buf: [4096]u8 = undefined;
    const req = try buildRequest(&ep, &defaults, &buf);
    try std.testing.expect(std.mem.startsWith(u8, req, "POST /api/v1/users HTTP/1.1\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, req, "Content-Length: 16\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, req, "{\"name\":\"alice\"}"));
}

test "buildRequest: Host header uses extractHost" {
    var headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer headers.deinit();
    const ep = scenario.Endpoint{
        .name = "test",
        .method = .GET,
        .path = "/health",
        .headers = headers,
        .timeout_ms = 5000,
    };
    var defaults_headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer defaults_headers.deinit();
    const defaults = scenario.Defaults{
        .base_url = "https://example.com:9000",
        .headers = defaults_headers,
    };
    var buf: [4096]u8 = undefined;
    const req = try buildRequest(&ep, &defaults, &buf);
    try std.testing.expect(std.mem.indexOf(u8, req, "Host: example.com:9000\r\n") != null);
}

test "buildRequest: BufferTooSmall error when buffer is insufficient" {
    var headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer headers.deinit();
    const ep = scenario.Endpoint{
        .name = "test",
        .method = .GET,
        .path = "/api/v1/users",
        .headers = headers,
        .timeout_ms = 5000,
    };
    var defaults_headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer defaults_headers.deinit();
    const defaults = scenario.Defaults{
        .base_url = "http://localhost:8080",
        .headers = defaults_headers,
    };
    var buf: [10]u8 = undefined;
    const result = buildRequest(&ep, &defaults, &buf);
    try std.testing.expectError(error.BufferTooSmall, result);
}

test "extractHost: removes scheme and path" {
    try std.testing.expectEqualStrings("localhost:8080", extractHost("http://localhost:8080"));
    try std.testing.expectEqualStrings("localhost:8080", extractHost("http://localhost:8080/api"));
    try std.testing.expectEqualStrings("example.com", extractHost("https://example.com/path"));
    try std.testing.expectEqualStrings("example.com:443", extractHost("https://example.com:443"));
    try std.testing.expectEqualStrings("localhost", extractHost("localhost"));
}

test "buildRequest: endpoint headers override defaults" {
    var ep_headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer ep_headers.deinit();
    try ep_headers.put("X-Custom", "value");
    // defaults と同名キー: ep 側の値が優先される
    try ep_headers.put("Authorization", "Bearer ep-token");

    const ep = scenario.Endpoint{
        .name = "test",
        .method = .GET,
        .path = "/api",
        .headers = ep_headers,
        .timeout_ms = 5000,
    };
    var defaults_headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer defaults_headers.deinit();
    try defaults_headers.put("Authorization", "Bearer default-token");
    try defaults_headers.put("X-Tenant", "acme");

    const defaults = scenario.Defaults{
        .base_url = "http://localhost:8080",
        .headers = defaults_headers,
    };
    var buf: [4096]u8 = undefined;
    const req = try buildRequest(&ep, &defaults, &buf);
    // ep 側の値のみ出力されること
    try std.testing.expect(std.mem.indexOf(u8, req, "Authorization: Bearer ep-token\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "Authorization: Bearer default-token\r\n") == null);
    // defaults 固有のヘッダは出力されること
    try std.testing.expect(std.mem.indexOf(u8, req, "X-Tenant: acme\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "X-Custom: value\r\n") != null);
}

test "buildRequest: reserved headers in user input are ignored" {
    var ep_headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer ep_headers.deinit();
    try ep_headers.put("Host", "evil.com");
    try ep_headers.put("Content-Length", "999");
    try ep_headers.put("Connection", "keep-alive");

    const ep = scenario.Endpoint{
        .name = "test",
        .method = .POST,
        .path = "/api",
        .headers = ep_headers,
        .body = scenario.Body{ .type = .json, .data = "hello" },
        .timeout_ms = 5000,
    };
    var defaults_headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer defaults_headers.deinit();
    try defaults_headers.put("host", "also-evil.com");

    const defaults = scenario.Defaults{
        .base_url = "http://localhost:8080",
        .headers = defaults_headers,
    };
    var buf: [4096]u8 = undefined;
    const req = try buildRequest(&ep, &defaults, &buf);
    // 自動生成された Host のみ出力され、ユーザー指定のものは無視される
    try std.testing.expect(std.mem.indexOf(u8, req, "Host: localhost:8080\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "evil.com") == null);
    // Content-Length はボディ長から自動計算される
    try std.testing.expect(std.mem.indexOf(u8, req, "Content-Length: 5\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "Content-Length: 999") == null);
    // Connection: close のみ出力
    try std.testing.expect(std.mem.indexOf(u8, req, "Connection: close\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "Connection: keep-alive") == null);
}
