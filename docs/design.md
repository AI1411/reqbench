# reqbench — 技術設計ドキュメント

## 概要

本ドキュメントは `docs/requirements.md` を補完する技術設計仕様です。各モジュールのデータ構造・インターフェース・アルゴリズム・スレッドモデルを定義し、実装の指針とします。

---

## 1. データ構造定義

### 1.1 シナリオ設定

```zig
// config/scenario.zig

pub const Method = enum { GET, POST, PUT, PATCH, DELETE, HEAD };

pub const BodyType = enum { json, form, raw };

pub const Body = struct {
    type: BodyType,
    data: []const u8,  // raw bytes (Arenaで確保)
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
    duration_ns: ?u64 = null,   // duration か requests のどちらか
    request_count: ?u64 = null,
    headers: std.StringHashMap([]const u8),
};

pub const Report = struct {
    formats: []const ReportFormat,  // [.json, .csv]
    output_dir: []const u8,
    compare_with: ?[]const u8 = null,
};

pub const Scenario = struct {
    name: []const u8,
    description: []const u8 = "",
    defaults: Defaults,
    endpoints: []Endpoint,
    report: ?Report = null,
};
```

### 1.2 メトリクス

```zig
// metrics/collector.zig

/// ワーカーからコレクターへ送る1リクエスト分の計測値 (64 bytes に収める)
pub const Sample = struct {
    endpoint_idx: u16,      // Endpoint スライスのインデックス
    status: u16,            // HTTP ステータスコード
    latency_ns: u64,        // ナノ秒単位レイテンシ
    bytes_received: u32,
    error_code: ErrorCode,  // ErrorCode.none = 正常
    _pad: [6]u8 = undefined,
};

pub const ErrorCode = enum(u8) {
    none = 0,
    timeout,
    connection_refused,
    connection_reset,
    dns_failure,
    tls_error,
    invalid_response,
};

/// エンドポイント別の集計統計
pub const EndpointStats = struct {
    count: u64,
    error_count: u64,
    bytes_total: u64,
    histogram: Histogram,
    status_codes: [600]u32,  // index = ステータスコード
};
```

### 1.3 リングバッファ (SPSC)

```zig
// utils/ring_buffer.zig

/// Single Producer Single Consumer — ロックフリー
/// capacity は 2^N である必要がある (マスク演算のため)
pub fn RingBuffer(comptime T: type, comptime capacity: usize) type {
    comptime assert(std.math.isPowerOfTwo(capacity));
    return struct {
        const Self = @This();
        const mask = capacity - 1;

        buf: [capacity]T align(64) = undefined,
        head: usize align(64) = 0,  // Producer が書く
        tail: usize align(64) = 0,  // Consumer が読む

        pub fn push(self: *Self, item: T) bool { ... }
        pub fn pop(self: *Self) ?T { ... }
        pub fn len(self: *Self) usize { ... }
    };
}

// 実用サイズ: Workers × 1024 サンプル分
pub const MetricsRing = RingBuffer(Sample, 65536);
```

### 1.4 HDR Histogram

```zig
// metrics/histogram.zig

/// 固定メモリ HDR Histogram
/// 精度: 1% (sigfigs=2), 範囲: 1µs〜60s
pub const Histogram = struct {
    const LOWEST = 1;           // 1 ns
    const HIGHEST = 60_000_000_000; // 60s in ns
    const SIG_FIGS = 2;

    counts: [BUCKET_COUNT]u64,
    total_count: u64,
    min: u64,
    max: u64,

    pub fn record(self: *Histogram, value_ns: u64) void { ... }
    pub fn percentile(self: *const Histogram, p: f64) u64 { ... }
    pub fn reset(self: *Histogram) void { ... }
};
```

---

## 2. モジュール間インターフェース

### 2.1 全体データフロー

