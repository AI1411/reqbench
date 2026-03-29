const std = @import("std");

pub const ParseDurationError = error{InvalidDuration};

pub fn parseDuration(s: []const u8) ParseDurationError!u64 {
    if (s.len < 2) return error.InvalidDuration;

    const suffix_len: usize = if (std.mem.endsWith(u8, s, "ms")) 2 else 1;
    const num_str = s[0 .. s.len - suffix_len];
    if (num_str.len == 0) return error.InvalidDuration;
    const num = std.fmt.parseInt(u64, num_str, 10) catch return error.InvalidDuration;

    const multiplier: u64 = if (suffix_len == 2)
        std.time.ns_per_ms
    else switch (s[s.len - 1]) {
        's' => std.time.ns_per_s,
        'm' => std.time.ns_per_min,
        'h' => std.time.ns_per_hour,
        else => return error.InvalidDuration,
    };
    return std.math.mul(u64, num, multiplier) catch return error.InvalidDuration;
}

test "parseDuration: 30s" {
    try std.testing.expectEqual(@as(u64, 30_000_000_000), try parseDuration("30s"));
}
test "parseDuration: 5m" {
    try std.testing.expectEqual(@as(u64, 300_000_000_000), try parseDuration("5m"));
}
test "parseDuration: 1h" {
    try std.testing.expectEqual(@as(u64, 3_600_000_000_000), try parseDuration("1h"));
}
test "parseDuration: 500ms" {
    try std.testing.expectEqual(@as(u64, 500_000_000), try parseDuration("500ms"));
}
test "parseDuration: invalid" {
    try std.testing.expectError(error.InvalidDuration, parseDuration("abc"));
}
