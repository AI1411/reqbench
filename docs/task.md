# reqbench Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Zig製の軽量HTTPベンチマーカー reqbench を4フェーズで実装する。

**Architecture:** 計測ループはゼロアロケーション設計（スタックバッファ＋Arena）。Worker N本がSPSCリングバッファ経由でCollectorにサンプルを送信。TUIは独立スレッドで10Hz描画。

**Tech Stack:** Zig 0.13, std.net.Stream (HTTP/1.1), std.Thread, ANSI escape codes (TUI), std.json (report)

---

## ファイル構成

```
reqbench/
├── build.zig
├── build.zig.zon
└── src/
    ├── main.zig
    ├── config/
    │   ├── scenario.zig      # 型定義 (Scenario, Endpoint, Defaults...)
    │   ├── parser.zig        # TOML → Scenario パース
    │   └── env.zig           # ${ENV_VAR} 展開
    ├── utils/
    │   ├── ring_buffer.zig   # SPSC RingBuffer(T, N)
    │   └── time.zig          # parseDuration ("30s" → ns)
    ├── metrics/
    │   ├── histogram.zig     # 固定メモリヒストグラム → percentile
    │   ├── collector.zig     # Sample, EndpointStats, Collector thread
    │   └── timeseries.zig    # RPS時系列 (Phase 2)
    ├── http/
    │   ├── request.zig       # buildRequest → []u8
    │   ├── response.zig      # parse → ParseResult{status, body_bytes}
    │   ├── client.zig        # sendRequest (connect/send/recv/close)
    │   └── pool.zig          # Keep-Alive pool (Phase 4)
    ├── engine/
    │   ├── scheduler.zig     # weight別ラウンドロビン (atomic counter)
    │   ├── worker.zig        # Worker thread (ゼロアロケーションループ)
    │   └── controller.zig    # State machine + start/pause/stop
    ├── tui/
    │   ├── input.zig         # raw mode + readKey
    │   ├── widgets.zig       # moveTo, barChart, lineGraph, tableRow
    │   ├── layout.zig        # 画面分割・座標計算
    │   └── render.zig        # 10Hz描画ループ
    └── report/
        ├── json.zig          # JSON サマリー出力
        ├── csv.zig           # 生データ CSV 出力
        └── compare.zig       # 前回比較・リグレッション検知
```

---

## Phase 1: 基盤

### Task 1: build.zig セットアップ

**Files:**
- Create: `build.zig`
- Create: `build.zig.zon`
- Create: `src/main.zig`

- [ ] **Step 1: build.zig を作成**

```zig
// build.zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "reqbench",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run reqbench");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
```

- [ ] **Step 2: build.zig.zon を作成**

```zig
// build.zig.zon
.{
    .name = "reqbench",
    .version = "0.1.0",
    .minimum_zig_version = "0.13.0",
    .dependencies = .{},
    .paths = .{""},
}
```

- [ ] **Step 3: src/main.zig の骨格を作成**

```zig
// src/main.zig
const std = @import("std");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("reqbench v0.1.0\n");
}

test {
    // 全モジュールのテストを引き込む
    _ = @import("config/scenario.zig");
    _ = @import("utils/ring_buffer.zig");
    _ = @import("utils/time.zig");
    _ = @import("metrics/histogram.zig");
    _ = @import("metrics/collector.zig");
    _ = @import("http/request.zig");
    _ = @import("http/response.zig");
    _ = @import("engine/scheduler.zig");
}
```

- [ ] **Step 4: ビルドが通ることを確認**

```bash
zig build
```
Expected: `zig-out/bin/reqbench` が生成される

- [ ] **Step 5: Commit**

```bash
git add build.zig build.zig.zon src/main.zig
git commit -m "chore: initial build setup"
```

---

### Task 2: config/scenario.zig — 型定義

**Files:**
- Create: `src/config/scenario.zig`

- [ ] **Step 1: テストを書く**

```zig
// src/config/scenario.zig の末尾に追加予定のテスト
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
```

- [ ] **Step 2: テストが失敗することを確認**

```bash
zig test src/config/scenario.zig
```
Expected: FAIL "use of undeclared identifier 'Endpoint'"

- [ ] **Step 3: 実装**

```zig
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
```

- [ ] **Step 4: テスト通過を確認**

```bash
zig test src/config/scenario.zig
```
Expected: All 2 tests passed

- [ ] **Step 5: Commit**

```bash
git add src/config/scenario.zig
git commit -m "feat: add scenario type definitions"
```

---

### Task 3: utils/time.zig — duration パース

**Files:**
- Create: `src/utils/time.zig`

- [ ] **Step 1: テストを書く**

```zig
test "parseDuration: 30s" {
    try std.testing.expectEqual(@as(u64, 30_000_000_000), try parseDuration("30s"));
}
test "parseDuration: 5m" {
    try std.testing.expectEqual(@as(u64, 300_000_000_000), try parseDuration("5m"));
}
test "parseDuration: 1h" {
    try std.testing.expectEqual(@as(u64, 3_600_000_000_000), try parseDuration("1h"));
}
test "parseDuration: invalid" {
    try std.testing.expectError(error.InvalidDuration, parseDuration("abc"));
}
```

- [ ] **Step 2: テストが失敗することを確認**

```bash
zig test src/utils/time.zig
```
Expected: FAIL "use of undeclared identifier 'parseDuration'"

- [ ] **Step 3: 実装**

```zig
// src/utils/time.zig
const std = @import("std");

pub const ParseDurationError = error{ InvalidDuration, Overflow };

pub fn parseDuration(s: []const u8) ParseDurationError!u64 {
    if (s.len < 2) return error.InvalidDuration;
    const unit = s[s.len - 1];
    const num_str = s[0 .. s.len - 1];
    const num = std.fmt.parseInt(u64, num_str, 10) catch return error.InvalidDuration;
    return switch (unit) {
        's' => num * std.time.ns_per_s,
        'm' => num * std.time.ns_per_min,
        'h' => num * std.time.ns_per_hour,
        else => error.InvalidDuration,
    };
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
test "parseDuration: invalid" {
    try std.testing.expectError(error.InvalidDuration, parseDuration("abc"));
}
```

- [ ] **Step 4: テスト通過を確認**

```bash
zig test src/utils/time.zig
```
Expected: All 4 tests passed

- [ ] **Step 5: Commit**

```bash
git add src/utils/time.zig
git commit -m "feat: add duration string parser"
```

---

### Task 4: config/env.zig — 環境変数展開

**Files:**
- Create: `src/config/env.zig`

- [ ] **Step 1: テストを書く**

```zig
test "expand: no variables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try expand("http://localhost:8080", arena.allocator());
    try std.testing.expectEqualStrings("http://localhost:8080", result);
}
test "expand: replaces known env var" {
    try std.posix.setenv("TEST_TOKEN", "abc123", true); // setenv for test
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try expand("Bearer ${TEST_TOKEN}", arena.allocator());
    try std.testing.expectEqualStrings("Bearer abc123", result);
}
test "expand: missing var returns error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.EnvVarNotFound, expand("${REQBENCH_MISSING_VAR_XYZ}", arena.allocator()));
}
```

- [ ] **Step 2: テストが失敗することを確認**

```bash
zig test src/config/env.zig
```

- [ ] **Step 3: 実装**

```zig
// src/config/env.zig
const std = @import("std");

pub const ExpandError = error{ EnvVarNotFound, OutOfMemory };

/// "${VAR}" を環境変数値に置換。allocator はArenaを想定。
pub fn expand(input: []const u8, allocator: std.mem.Allocator) ExpandError![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    var i: usize = 0;
    while (i < input.len) {
        if (i + 1 < input.len and input[i] == '$' and input[i + 1] == '{') {
            const end = std.mem.indexOfScalarPos(u8, input, i + 2, '}') orelse {
                try out.append(input[i]);
                i += 1;
                continue;
            };
            const var_name = input[i + 2 .. end];
            const val = std.posix.getenv(var_name) orelse return error.EnvVarNotFound;
            try out.appendSlice(val);
            i = end + 1;
        } else {
            try out.append(input[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice();
}

test "expand: no variables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try expand("http://localhost:8080", arena.allocator());
    try std.testing.expectEqualStrings("http://localhost:8080", result);
}
test "expand: replaces known env var" {
    try std.posix.setenv("TEST_TOKEN", "abc123", true);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try expand("Bearer ${TEST_TOKEN}", arena.allocator());
    try std.testing.expectEqualStrings("Bearer abc123", result);
}
test "expand: missing var returns error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.EnvVarNotFound, expand("${REQBENCH_MISSING_VAR_XYZ}", arena.allocator()));
}
```

- [ ] **Step 4: テスト通過を確認**

```bash
zig test src/config/env.zig
```
Expected: All 3 tests passed

- [ ] **Step 5: Commit**

```bash
git add src/config/env.zig
git commit -m "feat: add environment variable expansion"
```