```
main.zig
  │
  ├─→ config/parser.zig ──────────────→ Scenario
  │
  ├─→ engine/controller.zig
  │     │
  │     ├─→ engine/scheduler.zig ─── Endpoint 選択 (weight)
  │     │
  │     └─→ engine/worker.zig (N threads)
  │               │
  │               ├─→ http/client.zig ─── TCP/HTTP
  │               │
  │               └─→ MetricsRing.push(Sample)
  │
  ├─→ metrics/collector.zig (1 thread)
  │     │  MetricsRing.pop() → EndpointStats 更新
  │     └─→ timeseries.zig (RPS 時系列)
  │
  ├─→ tui/render.zig (1 thread, 10Hz)
  │     └─ EndpointStats を読み取り専用参照
  │
  └─→ report/  (終了時)
        ├─→ json.zig
        └─→ csv.zig
```

### 2.2 Controller API

```zig
// engine/controller.zig

pub const State = enum { idle, running, paused, stopped };

pub const Controller = struct {
    state: std.atomic.Value(State),
    scenario: *const Scenario,
    workers: []Worker,
    collector: *Collector,

    pub fn start(self: *Controller) !void;
    pub fn pause(self: *Controller) void;
    pub fn resume_(self: *Controller) void;
    pub fn stop(self: *Controller) void;
    pub fn wait(self: *Controller) void;  // 全 worker の終了を待機
};
```

### 2.3 Worker API

```zig
// engine/worker.zig

pub const WorkerConfig = struct {
    id: u32,
    scenario: *const Scenario,
    scheduler: *Scheduler,
    ring: *MetricsRing,
    state: *std.atomic.Value(Controller.State),
    allocator: std.mem.Allocator,
};

pub const Worker = struct {
    thread: std.Thread,
    config: WorkerConfig,

    pub fn spawn(config: WorkerConfig) !Worker;

    // スレッド内ループ (内部)
    fn run(config: WorkerConfig) void {
        var arena = std.heap.ArenaAllocator.init(config.allocator);
        while (config.state.load(.acquire) == .running) {
            defer _ = arena.reset(.retain_capacity);
            const ep = config.scheduler.next();
            const sample = sendRequest(ep, arena.allocator()) catch |err| makeSample(ep, err);
            while (!config.ring.push(sample)) std.Thread.yield() catch {};
        }
    }
};
```

### 2.4 Scheduler (weight ラウンドロビン)

```zig
// engine/scheduler.zig

pub const Scheduler = struct {
    endpoints: []const Endpoint,
    weights: []u32,          // 累積和
    total_weight: u32,
    counter: std.atomic.Value(u64),

    pub fn init(endpoints: []const Endpoint, allocator: std.mem.Allocator) !Scheduler;

    /// スレッドセーフ: atomic counter + 累積和で O(log N) 選択
    pub fn next(self: *Scheduler) *const Endpoint {
        const n = self.counter.fetchAdd(1, .monotonic) % self.total_weight;
        // 累積和を binary search
        const idx = std.sort.lowerBound(u32, n, self.weights, {}, std.sort.asc(u32));
        return &self.endpoints[idx];
    }
};
```

---

## 3. HTTP クライアント設計

### 3.1 接続モデル

Phase 1 では `std.net.Stream` の Keep-Alive なし実装からスタートし、Phase 4 でコネクションプーリングを追加する。

```
Worker  ─→  connect(addr)
        ─→  send(request_bytes)
        ←─  recv(response_bytes)
        ─→  close()
```

### 3.2 リクエスト構築

