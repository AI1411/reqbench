// src/config/scenario.zig
const std = @import("std");

pub const Method = enum { GET, POST, PUT, PATCH, DELETE, HEAD };
pub const BodyType = enum { json, form, raw };
pub const ReportFormat = enum { json, csv };

pub const Body = struct {
    type: BodyType,
    data: []const u8,
};

pub const Endpoint = struct {
    name: []const u8,
    method: Method,
    path: []const u8,
    weight: u32 = 1,
    headers: std.StringHashMap([]const u8),
    body: ?Body = null,
    timeout_ms: u32,
};

pub const Defaults = struct {
    base_url: []const u8,
    timeout_ms: u32 = 5000,
    concurrency: u32 = 50,
    duration_ns: ?u64 = null,
    request_count: ?u64 = null,
    headers: std.StringHashMap([]const u8),
};

pub const ReportConfig = struct {
    formats: []const ReportFormat,
    output_dir: []const u8,
    compare_with: ?[]const u8 = null,
};

pub const Scenario = struct {
    name: []const u8,
    description: []const u8 = "",
    defaults: Defaults,
    endpoints: []Endpoint,
    report: ?ReportConfig = null,
};

test "Endpoint default weight is 1" {
    const ep = Endpoint{
        .name = "test",
        .method = .GET,
        .path = "/health",
        .headers = std.StringHashMap([]const u8).init(std.testing.allocator),
        .timeout_ms = 5000,
    };
    try std.testing.expectEqual(@as(u32, 1), ep.weight);
}

test "Defaults duration and request_count are mutually exclusive" {
    var d = Defaults{
        .base_url = "http://localhost:8080",
        .headers = std.StringHashMap([]const u8).init(std.testing.allocator),
    };
    d.duration_ns = 30 * std.time.ns_per_s;
    try std.testing.expect(d.request_count == null);
}