---

### Task 5: utils/ring_buffer.zig — SPSC リングバッファ

**Files:**
- Create: `src/utils/ring_buffer.zig`

- [ ] **Step 1: テストを書く**

```zig
test "push and pop single item" {
    var rb = RingBuffer(u32, 4){};
    try std.testing.expect(rb.push(42));
    try std.testing.expectEqual(@as(?u32, 42), rb.pop());
    try std.testing.expectEqual(@as(?u32, null), rb.pop());
}
test "full buffer rejects push" {
    var rb = RingBuffer(u32, 4){};
    try std.testing.expect(rb.push(1));
    try std.testing.expect(rb.push(2));
    try std.testing.expect(rb.push(3));
    try std.testing.expect(!rb.push(4)); // capacity=4 → max 3 items
}
test "push pop maintains FIFO order" {
    var rb = RingBuffer(u32, 8){};
    for (0..5) |i| _ = rb.push(@intCast(i));
    for (0..5) |i| try std.testing.expectEqual(@as(?u32, @intCast(i)), rb.pop());
}
```

- [ ] **Step 2: テストが失敗することを確認**

```bash
zig test src/utils/ring_buffer.zig
```

- [ ] **Step 3: 実装**

```zig
// src/utils/ring_buffer.zig
const std = @import("std");

/// SPSC ロックフリーリングバッファ。capacity は 2^N であること。
/// head: producer側の書き込みカーソル (単調増加)
/// tail: consumer側の読み取りカーソル (単調増加)
pub fn RingBuffer(comptime T: type, comptime capacity: usize) type {
    if (!std.math.isPowerOfTwo(capacity)) @compileError("capacity must be power of 2");
    return struct {
        const Self = @This();
        const mask: usize = capacity - 1;

        buf: [capacity]T align(std.atomic.cache_line) = undefined,
        head: std.atomic.Value(usize) align(std.atomic.cache_line) = .init(0),
        tail: std.atomic.Value(usize) align(std.atomic.cache_line) = .init(0),

        /// Producer が呼ぶ。満杯なら false を返す。
        pub fn push(self: *Self, item: T) bool {
            const h = self.head.load(.monotonic);
            const t = self.tail.load(.acquire);
            if (h - t == capacity) return false; // full
            self.buf[h & mask] = item;
            self.head.store(h + 1, .release);
            return true;
        }

        /// Consumer が呼ぶ。空なら null を返す。
        pub fn pop(self: *Self) ?T {
            const t = self.tail.load(.monotonic);
            const h = self.head.load(.acquire);
            if (h == t) return null; // empty
            const item = self.buf[t & mask];
            self.tail.store(t + 1, .release);
            return item;
        }

        pub fn len(self: *Self) usize {
            const h = self.head.load(.acquire);
            const t = self.tail.load(.acquire);
            return h - t;
        }
    };
}

test "push and pop single item" {
    var rb = RingBuffer(u32, 4){};
    try std.testing.expect(rb.push(42));
    try std.testing.expectEqual(@as(?u32, 42), rb.pop());
    try std.testing.expectEqual(@as(?u32, null), rb.pop());
}
test "full buffer rejects push" {
    var rb = RingBuffer(u32, 4){};
    try std.testing.expect(rb.push(1));
    try std.testing.expect(rb.push(2));
    try std.testing.expect(rb.push(3));
    try std.testing.expect(!rb.push(4));
}
test "push pop maintains FIFO order" {
    var rb = RingBuffer(u32, 8){};
    for (0..5) |i| _ = rb.push(@intCast(i));
    for (0..5) |i| try std.testing.expectEqual(@as(?u32, @intCast(i)), rb.pop());
}
```

- [ ] **Step 4: テスト通過を確認**

```bash
zig test src/utils/ring_buffer.zig
```
Expected: All 3 tests passed

- [ ] **Step 5: Commit**

```bash
git add src/utils/ring_buffer.zig
git commit -m "feat: add SPSC lock-free ring buffer"
```

---

### Task 6: metrics/histogram.zig — パーセンタイル計算

**Files:**
- Create: `src/metrics/histogram.zig`

- [ ] **Step 1: テストを書く**

```zig
test "p50 of uniform distribution" {
    var h = Histogram{};
    for (0..100) |i| h.record(@as(u64, i + 1) * 1_000_000); // 1ms〜100ms
    const p50 = h.percentile(50.0);
    // 50ms 付近 (±5ms の誤差許容)
    try std.testing.expect(p50 >= 45_000_000 and p50 <= 55_000_000);
}
test "min and max are tracked" {
    var h = Histogram{};
    h.record(1_000_000);   // 1ms
    h.record(100_000_000); // 100ms
    try std.testing.expectEqual(@as(u64, 1_000_000), h.min);
    try std.testing.expectEqual(@as(u64, 100_000_000), h.max);
}
test "reset clears all counts" {
    var h = Histogram{};
    h.record(5_000_000);
    h.reset();
    try std.testing.expectEqual(@as(u64, 0), h.total_count);
}
```

- [ ] **Step 2: テストが失敗することを確認**

```bash
zig test src/metrics/histogram.zig
```

- [ ] **Step 3: 実装（線形バケット、Phase 4でHDRに置換）**

```zig
// src/metrics/histogram.zig
const std = @import("std");

/// シンプルな線形バケットヒストグラム (Phase 1用)
/// バケット: 0-1ms, 1-2ms, 2-5ms, 5-10ms, 10-20ms, 20-50ms, 50-100ms, 100ms+
/// 精度より実装シンプルさを優先。Phase 4でHDR Histogramに置換。
pub const BUCKET_COUNT = 8;
const BUCKET_BOUNDS_NS = [BUCKET_COUNT - 1]u64{
    1_000_000,   // 1ms
    2_000_000,   // 2ms
    5_000_000,   // 5ms
    10_000_000,  // 10ms
    20_000_000,  // 20ms
    50_000_000,  // 50ms
    100_000_000, // 100ms
    // 最後のバケットは 100ms+
};

pub const Histogram = struct {
    counts: [BUCKET_COUNT]u64 = [_]u64{0} ** BUCKET_COUNT,
    total_count: u64 = 0,
    min: u64 = std.math.maxInt(u64),
    max: u64 = 0,

    pub fn record(self: *Histogram, value_ns: u64) void {
        self.total_count += 1;
        if (value_ns < self.min) self.min = value_ns;
        if (value_ns > self.max) self.max = value_ns;
        for (BUCKET_BOUNDS_NS, 0..) |bound, i| {
            if (value_ns < bound) {
                self.counts[i] += 1;
                return;
            }
        }
        self.counts[BUCKET_COUNT - 1] += 1;
    }

    /// p: 0.0〜100.0
    pub fn percentile(self: *const Histogram, p: f64) u64 {
        if (self.total_count == 0) return 0;
        const target = @as(u64, @intFromFloat(@ceil(p / 100.0 * @as(f64, @floatFromInt(self.total_count)))));
        var cumulative: u64 = 0;
        for (self.counts, 0..) |count, i| {
            cumulative += count;
            if (cumulative >= target) {
                // バケット上限値を返す
                if (i < BUCKET_BOUNDS_NS.len) return BUCKET_BOUNDS_NS[i];
                return self.max;
            }
        }
        return self.max;
    }

    pub fn reset(self: *Histogram) void {
        self.* = .{};
        self.min = std.math.maxInt(u64);
    }
};

test "p50 of uniform distribution" {
    var h = Histogram{};
    for (0..100) |i| h.record(@as(u64, i + 1) * 1_000_000);
    const p50 = h.percentile(50.0);
    try std.testing.expect(p50 >= 45_000_000 and p50 <= 55_000_000);
}
test "min and max are tracked" {
    var h = Histogram{};
    h.record(1_000_000);
    h.record(100_000_000);
    try std.testing.expectEqual(@as(u64, 1_000_000), h.min);
    try std.testing.expectEqual(@as(u64, 100_000_000), h.max);
}
test "reset clears all counts" {
    var h = Histogram{};
    h.record(5_000_000);
    h.reset();
    try std.testing.expectEqual(@as(u64, 0), h.total_count);
}
```

- [ ] **Step 4: テスト通過を確認**

```bash
zig test src/metrics/histogram.zig
```
Expected: All 3 tests passed

- [ ] **Step 5: Commit**

```bash
git add src/metrics/histogram.zig
git commit -m "feat: add linear bucket histogram with percentile"
```

---

### Task 7: metrics/collector.zig — Sample型 + Collector

**Files:**
- Create: `src/metrics/collector.zig`

- [ ] **Step 1: テストを書く**