```zig
// http/request.zig

pub fn buildRequest(
    ep: *const Endpoint,
    defaults: *const Defaults,
    buf: []u8,          // Arenaから確保した書き込みバッファ
) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();

    // リクエストライン
    try w.print("{s} {s} HTTP/1.1\r\n", .{ @tagName(ep.method), ep.path });

    // ホストヘッダー
    try w.print("Host: {s}\r\n", .{extractHost(defaults.base_url)});

    // デフォルトヘッダー + エンドポイント固有ヘッダー (上書き)
    var it = defaults.headers.iterator();
    while (it.next()) |kv| try w.print("{s}: {s}\r\n", .{ kv.key_ptr.*, kv.value_ptr.* });
    var it2 = ep.headers.iterator();
    while (it2.next()) |kv| try w.print("{s}: {s}\r\n", .{ kv.key_ptr.*, kv.value_ptr.* });

    // ボディ
    if (ep.body) |body| {
        try w.print("Content-Length: {d}\r\n\r\n", .{body.data.len});
        try w.writeAll(body.data);
    } else {
        try w.writeAll("\r\n");
    }

    return fbs.getWritten();
}
```

### 3.3 レスポンスパース (ゼロアロケーション)

ステータスコードとボディサイズのみ取得。ボディは計測対象のバイト数として記録するが内容は捨てる。

```zig
// http/response.zig

pub const ParseResult = struct {
    status: u16,
    body_bytes: u32,
};

/// buf はスタック上の固定バッファ (8KB)
pub fn parse(stream: std.net.Stream, buf: *[8192]u8) !ParseResult {
    // ヘッダー読み取り
    // Content-Length または Transfer-Encoding: chunked を処理
    // ボディは読み捨て (バイト数だけカウント)
}
```

---

## 4. メトリクス収集スレッド

```zig
// metrics/collector.zig

pub const Collector = struct {
    ring: *MetricsRing,
    stats: []EndpointStats,  // endpoint ごと (Mutexなし、collector thread だけ書く)
    timeseries: *TimeSeries,
    running: std.atomic.Value(bool),

    pub fn spawn(self: *Collector) !std.Thread {
        return std.Thread.spawn(.{}, loop, .{self});
    }

    fn loop(self: *Collector) void {
        while (self.running.load(.acquire)) {
            while (self.ring.pop()) |sample| {
                self.process(sample);
            }
            std.Thread.yield() catch {};
        }
        // drain: 停止後の残サンプルも処理
        while (self.ring.pop()) |sample| self.process(sample);
    }

    fn process(self: *Collector, s: Sample) void {
        const st = &self.stats[s.endpoint_idx];
        st.count += 1;
        if (s.error_code != .none) st.error_count += 1;
        st.bytes_total += s.bytes_received;
        st.histogram.record(s.latency_ns);
        if (s.status < 600) st.status_codes[s.status] += 1;
        self.timeseries.record(s.endpoint_idx);
    }
};
```

---

## 5. TUI レンダラー設計

### 5.1 スレッドモデル

- TUI スレッドは **読み取り専用** で `EndpointStats` を参照
- `stats` は Collector スレッドが書き、TUI スレッドが読む
- `u64` の読み取りはアーキテクチャ的にアトミック (x86-64) → Mutex 不要
- ただし Histogram は複数フィールドを読むため、スナップショット方式を採用

```zig
// tui/render.zig

const REFRESH_HZ = 10;
const REFRESH_NS = std.time.ns_per_s / REFRESH_HZ;

fn loop(ctx: *RenderContext) void {
    while (ctx.running.load(.acquire)) {
        const snap = ctx.collector.snapshot();  // 軽量コピー
        ctx.draw(snap);
        std.Thread.sleep(REFRESH_NS);
    }
}
```

### 5.2 描画プリミティブ

外部ライブラリなし。ANSI エスケープコードで直接描画。

```zig
// tui/widgets.zig

/// カーソル移動
pub fn moveTo(w: anytype, row: u16, col: u16) !void {
    try w.print("\x1b[{d};{d}H", .{ row, col });
}

/// テーブル行
pub fn tableRow(w: anytype, cells: []const []const u8, widths: []const u16) !void { ... }

/// ASCII バーチャート (ヒストグラム)
pub fn barChart(w: anytype, value: f64, max: f64, width: u16) !void {
    const filled: u16 = @intFromFloat(@round(value / max * @as(f64, width)));
    for (0..filled) |_| try w.writeByte('\xe2\x96\x93'); // '▓'
    for (filled..width) |_| try w.writeByte(' ');
}

/// ASCII 折れ線グラフ (RPS 時系列)
pub fn lineGraph(w: anytype, data: []const f64, rows: u16, cols: u16) !void { ... }
```

