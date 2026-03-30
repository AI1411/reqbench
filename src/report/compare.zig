// src/report/compare.zig
const std = @import("std");

pub const Regression = struct {
    endpoint: []const u8,
    metric: []const u8,
    baseline: f64,
    current: f64,
    change_pct: f64,
};

pub const CompareEntry = struct {
    name: []const u8,
    rps: f64,
    p50_ms: f64,
    p95_ms: f64,
    p99_ms: f64,
};

pub fn detect(
    current: []const CompareEntry,
    baseline: []const CompareEntry,
    threshold_pct: f64,
    allocator: std.mem.Allocator,
) ![]Regression {
    var regressions = std.ArrayListUnmanaged(Regression){};
    errdefer regressions.deinit(allocator);
    for (current) |cur| {
        for (baseline) |base| {
            if (!std.mem.eql(u8, cur.name, base.name)) continue;
            try checkMetric(&regressions, allocator, cur.name, "p99", base.p99_ms, cur.p99_ms, threshold_pct);
            try checkMetric(&regressions, allocator, cur.name, "p95", base.p95_ms, cur.p95_ms, threshold_pct);
            // RPS低下検知: current/baseline を逆にして増加として扱う
            try checkMetric(&regressions, allocator, cur.name, "rps", cur.rps, base.rps, threshold_pct);
        }
    }
    return regressions.toOwnedSlice(allocator);
}

fn checkMetric(
    list: *std.ArrayListUnmanaged(Regression),
    allocator: std.mem.Allocator,
    ep: []const u8,
    metric: []const u8,
    baseline: f64,
    current: f64,
    threshold: f64,
) !void {
    if (baseline <= 0.0) return;
    const change = (current - baseline) / baseline * 100.0;
    if (change > threshold) {
        try list.append(allocator, .{
            .endpoint = ep,
            .metric = metric,
            .baseline = baseline,
            .current = current,
            .change_pct = change,
        });
    }
}

test "detect p99 regression above threshold" {
    const current = [_]CompareEntry{.{ .name = "api", .rps = 1000, .p50_ms = 2, .p95_ms = 8, .p99_ms = 30 }};
    const baseline = [_]CompareEntry{.{ .name = "api", .rps = 1000, .p50_ms = 2, .p95_ms = 8, .p99_ms = 20 }};
    const regs = try detect(&current, &baseline, 10.0, std.testing.allocator);
    defer std.testing.allocator.free(regs);
    try std.testing.expectEqual(@as(usize, 1), regs.len);
    try std.testing.expectEqualStrings("p99", regs[0].metric);
}

test "detect no regression within threshold" {
    const current = [_]CompareEntry{.{ .name = "api", .rps = 1000, .p50_ms = 2, .p95_ms = 8, .p99_ms = 21 }};
    const baseline = [_]CompareEntry{.{ .name = "api", .rps = 1000, .p50_ms = 2, .p95_ms = 8, .p99_ms = 20 }};
    const regs = try detect(&current, &baseline, 10.0, std.testing.allocator);
    defer std.testing.allocator.free(regs);
    try std.testing.expectEqual(@as(usize, 0), regs.len);
}

test "detect rps regression" {
    const current = [_]CompareEntry{.{ .name = "api", .rps = 800, .p50_ms = 2, .p95_ms = 8, .p99_ms = 20 }};
    const baseline = [_]CompareEntry{.{ .name = "api", .rps = 1000, .p50_ms = 2, .p95_ms = 8, .p99_ms = 20 }};
    const regs = try detect(&current, &baseline, 10.0, std.testing.allocator);
    defer std.testing.allocator.free(regs);
    try std.testing.expectEqual(@as(usize, 1), regs.len);
    try std.testing.expectEqualStrings("rps", regs[0].metric);
}