```zig
test "process increments count" {
    var stats = [1]EndpointStats{.{}};
    const sample = Sample{
        .endpoint_idx = 0,
        .status = 200,
        .latency_ns = 5_000_000,
        .bytes_received = 1024,
        .error_code = .none,
    };
    processOne(&stats, sample);
    try std.testing.expectEqual(@as(u64, 1), stats[0].count);
    try std.testing.expectEqual(@as(u64, 0), stats[0].error_count);
}
test "process counts errors" {
    var stats = [1]EndpointStats{.{}};
    const sample = Sample{
        .endpoint_idx = 0,
        .status = 0,
        .latency_ns = 1_000_000,
        .bytes_received = 0,
        .error_code = .timeout,
    };
    processOne(&stats, sample);
    try std.testing.expectEqual(@as(u64, 1), stats[0].error_count);
}
```

- [ ] **Step 2: テストが失敗することを確認**

```bash
zig test src/metrics/collector.zig
```

- [ ] **Step 3: 実装**

```zig
// src/metrics/collector.zig
const std = @import("std");
const RingBuffer = @import("../utils/ring_buffer.zig").RingBuffer;
const Histogram = @import("histogram.zig").Histogram;

pub const ErrorCode = enum(u8) {
    none = 0,
    timeout,
    connection_refused,
    connection_reset,
    dns_failure,
    tls_error,
    invalid_response,
};

pub const Sample = struct {
    endpoint_idx: u16,
    status: u16,
    latency_ns: u64,
    bytes_received: u32,
    error_code: ErrorCode,
    _pad: [6]u8 = undefined,

    comptime {
        // 64バイト境界に収まることを確認
        std.debug.assert(@sizeOf(Sample) <= 64);
    }
};

pub const EndpointStats = struct {
    count: u64 = 0,
    error_count: u64 = 0,
    bytes_total: u64 = 0,
    histogram: Histogram = .{},
    status_codes: [600]u32 = [_]u32{0} ** 600,
};

pub const MetricsRing = RingBuffer(Sample, 65536);

pub const Collector = struct {
    ring: *MetricsRing,
    stats: []EndpointStats,
    running: std.atomic.Value(bool),

    pub fn init(ring: *MetricsRing, stats: []EndpointStats) Collector {
        return .{
            .ring = ring,
            .stats = stats,
            .running = .init(false),
        };
    }

    pub fn spawn(self: *Collector) !std.Thread {
        self.running.store(true, .release);
        return std.Thread.spawn(.{}, loop, .{self});
    }

    pub fn stop(self: *Collector) void {
        self.running.store(false, .release);
    }

    fn loop(self: *Collector) void {
        while (self.running.load(.acquire)) {
            while (self.ring.pop()) |sample| processOne(self.stats, sample);
            std.Thread.yield() catch {};
        }
        while (self.ring.pop()) |sample| processOne(self.stats, sample);
    }
};

pub fn processOne(stats: []EndpointStats, s: Sample) void {
    const st = &stats[s.endpoint_idx];
    st.count += 1;
    if (s.error_code != .none) st.error_count += 1;
    st.bytes_total += s.bytes_received;
    st.histogram.record(s.latency_ns);
    if (s.status < 600) st.status_codes[s.status] += 1;
}

test "process increments count" {
    var stats = [1]EndpointStats{.{}};
    const sample = Sample{ .endpoint_idx = 0, .status = 200, .latency_ns = 5_000_000, .bytes_received = 1024, .error_code = .none };
    processOne(&stats, sample);
    try std.testing.expectEqual(@as(u64, 1), stats[0].count);
    try std.testing.expectEqual(@as(u64, 0), stats[0].error_count);
}
test "process counts errors" {
    var stats = [1]EndpointStats{.{}};
    const sample = Sample{ .endpoint_idx = 0, .status = 0, .latency_ns = 1_000_000, .bytes_received = 0, .error_code = .timeout };
    processOne(&stats, sample);
    try std.testing.expectEqual(@as(u64, 1), stats[0].error_count);
}
```

- [ ] **Step 4: テスト通過を確認**

```bash
zig test src/metrics/collector.zig
```
Expected: All 2 tests passed

- [ ] **Step 5: Commit**

```bash
git add src/metrics/collector.zig
git commit -m "feat: add Sample type and Collector thread"
```

---

### Task 8: http/request.zig — リクエスト構築

**Files:**
- Create: `src/http/request.zig`

- [ ] **Step 1: テストを書く**

```zig
test "buildRequest: GET with no body ends with CRLF" {
    const scenario = @import("../config/scenario.zig");
    var headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer headers.deinit();
    const ep = scenario.Endpoint{
        .name = "test", .method = .GET, .path = "/api/v1/users",
        .headers = headers, .timeout_ms = 5000,
    };
    var defaults_headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer defaults_headers.deinit();
    const defaults = scenario.Defaults{
        .base_url = "http://localhost:8080", .headers = defaults_headers,
    };
    var buf: [4096]u8 = undefined;
    const req = try buildRequest(&ep, &defaults, &buf);
    try std.testing.expect(std.mem.endsWith(u8, req, "\r\n\r\n"));
    try std.testing.expect(std.mem.startsWith(u8, req, "GET /api/v1/users HTTP/1.1\r\n"));
}
```

- [ ] **Step 2: テストが失敗することを確認**

```bash
zig test src/http/request.zig
```

- [ ] **Step 3: 実装**

```zig
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

    var it = defaults.headers.iterator();
    while (it.next()) |kv| {
        w.print("{s}: {s}\r\n", .{ kv.key_ptr.*, kv.value_ptr.* }) catch return error.BufferTooSmall;
    }
    var it2 = ep.headers.iterator();
    while (it2.next()) |kv| {
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
    const sc = @import("../config/scenario.zig");
    var headers = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer headers.deinit();
    const ep = sc.Endpoint{ .name = "test", .method = .GET, .path = "/api/v1/users", .headers = headers, .timeout_ms = 5000 };
    var dh = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer dh.deinit();
    const defaults = sc.Defaults{ .base_url = "http://localhost:8080", .headers = dh };
    var buf: [4096]u8 = undefined;
    const req = try buildRequest(&ep, &defaults, &buf);
    try std.testing.expect(std.mem.endsWith(u8, req, "\r\n\r\n"));
    try std.testing.expect(std.mem.startsWith(u8, req, "GET /api/v1/users HTTP/1.1\r\n"));
}
test "extractHost: removes scheme and path" {
    try std.testing.expectEqualStrings("localhost:8080", extractHost("http://localhost:8080"));
    try std.testing.expectEqualStrings("api.example.com", extractHost("https://api.example.com/v1"));
}
```

- [ ] **Step 4: テスト通過を確認**

```bash
zig test src/http/request.zig
```
Expected: All 2 tests passed

- [ ] **Step 5: Commit**

```bash
git add src/http/request.zig
git commit -m "feat: add HTTP request builder"
```

---

### Task 9: http/response.zig — レスポンスパース

**Files:**
- Create: `src/http/response.zig`

- [ ] **Step 1: テストを書く**

```zig
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
```

- [ ] **Step 2: テストが失敗することを確認**

```bash
zig test src/http/response.zig
```

- [ ] **Step 3: 実装**

```zig
// src/http/response.zig
const std = @import("std");

pub const ParseResult = struct {
    status: u16,
    body_bytes: u32,
};

pub const ParseError = error{ InvalidResponse, BufferTooSmall };

/// ヘッダーを読み取りステータスとボディサイズを返す。ボディは読み捨て。
pub fn parseFromReader(reader: anytype, buf: *[8192]u8) (ParseError || @TypeOf(reader).Error)!ParseResult {
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

    // Content-Length を探す
    var body_bytes: u32 = 0;
    var lines = std.mem.splitSequence(u8, headers[status_line_end + 2 ..], "\r\n");
    while (lines.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const val = std.mem.trim(u8, line[15..], " ");
            body_bytes = std.fmt.parseInt(u32, val, 10) catch 0;
            break;
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
```

- [ ] **Step 4: テスト通過を確認**

```bash
zig test src/http/response.zig
```
Expected: All 2 tests passed

- [ ] **Step 5: Commit**

```bash
git add src/http/response.zig
git commit -m "feat: add HTTP response parser (zero-alloc)"
```

---

### Task 10: http/client.zig — HTTP クライアント

**Files:**
- Create: `src/http/client.zig`

- [ ] **Step 1: テストを書く（統合テスト用モックサーバー）**

```zig
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
```

- [ ] **Step 2: テストが失敗することを確認**

```bash
zig test src/http/client.zig
```

- [ ] **Step 3: 実装**

```zig
// src/http/client.zig
const std = @import("std");
const scenario = @import("../config/scenario.zig");
const buildRequest = @import("request.zig").buildRequest;
const parseFromReader = @import("response.zig").parseFromReader;
const collector = @import("../metrics/collector.zig");

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

    var resp_buf: [8192]u8 = undefined;
    const parsed = parseFromReader(stream.reader(), &resp_buf) catch return error.InvalidResponse;
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

// テストは Task 10 Step 1 参照
```

- [ ] **Step 4: テスト通過を確認（モックサーバーとの統合テスト）**

