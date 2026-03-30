// src/config/parser.zig
const std = @import("std");
const scenario = @import("scenario.zig");
const time_utils = @import("../utils/time.zig");

pub const ParseError = error{ MissingField, InvalidFormat, OutOfMemory };

/// 超シンプルなTOMLパーサー。Phase 1では key = "value" と [[arrays]] のみ対応。
/// zig-toml ライブラリ追加は Phase 2 で検討。
pub fn parseScenario(toml_src: []const u8, allocator: std.mem.Allocator) ParseError!scenario.Scenario {
    var endpoints = std.ArrayListUnmanaged(scenario.Endpoint){};
    errdefer endpoints.deinit(allocator);
    var name: []const u8 = "unnamed";
    var base_url: []const u8 = "";
    var concurrency: u32 = 50;
    var duration_ns: ?u64 = null;
    var timeout_ms: u32 = 5000;

    var lines = std.mem.splitScalar(u8, toml_src, '\n');
    var in_endpoint = false;
    var cur_ep_name: []const u8 = "";
    var cur_ep_method: scenario.Method = .GET;
    var cur_ep_path: []const u8 = "/";
    var cur_ep_weight: u32 = 1;

    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;

        if (std.mem.eql(u8, line, "[[endpoints]]")) {
            if (in_endpoint and cur_ep_path.len > 0) {
                try endpoints.append(allocator, .{
                    .name = cur_ep_name,
                    .method = cur_ep_method,
                    .path = cur_ep_path,
                    .weight = cur_ep_weight,
                    .headers = std.StringHashMap([]const u8).init(allocator),
                    .timeout_ms = timeout_ms,
                });
            }
            in_endpoint = true;
            cur_ep_name = "";
            cur_ep_path = "/";
            cur_ep_method = .GET;
            cur_ep_weight = 1;
            continue;
        }

        if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
            const key = std.mem.trim(u8, line[0..eq], " ");
            const raw_val = std.mem.trim(u8, line[eq + 1 ..], " ");
            const val = if (raw_val.len >= 2 and raw_val[0] == '"')
                raw_val[1 .. raw_val.len - 1]
            else
                raw_val;

            if (std.mem.eql(u8, key, "name") and !in_endpoint) {
                name = try allocator.dupe(u8, val);
            } else if (std.mem.eql(u8, key, "base_url")) {
                base_url = try allocator.dupe(u8, val);
            } else if (std.mem.eql(u8, key, "concurrency")) {
                concurrency = std.fmt.parseInt(u32, val, 10) catch 50;
            } else if (std.mem.eql(u8, key, "duration")) {
                duration_ns = time_utils.parseDuration(val) catch null;
            } else if (std.mem.eql(u8, key, "timeout_ms")) {
                timeout_ms = std.fmt.parseInt(u32, val, 10) catch 5000;
            } else if (in_endpoint and std.mem.eql(u8, key, "name")) {
                cur_ep_name = try allocator.dupe(u8, val);
            } else if (in_endpoint and std.mem.eql(u8, key, "method")) {
                cur_ep_method = std.meta.stringToEnum(scenario.Method, val) orelse .GET;
            } else if (in_endpoint and std.mem.eql(u8, key, "path")) {
                cur_ep_path = try allocator.dupe(u8, val);
            } else if (in_endpoint and std.mem.eql(u8, key, "weight")) {
                cur_ep_weight = std.fmt.parseInt(u32, val, 10) catch 1;
            }
        }
    }

    if (in_endpoint and cur_ep_path.len > 0) {
        try endpoints.append(allocator, .{
            .name = cur_ep_name,
            .method = cur_ep_method,
            .path = cur_ep_path,
            .weight = cur_ep_weight,
            .headers = std.StringHashMap([]const u8).init(allocator),
            .timeout_ms = timeout_ms,
        });
    }
    if (base_url.len == 0) return error.MissingField;

    return scenario.Scenario{
        .name = name,
        .defaults = .{
            .base_url = base_url,
            .concurrency = concurrency,
            .duration_ns = duration_ns,
            .timeout_ms = timeout_ms,
            .headers = std.StringHashMap([]const u8).init(allocator),
        },
        .endpoints = try endpoints.toOwnedSlice(allocator),
    };
}

test "parse minimal toml" {
    const src =
        \\[defaults]
        \\base_url = "http://localhost:8080"
        \\concurrency = 10
        \\duration = "5s"
        \\
        \\[[endpoints]]
        \\name = "health"
        \\method = "GET"
        \\path = "/health"
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sc = try parseScenario(src, arena.allocator());
    try std.testing.expectEqual(@as(u32, 10), sc.defaults.concurrency);
    try std.testing.expectEqual(@as(usize, 1), sc.endpoints.len);
    try std.testing.expectEqualStrings("health", sc.endpoints[0].name);
}