### 5.3 キーボード入力

```zig
// tui/input.zig

pub const Key = enum { q, p, up, down, r, unknown };

pub fn readKey(fd: std.posix.fd_t) Key {
    var buf: [4]u8 = undefined;
    const n = std.posix.read(fd, &buf) catch return .unknown;
    return switch (buf[0]) {
        'q' => .q,
        'p' => .p,
        'r' => .r,
        '\x1b' => if (n >= 3 and buf[1] == '[') switch (buf[2]) {
            'A' => .up,
            'B' => .down,
            else => .unknown,
        } else .unknown,
        else => .unknown,
    };
}
```

---

## 6. レポート出力

### 6.1 JSON 出力

`std.json.stringify` を使用。出力先は `std.fs.File`（バッファリング付き）。

```zig
// report/json.zig

pub fn write(scenario: *const Scenario, stats: []const EndpointStats, elapsed_ns: u64, out: std.fs.File) !void {
    var bw = std.io.bufferedWriter(out.writer());
    // std.json.stringify でシリアライズ
    try std.json.stringify(buildReport(scenario, stats, elapsed_ns), .{ .whitespace = .indent_2 }, bw.writer());
    try bw.flush();
}
```

### 6.2 CSV 出力 (生データ)

Worker → Ring の Sample を直接 CSV に落とす副経路が必要なため、`--csv` 指定時のみ有効化。パフォーマンスへの影響を避けるため、書き込みは別スレッドのバッファ付きライターで行う。

```zig
// report/csv.zig

pub fn writeHeader(w: anytype) !void {
    try w.writeAll("timestamp_ns,endpoint,method,status,latency_us,bytes,error\n");
}

pub fn writeSample(w: anytype, s: Sample, scenario: *const Scenario, ts_ns: u64) !void {
    const ep = &scenario.endpoints[s.endpoint_idx];
    try w.print("{d},{s},{s},{d},{d},{d},{s}\n", .{
        ts_ns,
        ep.name,
        @tagName(ep.method),
        s.status,
        s.latency_ns / 1000,  // µs に変換
        s.bytes_received,
        @tagName(s.error_code),
    });
}
```

### 6.3 比較ロジック

```zig
// report/compare.zig

pub const Regression = struct {
    endpoint: []const u8,
    metric: []const u8,     // "p50", "p95", "p99", "rps"
    baseline: f64,
    current: f64,
    change_pct: f64,
};

/// 閾値を超えた指標を返す
pub fn detect(
    current: Report,
    baseline: Report,
    threshold_pct: f64,  // デフォルト 10.0%
    allocator: std.mem.Allocator,
) ![]Regression { ... }
```

---

## 7. メモリ管理戦略

| レイヤー | アロケータ | ライフタイム |
|----------|-----------|-------------|
| シナリオパース | `ArenaAllocator` (GPA backing) | プロセス終了まで |
| リクエスト1件 | `ArenaAllocator.reset()` | リクエスト完了後に即解放 |
| TUI スナップショット | `FixedBufferAllocator` (スタック) | フレーム描画中 |
| レポート生成 | `ArenaAllocator` (GPA backing) | レポート書き込み後 |
| メトリクス統計 | 静的配列 (endpoint数 × EndpointStats) | プロセス終了まで |

### ゼロアロケーション計測ループの実現