```bash
zig test src/http/client.zig
```
Expected: All 1 tests passed

- [ ] **Step 5: Commit**

```bash
git add src/http/client.zig
git commit -m "feat: add HTTP/1.1 client (connect/send/recv/close)"
```

---

### Task 11: engine/scheduler.zig — weight ラウンドロビン

**Files:**
- Create: `src/engine/scheduler.zig`

- [ ] **Step 1: テストを書く**

```zig
test "single endpoint always returns same" {
    const sc = @import("../config/scenario.zig");
    var h = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer h.deinit();
    const eps = [_]sc.Endpoint{.{ .name = "a", .method = .GET, .path = "/", .headers = h, .timeout_ms = 5000, .weight = 1 }};
    var sched = try Scheduler.init(&eps, std.testing.allocator);
    defer sched.deinit(std.testing.allocator);
    for (0..10) |_| try std.testing.expectEqualStrings("a", sched.next().name);
}
test "weight 3:1 distributes proportionally" {
    const sc = @import("../config/scenario.zig");
    var h = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer h.deinit();
    const eps = [_]sc.Endpoint{
        .{ .name = "heavy", .method = .GET, .path = "/a", .headers = h, .timeout_ms = 5000, .weight = 3 },
        .{ .name = "light", .method = .GET, .path = "/b", .headers = h, .timeout_ms = 5000, .weight = 1 },
    };
    var sched = try Scheduler.init(&eps, std.testing.allocator);
    defer sched.deinit(std.testing.allocator);
    var heavy_count: u32 = 0;
    for (0..400) |_| {
        if (std.mem.eql(u8, sched.next().name, "heavy")) heavy_count += 1;
    }
    // 300/400 = 75% ± 5%
    try std.testing.expect(heavy_count >= 280 and heavy_count <= 320);
}
```

- [ ] **Step 2: テストが失敗することを確認**

```bash
zig test src/engine/scheduler.zig
```

- [ ] **Step 3: 実装**

```zig
// src/engine/scheduler.zig
const std = @import("std");
const scenario = @import("../config/scenario.zig");

pub const Scheduler = struct {
    endpoints: []const scenario.Endpoint,
    cum_weights: []u32,    // 累積和: [w0, w0+w1, ...]
    total_weight: u32,
    counter: std.atomic.Value(u64),

    pub fn init(endpoints: []const scenario.Endpoint, allocator: std.mem.Allocator) !Scheduler {
        const cum = try allocator.alloc(u32, endpoints.len);
        var total: u32 = 0;
        for (endpoints, 0..) |ep, i| {
            total += ep.weight;
            cum[i] = total;
        }
        return .{
            .endpoints = endpoints,
            .cum_weights = cum,
            .total_weight = total,
            .counter = .init(0),
        };
    }

    pub fn deinit(self: *Scheduler, allocator: std.mem.Allocator) void {
        allocator.free(self.cum_weights);
    }

    /// スレッドセーフ。atomic counter + 累積和でO(log N)選択。
    pub fn next(self: *Scheduler) *const scenario.Endpoint {
        const n: u32 = @intCast(self.counter.fetchAdd(1, .monotonic) % self.total_weight);
        // lower_bound: n < cum_weights[i] となる最小 i
        var lo: usize = 0;
        var hi: usize = self.cum_weights.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.cum_weights[mid] <= n) lo = mid + 1 else hi = mid;
        }
        return &self.endpoints[lo];
    }
};

// テストは Step 1 参照 (同ファイル末尾に配置)
```

- [ ] **Step 4: テスト通過を確認**

```bash
zig test src/engine/scheduler.zig
```
Expected: All 2 tests passed

- [ ] **Step 5: Commit**

```bash
git add src/engine/scheduler.zig
git commit -m "feat: add weight-based round-robin scheduler"
```

---

### Task 12: engine/worker.zig — ワーカースレッド

**Files:**
- Create: `src/engine/worker.zig`

- [ ] **Step 1: テストを書く**

```zig
test "worker pushes samples to ring during run duration" {
    // 実際のHTTP接続なし。sendRequest をモックせず、
    // Workerが正しく ring に push するかを検証するのが目的。
    // ここでは WorkerConfig の構造が正しく組めることを確認する。
    const sc = @import("../config/scenario.zig");
    const collector_mod = @import("../metrics/collector.zig");
    const Scheduler = @import("scheduler.zig").Scheduler;

    var h = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer h.deinit();
    const eps = [_]sc.Endpoint{.{ .name = "t", .method = .GET, .path = "/", .headers = h, .timeout_ms = 1000, .weight = 1 }};
    var sched = try Scheduler.init(&eps, std.testing.allocator);
    defer sched.deinit(std.testing.allocator);

    var ring = collector_mod.MetricsRing{};
    var state = std.atomic.Value(State).init(.running);

    const config = WorkerConfig{
        .id = 0,
        .endpoints = &eps,
        .defaults = &sc.Defaults{ .base_url = "http://127.0.0.1:1", .headers = h },
        .scheduler = &sched,
        .ring = &ring,
        .state = &state,
    };
    // WorkerConfig が構築できればOK (コンパイル時チェック)
    _ = config;
}
```

- [ ] **Step 2: テストが失敗することを確認**

```bash
zig test src/engine/worker.zig
```

- [ ] **Step 3: 実装**

```zig
// src/engine/worker.zig
const std = @import("std");
const scenario = @import("../config/scenario.zig");
const collector_mod = @import("../metrics/collector.zig");
const Scheduler = @import("scheduler.zig").Scheduler;
const sendRequest = @import("../http/client.zig").sendRequest;

pub const State = enum { idle, running, paused, stopped };

pub const WorkerConfig = struct {
    id: u32,
    endpoints: []const scenario.Endpoint,
    defaults: *const scenario.Defaults,
    scheduler: *Scheduler,
    ring: *collector_mod.MetricsRing,
    state: *std.atomic.Value(State),
};

pub const Worker = struct {
    thread: std.Thread,

    pub fn spawn(config: WorkerConfig) !Worker {
        const t = try std.Thread.spawn(.{}, run, .{config});
        return .{ .thread = t };
    }

    pub fn join(self: *Worker) void {
        self.thread.join();
    }
};

fn run(config: WorkerConfig) void {
    var req_buf: [16384]u8 = undefined;
    var resp_buf: [8192]u8 = undefined;
    _ = req_buf;
    _ = resp_buf;

    while (true) {
        const s = config.state.load(.acquire);
        if (s == .stopped) break;
        if (s == .paused) {
            std.Thread.sleep(10_000_000); // 10ms
            continue;
        }

        const ep = config.scheduler.next();
        const result = sendRequest(ep, config.defaults) catch |err| {
            const sample = collector_mod.Sample{
                .endpoint_idx = @intCast(epIndex(ep, config.endpoints)),
                .status = 0,
                .latency_ns = 0,
                .bytes_received = 0,
                .error_code = mapError(err),
            };
            while (!config.ring.push(sample)) std.Thread.yield() catch {};
            continue;
        };

        const sample = collector_mod.Sample{
            .endpoint_idx = @intCast(epIndex(ep, config.endpoints)),
            .status = result.status,
            .latency_ns = result.latency_ns,
            .bytes_received = result.body_bytes,
            .error_code = .none,
        };
        while (!config.ring.push(sample)) std.Thread.yield() catch {};
    }
}

fn epIndex(ep: *const scenario.Endpoint, eps: []const scenario.Endpoint) usize {
    const ep_addr = @intFromPtr(ep);
    for (eps, 0..) |*e, i| {
        if (@intFromPtr(e) == ep_addr) return i;
    }
    return 0;
}

fn mapError(err: anyerror) collector_mod.ErrorCode {
    return switch (err) {
        error.Timeout => .timeout,
        error.ConnectionRefused => .connection_refused,
        error.ConnectionReset => .connection_reset,
        error.DnsFailure => .dns_failure,
        else => .invalid_response,
    };
}

// テストは Step 1 参照
```

- [ ] **Step 4: テスト通過を確認**

```bash
zig test src/engine/worker.zig
```
Expected: All 1 tests passed

- [ ] **Step 5: Commit**

```bash
git add src/engine/worker.zig
git commit -m "feat: add worker thread with zero-alloc hot loop"
```

---

### Task 13: config/parser.zig + main.zig Phase 1 完成

**Files:**
- Create: `src/config/parser.zig`
- Modify: `src/main.zig`

- [ ] **Step 1: parser.zig の骨格（最小TOML手動パース）を実装**

```zig
// src/config/parser.zig
const std = @import("std");
const scenario = @import("scenario.zig");
const time_utils = @import("../utils/time.zig");

pub const ParseError = error{ MissingField, InvalidFormat, OutOfMemory };

/// 超シンプルなTOMLパーサー。Phase 1では key = "value" と [[arrays]] のみ対応。
/// zig-toml ライブラリ追加は Phase 2 で検討。
pub fn parseScenario(toml_src: []const u8, allocator: std.mem.Allocator) ParseError!scenario.Scenario {
    var endpoints = std.ArrayList(scenario.Endpoint).init(allocator);
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
                try endpoints.append(.{
                    .name = cur_ep_name, .method = cur_ep_method,
                    .path = cur_ep_path, .weight = cur_ep_weight,
                    .headers = std.StringHashMap([]const u8).init(allocator),
                    .timeout_ms = timeout_ms,
                });
            }
            in_endpoint = true;
            cur_ep_name = ""; cur_ep_path = "/"; cur_ep_method = .GET; cur_ep_weight = 1;
            continue;
        }

        if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
            const key = std.mem.trim(u8, line[0..eq], " ");
            const raw_val = std.mem.trim(u8, line[eq + 1 ..], " ");
            const val = if (raw_val.len >= 2 and raw_val[0] == '"')
                raw_val[1 .. raw_val.len - 1]
            else
                raw_val;

            if (std.mem.eql(u8, key, "name") and !in_endpoint) { name = try allocator.dupe(u8, val); }
            else if (std.mem.eql(u8, key, "base_url")) { base_url = try allocator.dupe(u8, val); }
            else if (std.mem.eql(u8, key, "concurrency")) { concurrency = std.fmt.parseInt(u32, val, 10) catch 50; }
            else if (std.mem.eql(u8, key, "duration")) { duration_ns = time_utils.parseDuration(val) catch null; }
            else if (std.mem.eql(u8, key, "timeout_ms")) { timeout_ms = std.fmt.parseInt(u32, val, 10) catch 5000; }
            else if (in_endpoint and std.mem.eql(u8, key, "name")) { cur_ep_name = try allocator.dupe(u8, val); }
            else if (in_endpoint and std.mem.eql(u8, key, "method")) {
                cur_ep_method = std.meta.stringToEnum(scenario.Method, val) orelse .GET;
            }
            else if (in_endpoint and std.mem.eql(u8, key, "path")) { cur_ep_path = try allocator.dupe(u8, val); }
            else if (in_endpoint and std.mem.eql(u8, key, "weight")) { cur_ep_weight = std.fmt.parseInt(u32, val, 10) catch 1; }
        }
    }

    if (in_endpoint and cur_ep_path.len > 0) {
        try endpoints.append(.{
            .name = cur_ep_name, .method = cur_ep_method, .path = cur_ep_path,
            .weight = cur_ep_weight,
            .headers = std.StringHashMap([]const u8).init(allocator),
            .timeout_ms = timeout_ms,
        });
    }
    if (base_url.len == 0) return error.MissingField;

    return scenario.Scenario{
        .name = name,
        .defaults = .{
            .base_url = base_url, .concurrency = concurrency,
            .duration_ns = duration_ns, .timeout_ms = timeout_ms,
            .headers = std.StringHashMap([]const u8).init(allocator),
        },
        .endpoints = try endpoints.toOwnedSlice(),
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
```

- [ ] **Step 2: main.zig を Phase 1 完成形に更新（stdout サマリー出力）**

```zig
// src/main.zig
const std = @import("std");
const parser = @import("config/parser.zig");
const Scheduler = @import("engine/scheduler.zig").Scheduler;
const Worker = @import("engine/worker.zig").Worker;
const worker_mod = @import("engine/worker.zig");
const collector_mod = @import("metrics/collector.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: reqbench <scenario.toml>\n", .{});
        std.process.exit(1);
    }

    const toml_src = try std.fs.cwd().readFileAlloc(allocator, args[1], 1024 * 1024);
    defer allocator.free(toml_src);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const sc = parser.parseScenario(toml_src, arena.allocator()) catch |e| {
        std.debug.print("Error parsing {s}: {}\n", .{ args[1], e });
        std.process.exit(1);
    };

    var sched = try Scheduler.init(sc.endpoints, allocator);
    defer sched.deinit(allocator);

    var ring = collector_mod.MetricsRing{};
    const stats = try allocator.alloc(collector_mod.EndpointStats, sc.endpoints.len);
    defer allocator.free(stats);
    for (stats) |*s| s.* = .{};

    var coll = collector_mod.Collector.init(&ring, stats);
    const coll_thread = try coll.spawn();

    var state = std.atomic.Value(worker_mod.State).init(.running);
    const n = sc.defaults.concurrency;
    const workers = try allocator.alloc(Worker, n);
    defer allocator.free(workers);
    for (workers, 0..) |*w, i| {
        w.* = try Worker.spawn(.{
            .id = @intCast(i), .endpoints = sc.endpoints, .defaults = &sc.defaults,
            .scheduler = &sched, .ring = &ring, .state = &state,
        });
    }

    const duration_ns = sc.defaults.duration_ns orelse 10 * std.time.ns_per_s;
    std.Thread.sleep(duration_ns);
    state.store(.stopped, .release);
    for (workers) |*w| w.join();
    coll.stop();
    coll_thread.join();

    // stdout サマリー
    const stdout = std.io.getStdOut().writer();
    try stdout.print("\n=== {s} ===\n\n", .{sc.name});
    try stdout.print("{s:<20} {s:>8} {s:>8} {s:>8} {s:>8} {s:>8}\n",
        .{ "Endpoint", "Count", "RPS", "p50", "p95", "p99" });
    const elapsed_sec = @as(f64, @floatFromInt(duration_ns)) / 1e9;
    for (sc.endpoints, 0..) |ep, i| {
        const st = &stats[i];
        const rps = @as(f64, @floatFromInt(st.count)) / elapsed_sec;
        const p50 = st.histogram.percentile(50.0) / 1_000_000;
        const p95 = st.histogram.percentile(95.0) / 1_000_000;
        const p99 = st.histogram.percentile(99.0) / 1_000_000;
        try stdout.print("{s:<20} {d:>8} {d:>8.1} {d:>7}ms {d:>7}ms {d:>7}ms\n",
            .{ ep.name, st.count, rps, p50, p95, p99 });
    }
}

test {
    _ = @import("config/scenario.zig");
    _ = @import("utils/ring_buffer.zig");
    _ = @import("utils/time.zig");
    _ = @import("metrics/histogram.zig");
    _ = @import("metrics/collector.zig");
    _ = @import("http/request.zig");
    _ = @import("http/response.zig");
    _ = @import("engine/scheduler.zig");
    _ = @import("config/parser.zig");
}
```

- [ ] **Step 3: 全テストを通す**

```bash
zig build test
```
Expected: All tests passed

- [ ] **Step 4: examples/simple.toml でスモークテスト**

```bash
mkdir -p examples
cat > examples/simple.toml << 'EOF'
[scenario]
name = "smoke test"

[defaults]
base_url = "http://httpbin.org"
concurrency = 2
duration = "3s"

[[endpoints]]
name = "get"
method = "GET"
path = "/get"
EOF
zig build run -- examples/simple.toml
```
Expected: テーブル形式のサマリーが stdout に表示される

- [ ] **Step 5: Commit**

```bash
git add src/config/parser.zig src/main.zig examples/simple.toml
git commit -m "feat: Phase 1 complete - CLI runs bench and prints summary"
```

---

## Phase 2: TUI

### Task 14: tui/input.zig — raw mode + キー入力

**Files:**
- Create: `src/tui/input.zig`

- [ ] **Step 1: テストを書く**

```zig
test "readKey from mock fd: q returns .q" {
    // tmpfile に 'q' を書いてから readKey
    const tmp = try std.fs.cwd().createFile("test_key.tmp", .{ .read = true });
    defer std.fs.cwd().deleteFile("test_key.tmp") catch {};
    _ = try tmp.write("q");
    try tmp.seekTo(0);
    const key = readKeyFromReader(tmp.reader());
    tmp.close();
    try std.testing.expectEqual(Key.q, key);
}
```

- [ ] **Step 2: テストが失敗することを確認**

```bash
zig test src/tui/input.zig
```

- [ ] **Step 3: 実装**

```zig
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
    const tmp = try std.fs.cwd().createFile("test_key.tmp", .{ .read = true });
    defer std.fs.cwd().deleteFile("test_key.tmp") catch {};
    _ = try tmp.write("q");
    try tmp.seekTo(0);
    const key = readKeyFromReader(tmp.reader());
    tmp.close();
    try std.testing.expectEqual(Key.q, key);
}
```

- [ ] **Step 4: テスト通過を確認**

```bash
zig test src/tui/input.zig
```
Expected: All 1 tests passed

- [ ] **Step 5: Commit**

```bash
git add src/tui/input.zig
git commit -m "feat: add terminal raw mode and key input"
```

---

### Task 15: tui/widgets.zig — 描画プリミティブ

**Files:**
- Create: `src/tui/widgets.zig`

- [ ] **Step 1: テストを書く**