```zig
// engine/worker.zig の run() 内
var arena = std.heap.ArenaAllocator.init(gpa);
var req_buf: [16384]u8 = undefined;  // 16KB スタックバッファ
var resp_buf: [8192]u8 = undefined;  //  8KB スタックバッファ

while (running) {
    defer _ = arena.reset(.retain_capacity);
    // req_buf / resp_buf はスタック → ヒープ割り当てゼロ
    const req = try http.buildRequest(ep, defaults, &req_buf);
    const result = try http.sendRaw(stream, req, &resp_buf);
    ring.push(makeSample(result));
}
```

---

## 8. スレッドモデル全体図

```
Main Thread
  ├─ parse TOML
  ├─ setup terminal (raw mode)
  ├─ spawn Collector Thread
  ├─ spawn TUI Thread
  ├─ spawn Worker Threads [0..N-1]
  ├─ handle keyboard input (blocking read)
  └─ wait all threads → write report → restore terminal

Collector Thread (1x)
  └─ MetricsRing.pop() → EndpointStats 更新 (書き込み専有)

TUI Thread (1x)
  └─ 100ms sleep → EndpointStats スナップショット → ANSI 描画

Worker Thread (Nx)
  └─ Scheduler.next() → HTTP送受信 → MetricsRing.push()
```

---

## 9. ターミナル制御

```zig
// tui/input.zig

pub fn enableRawMode(fd: std.posix.fd_t) !std.posix.termios {
    const orig = try std.posix.tcgetattr(fd);
    var raw = orig;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 1;  // 100ms タイムアウト
    try std.posix.tcsetattr(fd, .NOW, raw);
    return orig;
}

pub fn disableRawMode(fd: std.posix.fd_t, orig: std.posix.termios) void {
    std.posix.tcsetattr(fd, .NOW, orig) catch {};
}
```

---

## 10. エラーハンドリング方針

| エラー種別 | 対応 |
|-----------|------|
| 接続失敗 | `Sample.error_code` に記録、計測継続 |
| タイムアウト | `Sample.error_code = .timeout`、計測継続 |
| 不正レスポンス | `Sample.error_code = .invalid_response`、計測継続 |
| TOML パースエラー | `std.debug.print` + `process.exit(1)` |
| レポート書き込み失敗 | stderr に警告、計測結果は stdout に出力 |
| ターミナルサイズ不足 | 警告メッセージのみ、描画を縮退 |

Worker スレッドは **絶対に panic しない**。全エラーは `Sample.error_code` に変換して計測データとして扱う。

---

## 11. CLI 引数パース

`std.process.argsAlloc` + 手動パース（外部ライブラリなし）。

```zig
// main.zig

pub const Args = struct {
    subcommand: enum { run, quick, compare },
    toml_path: ?[]const u8 = null,
    concurrency: ?u32 = null,
    duration: ?[]const u8 = null,  // "30s", "5m" など
    report: ?[]const u8 = null,    // "json,csv"
    output_dir: ?[]const u8 = null,
    compare_with: ?[]const u8 = null,
    no_tui: bool = false,
    // quick サブコマンド用
    url: ?[]const u8 = null,
};
```

---

## 12. 実装優先順位マッピング

requirements.md の Phase に対応する実装ファイル群：

| Phase | 実装対象ファイル |
|-------|----------------|
| 1 基盤 | `main.zig`, `config/`, `http/client.zig`, `http/request.zig`, `http/response.zig`, `engine/worker.zig`, `engine/scheduler.zig`, `metrics/collector.zig`, `metrics/histogram.zig`, `utils/ring_buffer.zig` |
| 2 TUI | `tui/render.zig`, `tui/widgets.zig`, `tui/layout.zig`, `tui/input.zig`, `engine/controller.zig`, `metrics/timeseries.zig` |
| 3 レポート | `report/json.zig`, `report/csv.zig`, `report/compare.zig` |
| 4 最適化 | `utils/ring_buffer.zig`(lock-free 化), `http/pool.zig`, `metrics/histogram.zig`(HDR) |