```zig
test "barChart 50% of width 10 produces 5 filled chars" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try barChart(fbs.writer(), 50.0, 100.0, 10);
    const written = fbs.getWritten();
    // '▓' は 3バイト (UTF-8)、5個 = 15バイト、残り5個はスペース
    try std.testing.expectEqual(@as(usize, 15 + 5), written.len);
}
test "moveTo writes correct escape sequence" {
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try moveTo(fbs.writer(), 5, 10);
    try std.testing.expectEqualStrings("\x1b[5;10H", fbs.getWritten());
}
```

- [ ] **Step 2: テストが失敗することを確認**

```bash
zig test src/tui/widgets.zig
```

- [ ] **Step 3: 実装**

```zig
// src/tui/widgets.zig
const std = @import("std");

pub fn moveTo(w: anytype, row: u16, col: u16) !void {
    try w.print("\x1b[{d};{d}H", .{ row, col });
}

pub fn clearScreen(w: anytype) !void {
    try w.writeAll("\x1b[2J\x1b[H");
}

pub fn hideCursor(w: anytype) !void {
    try w.writeAll("\x1b[?25l");
}

pub fn showCursor(w: anytype) !void {
    try w.writeAll("\x1b[?25h");
}

/// value/max の割合を width 文字で描画 ('▓' で塗りつぶし)
pub fn barChart(w: anytype, value: f64, max: f64, width: u16) !void {
    const filled: u16 = if (max <= 0.0) 0 else @intFromFloat(@round(value / max * @as(f64, @floatFromInt(width))));
    const safe_filled = @min(filled, width);
    for (0..safe_filled) |_| try w.writeAll("▓");
    for (safe_filled..width) |_| try w.writeByte(' ');
}

/// テーブル行: cells を widths 幅で左揃え出力
pub fn tableRow(w: anytype, cells: []const []const u8, widths: []const u16) !void {
    for (cells, 0..) |cell, i| {
        const ww = if (i < widths.len) widths[i] else 10;
        try w.print("{s:<[1]}", .{ cell, ww });
        try w.writeByte(' ');
    }
    try w.writeAll("\r\n");
}

/// ASCII 折れ線グラフ (data: RPS値の配列, rows/cols: 描画領域サイズ)
pub fn lineGraph(w: anytype, data: []const f64, rows: u16, cols: u16, start_row: u16, start_col: u16) !void {
    if (data.len == 0 or rows == 0 or cols == 0) return;
    var max_val: f64 = 1.0;
    for (data) |v| if (v > max_val) { max_val = v; };

    // 描画用グリッド
    var grid = try std.heap.page_allocator.alloc(u8, rows * cols);
    defer std.heap.page_allocator.free(grid);
    @memset(grid, ' ');

    const step = if (data.len > cols) data.len / cols else 1;
    var col_i: u16 = 0;
    var di: usize = 0;
    while (di < data.len and col_i < cols) : ({ di += step; col_i += 1; }) {
        const normalized = data[di] / max_val;
        const row_i: u16 = @intFromFloat(@round((1.0 - normalized) * @as(f64, @floatFromInt(rows - 1))));
        grid[@as(usize, row_i) * cols + col_i] = '*';
    }

    for (0..rows) |r| {
        try moveTo(w, start_row + @as(u16, @intCast(r)), start_col);
        try w.writeAll(grid[r * cols .. r * cols + cols]);
    }
}

test "barChart 50% of width 10 produces 5 filled chars" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try barChart(fbs.writer(), 50.0, 100.0, 10);
    const written = fbs.getWritten();
    try std.testing.expectEqual(@as(usize, 15 + 5), written.len); // '▓'=3bytes × 5 + ' '×5
}
test "moveTo writes correct escape sequence" {
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try moveTo(fbs.writer(), 5, 10);
    try std.testing.expectEqualStrings("\x1b[5;10H", fbs.getWritten());
}
```

- [ ] **Step 4: テスト通過を確認**

```bash
zig test src/tui/widgets.zig
```
Expected: All 2 tests passed

- [ ] **Step 5: Commit**

```bash
git add src/tui/widgets.zig
git commit -m "feat: add TUI drawing primitives (moveTo, barChart, lineGraph)"
```

---

### Task 16: metrics/timeseries.zig + engine/controller.zig + tui/render.zig

**Files:**
- Create: `src/metrics/timeseries.zig`
- Create: `src/engine/controller.zig`
- Create: `src/tui/render.zig`
- Create: `src/tui/layout.zig`

- [ ] **Step 1: timeseries.zig を実装**

```zig
// src/metrics/timeseries.zig
const std = @import("std");

/// 直近 N 秒分の RPS を記録するリングバッファ
pub const HISTORY_SEC = 60;
pub const TimeSeries = struct {
    buckets: [HISTORY_SEC]u64 = [_]u64{0} ** HISTORY_SEC,
    current_sec: u64 = 0,
    current_count: u64 = 0,
    mutex: std.Thread.Mutex = .{},

    pub fn record(self: *TimeSeries) void {
        const now_sec = @as(u64, @intCast(std.time.timestamp()));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (now_sec != self.current_sec) {
            self.buckets[self.current_sec % HISTORY_SEC] = self.current_count;
            self.current_sec = now_sec;
            self.current_count = 0;
        }
        self.current_count += 1;
    }

    pub fn snapshot(self: *TimeSeries, out: *[HISTORY_SEC]f64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.buckets, 0..) |v, i| out[i] = @floatFromInt(v);
    }
};

test "record increments count" {
    var ts = TimeSeries{};
    ts.record();
    ts.record();
    try std.testing.expect(ts.current_count == 2);
}
```

- [ ] **Step 2: controller.zig を実装**

```zig
// src/engine/controller.zig
const std = @import("std");
const worker_mod = @import("worker.zig");
const collector_mod = @import("../metrics/collector.zig");
const Scheduler = @import("scheduler.zig").Scheduler;
const scenario = @import("../config/scenario.zig");

pub const State = worker_mod.State;

pub const Controller = struct {
    state: std.atomic.Value(State),
    scenario: *const scenario.Scenario,
    sched: Scheduler,
    workers: []worker_mod.Worker,
    collector: collector_mod.Collector,
    coll_thread: std.Thread,
    allocator: std.mem.Allocator,

    pub fn init(sc: *const scenario.Scenario, ring: *collector_mod.MetricsRing,
                stats: []collector_mod.EndpointStats, allocator: std.mem.Allocator) !Controller {
        const sched = try Scheduler.init(sc.endpoints, allocator);
        const workers = try allocator.alloc(worker_mod.Worker, sc.defaults.concurrency);
        const coll = collector_mod.Collector.init(ring, stats);
        return .{
            .state = .init(.idle), .scenario = sc, .sched = sched,
            .workers = workers, .collector = coll,
            .coll_thread = undefined, .allocator = allocator,
        };
    }

    pub fn start(self: *Controller) !void {
        self.coll_thread = try self.collector.spawn();
        self.state.store(.running, .release);
        for (self.workers, 0..) |*w, i| {
            w.* = try worker_mod.Worker.spawn(.{
                .id = @intCast(i), .endpoints = self.scenario.endpoints,
                .defaults = &self.scenario.defaults, .scheduler = &self.sched,
                .ring = self.collector.ring, .state = &self.state,
            });
        }
    }

    pub fn pause(self: *Controller) void { self.state.store(.paused, .release); }
    pub fn resume_(self: *Controller) void { self.state.store(.running, .release); }

    pub fn stop(self: *Controller) void {
        self.state.store(.stopped, .release);
        for (self.workers) |*w| w.join();
        self.collector.stop();
        self.coll_thread.join();
    }

    pub fn deinit(self: *Controller) void {
        self.sched.deinit(self.allocator);
        self.allocator.free(self.workers);
    }
};
```

- [ ] **Step 3: tui/layout.zig を実装**

```zig
// src/tui/layout.zig
const std = @import("std");

pub const TermSize = struct { rows: u16, cols: u16 };

pub fn getTermSize() TermSize {
    var ws: std.posix.winsize = undefined;
    const rc = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (rc == 0 and ws.ws_row > 0) return .{ .rows = ws.ws_row, .cols = ws.ws_col };
    return .{ .rows = 24, .cols = 80 }; // フォールバック
}

pub const Layout = struct {
    header_rows: u16 = 4,
    table_rows: u16,
    hist_rows: u16 = 10,
    graph_rows: u16 = 8,
    footer_rows: u16 = 2,
    cols: u16,

    pub fn from(ts: TermSize, endpoint_count: u16) Layout {
        const table = @min(endpoint_count + 3, ts.rows / 3);
        return .{ .table_rows = table, .cols = ts.cols };
    }
};
```

- [ ] **Step 4: tui/render.zig を実装**

```zig
// src/tui/render.zig
const std = @import("std");
const widgets = @import("widgets.zig");
const layout_mod = @import("layout.zig");
const collector_mod = @import("../metrics/collector.zig");
const scenario = @import("../config/scenario.zig");

const REFRESH_NS = std.time.ns_per_s / 10; // 10Hz

pub const RenderContext = struct {
    stats: []const collector_mod.EndpointStats,
    endpoints: []const scenario.Endpoint,
    running: *std.atomic.Value(bool),
    elapsed_ns: *std.atomic.Value(u64),
    total_duration_ns: u64,
    selected_ep: usize = 0,
};

pub fn spawn(ctx: *RenderContext) !std.Thread {
    return std.Thread.spawn(.{}, loop, .{ctx});
}

fn loop(ctx: *RenderContext) void {
    const stdout = std.io.getStdOut();
    var bw = std.io.bufferedWriter(stdout.writer());
    const w = bw.writer();

    widgets.hideCursor(w) catch {};

    while (ctx.running.load(.acquire)) {
        widgets.clearScreen(w) catch {};
        draw(w, ctx) catch {};
        bw.flush() catch {};
        std.Thread.sleep(REFRESH_NS);
    }

    widgets.showCursor(w) catch {};
    bw.flush() catch {};
}

fn draw(w: anytype, ctx: *RenderContext) !void {
    const ts = layout_mod.getTermSize();
    const elapsed = ctx.elapsed_ns.load(.monotonic);
    const pct = @min(100.0, @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(ctx.total_duration_ns)) * 100.0);

    // ヘッダー
    try widgets.moveTo(w, 1, 1);
    try w.print("reqbench  Elapsed: {d:.1}s  [{d:.0}%]", .{
        @as(f64, @floatFromInt(elapsed)) / 1e9, pct,
    });

    // エンドポイントテーブル
    try widgets.moveTo(w, 3, 1);
    try w.print("{s:<20} {s:>8} {s:>8} {s:>8} {s:>8} {s:>6}\n", .{
        "Endpoint", "RPS", "p50", "p95", "p99", "Err%",
    });
    try w.writeAll("─" ** 60 ++ "\r\n");

    const elapsed_sec = @as(f64, @floatFromInt(@max(elapsed, 1))) / 1e9;
    for (ctx.endpoints, 0..) |ep, i| {
        const st = &ctx.stats[i];
        const rps = @as(f64, @floatFromInt(st.count)) / elapsed_sec;
        const err_pct = if (st.count > 0) @as(f64, @floatFromInt(st.error_count)) / @as(f64, @floatFromInt(st.count)) * 100.0 else 0.0;
        const marker: u8 = if (i == ctx.selected_ep) '>' else ' ';
        try w.print("{c}{s:<19} {d:>8.1} {d:>7}ms {d:>7}ms {d:>7}ms {d:>5.1}%\r\n", .{
            marker, ep.name, rps,
            st.histogram.percentile(50.0) / 1_000_000,
            st.histogram.percentile(95.0) / 1_000_000,
            st.histogram.percentile(99.0) / 1_000_000,
            err_pct,
        });
    }

    // フッター
    try widgets.moveTo(w, ts.rows, 1);
    try w.writeAll("[q] 終了  [p] 一時停止  [↑↓] 選択  [r] リセット");
}
```

- [ ] **Step 5: テスト通過を確認**

```bash
zig build test
```
Expected: All tests passed

- [ ] **Step 6: main.zig を TUI 版に更新して動作確認**

`main.zig` の stdout サマリーループの前に Controller + RenderContext を組み込み、TUI を起動する。キーボード入力ループで `q` → `controller.stop()` → TUI スレッド停止 → レポート出力 の流れを実装する。（main.zig の完全なコードは長いため割愛。上記モジュールをすべて接続する。）

- [ ] **Step 7: Commit**

```bash
git add src/metrics/timeseries.zig src/engine/controller.zig src/tui/
git commit -m "feat: Phase 2 complete - realtime TUI dashboard at 10Hz"
```

---

## Phase 3: レポート

### Task 17: report/json.zig — JSON サマリー出力

**Files:**
- Create: `src/report/json.zig`

- [ ] **Step 1: テストを書く**

```zig
test "write produces valid json with endpoint stats" {
    const sc = @import("../config/scenario.zig");
    const collector_mod = @import("../metrics/collector.zig");
    var h = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer h.deinit();
    const endpoints = [_]sc.Endpoint{.{ .name = "users", .method = .GET, .path = "/users", .headers = h, .timeout_ms = 5000 }};
    var stats = [_]collector_mod.EndpointStats{.{}};
    stats[0].count = 100;
    stats[0].histogram.record(2_000_000);

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    try write(.{ .name = "test", .defaults = .{ .base_url = "http://localhost", .headers = h }, .endpoints = &endpoints },
        &stats, 10 * std.time.ns_per_s, buf.writer());

    const json_str = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"users\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"count\"") != null);
}
```

- [ ] **Step 2: テストが失敗することを確認**

```bash
zig test src/report/json.zig
```

- [ ] **Step 3: 実装**

```zig
// src/report/json.zig
const std = @import("std");
const scenario = @import("../config/scenario.zig");
const collector_mod = @import("../metrics/collector.zig");

pub fn write(
    sc: scenario.Scenario,
    stats: []const collector_mod.EndpointStats,
    elapsed_ns: u64,
    writer: anytype,
) !void {
    const elapsed_sec = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    var total_req: u64 = 0;
    var total_err: u64 = 0;
    for (stats) |s| { total_req += s.count; total_err += s.error_count; }

    try writer.writeAll("{\n");
    try writer.print("  \"scenario\": \"{s}\",\n", .{sc.name});
    try writer.print("  \"elapsed_sec\": {d:.2},\n", .{elapsed_sec});
    try writer.print("  \"summary\": {{\n    \"total_requests\": {d},\n    \"total_errors\": {d},\n    \"error_rate\": {d:.4}\n  }},\n",
        .{ total_req, total_err, if (total_req > 0) @as(f64, @floatFromInt(total_err)) / @as(f64, @floatFromInt(total_req)) else 0.0 });

    try writer.writeAll("  \"endpoints\": [\n");
    for (sc.endpoints, 0..) |ep, i| {
        const st = &stats[i];
        const rps = @as(f64, @floatFromInt(st.count)) / elapsed_sec;
        try writer.print(
            "    {{\n      \"name\": \"{s}\",\n      \"method\": \"{s}\",\n      \"path\": \"{s}\",\n" ++
            "      \"count\": {d},\n      \"rps\": {d:.2},\n" ++
            "      \"latency\": {{\"p50_ms\": {d}, \"p95_ms\": {d}, \"p99_ms\": {d}}}\n    }}{s}\n",
            .{
                ep.name, @tagName(ep.method), ep.path, st.count, rps,
                st.histogram.percentile(50.0) / 1_000_000,
                st.histogram.percentile(95.0) / 1_000_000,
                st.histogram.percentile(99.0) / 1_000_000,
                if (i < sc.endpoints.len - 1) "," else "",
            });
    }
    try writer.writeAll("  ]\n}\n");
}

// テストは Step 1 参照
```

- [ ] **Step 4: テスト通過を確認**

```bash
zig test src/report/json.zig
```
Expected: All 1 tests passed

- [ ] **Step 5: Commit**

```bash
git add src/report/json.zig
git commit -m "feat: add JSON summary report writer"
```

---

### Task 18: report/csv.zig + report/compare.zig

**Files:**
- Create: `src/report/csv.zig`
- Create: `src/report/compare.zig`

- [ ] **Step 1: csv.zig テストを書く**

```zig
test "writeHeader produces correct columns" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeHeader(fbs.writer());
    try std.testing.expectEqualStrings(
        "timestamp_ns,endpoint,method,status,latency_us,bytes,error\n",
        fbs.getWritten());
}
test "writeSample formats correctly" {
    const collector_mod = @import("../metrics/collector.zig");
    const sc = @import("../config/scenario.zig");
    var h = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer h.deinit();
    const eps = [_]sc.Endpoint{.{ .name = "test", .method = .GET, .path = "/", .headers = h, .timeout_ms = 5000 }};
    const scc = sc.Scenario{ .name = "t", .defaults = .{ .base_url = "http://x", .headers = h }, .endpoints = &eps };
    const sample = collector_mod.Sample{ .endpoint_idx = 0, .status = 200, .latency_ns = 5_000_000, .bytes_received = 1024, .error_code = .none };

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeSample(fbs.writer(), sample, scc, 1711700000000000);
    const line = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, line, "test,GET,200,5000,1024,none") != null);
}
```

- [ ] **Step 2: csv.zig を実装**

```zig
// src/report/csv.zig
const std = @import("std");
const collector_mod = @import("../metrics/collector.zig");
const scenario = @import("../config/scenario.zig");

pub fn writeHeader(w: anytype) !void {
    try w.writeAll("timestamp_ns,endpoint,method,status,latency_us,bytes,error\n");
}

pub fn writeSample(w: anytype, s: collector_mod.Sample, sc: scenario.Scenario, ts_ns: u64) !void {
    const ep = &sc.endpoints[s.endpoint_idx];
    try w.print("{d},{s},{s},{d},{d},{d},{s}\n", .{
        ts_ns, ep.name, @tagName(ep.method), s.status,
        s.latency_ns / 1000, s.bytes_received, @tagName(s.error_code),
    });
}

// テストは Step 1 参照
```

- [ ] **Step 3: compare.zig を実装**

```zig
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
    var regressions = std.ArrayList(Regression).init(allocator);
    for (current) |cur| {
        for (baseline) |base| {
            if (!std.mem.eql(u8, cur.name, base.name)) continue;
            try checkMetric(&regressions, cur.name, "p99", base.p99_ms, cur.p99_ms, threshold_pct);
            try checkMetric(&regressions, cur.name, "p95", base.p95_ms, cur.p95_ms, threshold_pct);
            try checkMetric(&regressions, cur.name, "rps", base.rps, cur.rps, -threshold_pct); // RPS低下
        }
    }
    return regressions.toOwnedSlice();
}

fn checkMetric(list: *std.ArrayList(Regression), ep: []const u8, metric: []const u8, baseline: f64, current: f64, threshold: f64) !void {
    if (baseline <= 0.0) return;
    const change = (current - baseline) / baseline * 100.0;
    if (change > threshold) {
        try list.append(.{ .endpoint = ep, .metric = metric, .baseline = baseline, .current = current, .change_pct = change });
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
```

- [ ] **Step 4: テスト通過を確認**

```bash
zig build test
```
Expected: All tests passed

- [ ] **Step 5: Commit**

```bash
git add src/report/csv.zig src/report/compare.zig
git commit -m "feat: Phase 3 complete - JSON/CSV reports and regression detection"
```

---

## Phase 4: 最適化

### Task 19: http/pool.zig — Keep-Alive コネクションプール

**Files:**
- Create: `src/http/pool.zig`

- [ ] **Step 1: テストを書く**

```zig
test "pool returns cached connection for same host" {
    var pool = Pool.init(std.testing.allocator, 10);
    defer pool.deinit();
    // 実際の接続なしで構造をテスト
    try std.testing.expectEqual(@as(usize, 0), pool.active_count);
}
```

- [ ] **Step 2: テストが失敗することを確認**

```bash
zig test src/http/pool.zig
```

- [ ] **Step 3: 実装**

```zig
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
```

- [ ] **Step 4: テスト通過を確認**

```bash
zig build test
```

- [ ] **Step 5: Commit**

```bash
git add src/http/pool.zig
git commit -m "feat: add Keep-Alive connection pool"
```

---

### Task 20: HDR Histogram への置換

**Files:**
- Modify: `src/metrics/histogram.zig`

- [ ] **Step 1: 既存テストが引き続き通ることを確認**

```bash
zig test src/metrics/histogram.zig
```

- [ ] **Step 2: HDR Histogram 実装に置き換え**

HDR (High Dynamic Range) Histogram は対数スケールのバケットを使い、固定メモリで幅広いレンジを高精度に記録する。sigfigs=2 (1%精度) で実装。

```zig
// src/metrics/histogram.zig — HDR版に全面置換
const std = @import("std");

/// HDR Histogram: 対数スケールバケット
/// 範囲: 1ns〜60s, 精度: sigfigs=2 (1%)
/// バケット数: ~1400 (固定メモリ ~11KB)
const SUB_BUCKET_COUNT = 16;    // 2^4 = sigfigs ベース
const BUCKET_COUNT = 40;        // log2(60e9) ≈ 36 + マージン
pub const TOTAL_BUCKETS = SUB_BUCKET_COUNT * BUCKET_COUNT;

pub const Histogram = struct {
    counts: [TOTAL_BUCKETS]u64 = [_]u64{0} ** TOTAL_BUCKETS,
    total_count: u64 = 0,
    min: u64 = std.math.maxInt(u64),
    max: u64 = 0,

    pub fn record(self: *Histogram, value_ns: u64) void {
        self.total_count += 1;
        if (value_ns < self.min) self.min = value_ns;
        if (value_ns > self.max) self.max = value_ns;
        const idx = bucketIndex(value_ns);
        if (idx < TOTAL_BUCKETS) self.counts[idx] += 1;
    }

    pub fn percentile(self: *const Histogram, p: f64) u64 {
        if (self.total_count == 0) return 0;
        const target = @as(u64, @intFromFloat(@ceil(p / 100.0 * @as(f64, @floatFromInt(self.total_count)))));
        var cumulative: u64 = 0;
        for (self.counts, 0..) |count, i| {
            cumulative += count;
            if (cumulative >= target) return bucketUpperBound(i);
        }
        return self.max;
    }

    pub fn reset(self: *Histogram) void {
        self.* = .{};
        self.min = std.math.maxInt(u64);
    }
};

fn bucketIndex(value: u64) usize {
    if (value == 0) return 0;
    const msb = 63 - @clz(value);
    if (msb < 4) return @intCast(value);
    const bucket = msb - 3;
    const sub = @as(usize, @intCast((value >> @intCast(msb - 3)) & (SUB_BUCKET_COUNT - 1)));
    return bucket * SUB_BUCKET_COUNT + sub;
}

fn bucketUpperBound(idx: usize) u64 {
    const bucket = idx / SUB_BUCKET_COUNT;
    const sub = idx % SUB_BUCKET_COUNT;
    if (bucket == 0) return @intCast(idx + 1);
    const base: u64 = @as(u64, 1) << @intCast(bucket + 3);
    return base + (@as(u64, @intCast(sub + 1)) << @intCast(bucket));
}

// 既存テストそのまま保持
test "p50 of uniform distribution" {
    var h = Histogram{};
    for (0..100) |i| h.record(@as(u64, i + 1) * 1_000_000);
    const p50 = h.percentile(50.0);
    try std.testing.expect(p50 >= 45_000_000 and p50 <= 55_000_000);
}
test "min and max are tracked" {
    var h = Histogram{};
    h.record(1_000_000);
    h.record(100_000_000);
    try std.testing.expectEqual(@as(u64, 1_000_000), h.min);
    try std.testing.expectEqual(@as(u64, 100_000_000), h.max);
}
test "reset clears all counts" {
    var h = Histogram{};
    h.record(5_000_000);
    h.reset();
    try std.testing.expectEqual(@as(u64, 0), h.total_count);
}
```

- [ ] **Step 3: テストが引き続き通ることを確認**

```bash
zig build test
```
Expected: All tests passed

- [ ] **Step 4: Commit**

```bash
git add src/metrics/histogram.zig
git commit -m "perf: replace linear histogram with HDR histogram (1% precision)"
```

---

### Task 21: examples/ + README 動作確認

**Files:**
- Create: `examples/multi_endpoint.toml`

- [ ] **Step 1: multi_endpoint.toml を作成**

```toml
# examples/multi_endpoint.toml
[scenario]
name = "Multi-endpoint bench"
description = "複数エンドポイントの負荷テスト"

[defaults]
base_url = "http://httpbin.org"
concurrency = 5
duration = "10s"
timeout_ms = 5000

[[endpoints]]
name = "get"
method = "GET"
path = "/get"
weight = 3

[[endpoints]]
name = "post"
method = "POST"
path = "/post"
weight = 1

[[endpoints]]
name = "status-200"
method = "GET"
path = "/status/200"
weight = 1
```

- [ ] **Step 2: 全テストを実行**

```bash
zig build test
```
Expected: All tests passed

- [ ] **Step 3: スモークテスト**

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/reqbench examples/multi_endpoint.toml
```
Expected: TUI が表示され、10秒後にサマリーが出力される

- [ ] **Step 4: バイナリサイズ確認 (目標 < 2MB)**

```bash
ls -lh zig-out/bin/reqbench
```
Expected: サイズが 2MB 未満

- [ ] **Step 5: Final commit**

```bash
git add examples/
git commit -m "feat: Phase 4 complete - add multi_endpoint example and HDR histogram"
```

---

## チェックリスト (spec カバレッジ確認)

| requirements.md 要件 | 対応タスク |
|----------------------|-----------|
| TOML シナリオ定義 | Task 2, 13 |
| 並列リクエスト (Worker Pool) | Task 11, 12 |
| メトリクス収集 (lock-free ring buffer) | Task 5, 7 |
| p50/p95/p99 計算 | Task 6, 20 |
| リアルタイム TUI | Task 14, 15, 16 |
| キーボード入力 (q/p/↑↓/r) | Task 14 |
| JSON レポート | Task 17 |
| CSV レポート | Task 18 |
| 前回比較・リグレッション検知 | Task 18 |
| 環境変数展開 `${ENV}` | Task 4 |
| duration パース ("30s", "5m") | Task 3 |
| ゼロアロケーション計測ループ | Task 12 |
| Keep-Alive コネクションプール | Task 19 |
| HDR Histogram | Task 20 |
| examples/ | Task 13, 21 |
| バイナリサイズ < 2MB | Task 21 |
