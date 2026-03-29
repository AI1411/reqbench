# reqbench — 設計ドキュメント

## コンセプト

Zig製の軽量HTTPベンチマーカー。TOML でシナリオを定義し、複数エンドポイントへの並列リクエストをリアルタイムTUIで可視化。ツール自体のオーバーヘッドをほぼゼロにすることで、Go/Rust 製サーバーの正確なパフォーマンス計測を実現する。

### 既存ツールとの差別化

| ツール | 言語 | 弱点 | reqbench の優位性 |
|--------|------|------|-------------------|
| hey | Go | 単一URLのみ、GCによるレイテンシ揺れ | シナリオ定義＋GCなし |
| vegeta | Go | TUIなし、リアルタイム可視化が弱い | ライブダッシュボード |
| wrk | C/Lua | Luaスクリプトが煩雑 | TOML宣言的シナリオ |
| k6 | Go | JSランタイムのオーバーヘッド | ネイティブバイナリ、ゼロ依存 |
| oha | Rust | 単一URLのみ | シナリオ定義＋レポート出力 |

---

## アーキテクチャ

```
┌──────────────────────────────────────────────────────┐
│                     CLI Entry                        │
│  (引数パース: TOML パス, 出力形式, 並列数 etc.)       │
└──────────────┬───────────────────────────────────────┘
               │
               ▼
┌──────────────────────────────────────────────────────┐
│              Scenario Parser (TOML)                  │
│  - エンドポイント定義                                 │
│  - ヘッダー / ボディ / メソッド                       │
│  - 並列数 / 期間 / リクエスト数                       │
│  - 依存関係 (sequential steps)                       │
└──────────────┬───────────────────────────────────────┘
               │
               ▼
┌──────────────────────────────────────────────────────┐
│              Worker Pool (io_uring / epoll)           │
│                                                      │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐                │
│  │Worker 1 │ │Worker 2 │ │Worker N │   Zig threads   │
│  │         │ │         │ │         │                  │
│  │ HTTP/1.1│ │ HTTP/1.1│ │ HTTP/1.1│                  │
│  │ Client  │ │ Client  │ │ Client  │                  │
│  └────┬────┘ └────┬────┘ └────┬────┘                 │
│       │           │           │                       │
│       └───────────┴───────────┘                       │
│                   │                                   │
│                   ▼                                   │
│         Metrics Collector (lock-free ring buffer)     │
└──────────────────┬───────────────────────────────────┘
                   │
          ┌────────┴────────┐
          ▼                 ▼
┌──────────────┐   ┌──────────────────┐
│  TUI Render  │   │  Report Writer   │
│  (terminal)  │   │  (JSON / CSV)    │
│              │   │                  │
│ - ライブ統計  │   │ - サマリー        │
│ - ヒストグラム│   │ - 全レコード      │
│ - エラー率    │   │ - 比較用フォーマット│
└──────────────┘   └──────────────────┘
```

### コア設計方針

1. **ゼロアロケーション計測ループ**: リクエスト送信〜レスポンス受信のホットパスではヒープ割り当てを行わない。Arena Allocator でリクエスト単位のメモリを管理し、完了後に一括解放
2. **Lock-free メトリクス収集**: Worker → Collector 間は固定サイズのリングバッファで通信。ロック競合を排除し、計測精度を最大化
3. **TUI は独立スレッド**: 描画処理が計測に影響しないよう、TUI レンダリングは専用スレッドで 10Hz 更新

---

## TOML シナリオ定義

```toml
[scenario]
name = "API ベンチマーク"
description = "ユーザーAPI + 商品APIの負荷テスト"

[defaults]
base_url = "http://localhost:8080"
timeout_ms = 5000
concurrency = 50
duration = "30s"          # または requests = 10000

[defaults.headers]
Content-Type = "application/json"
Authorization = "Bearer ${ENV_TOKEN}"  # 環境変数展開

# ─── エンドポイント定義 ───

[[endpoints]]
name = "ユーザー一覧"
method = "GET"
path = "/api/v1/users"
weight = 3                # リクエスト比率 (3:1:1)

[[endpoints]]
name = "ユーザー詳細"
method = "GET"
path = "/api/v1/users/1"
weight = 1

[[endpoints]]
name = "商品作成"
method = "POST"
path = "/api/v1/products"
weight = 1
[endpoints.body]
type = "json"
data = '{"name": "テスト商品", "price": 1000}'

# ─── レポート設定 ───

[report]
format = ["json", "csv"]
output_dir = "./bench-results"
compare_with = "./bench-results/previous.json"  # 前回との比較
```

### シナリオの高度な機能（v2以降）

```toml
# シーケンシャルステップ（ログイン → API呼び出し）
[[sequences]]
name = "認証フロー"

[[sequences.steps]]
name = "ログイン"
method = "POST"
path = "/auth/login"
[sequences.steps.body]
type = "json"
data = '{"email": "test@example.com", "password": "pass"}'
extract = { token = "$.access_token" }   # JSONPath で値抽出

[[sequences.steps]]
name = "プロフィール取得"
method = "GET"
path = "/api/v1/me"
[sequences.steps.headers]
Authorization = "Bearer ${token}"        # 前ステップの値を参照
```

---

## TUI ダッシュボード設計

```
┌─ reqbench ─────────────────────────────────────────────────────┐
│ Scenario: API ベンチマーク    Elapsed: 12.3s / 30.0s   [▓▓▓░░] │
│ Concurrency: 50              Total Requests: 24,891            │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  Endpoint             RPS     p50     p95     p99    Err%      │
│  ─────────────────────────────────────────────────────────     │
│  ユーザー一覧         1,245   2.1ms   8.3ms  15.1ms  0.0%     │
│  ユーザー詳細           415   1.8ms   6.2ms  12.4ms  0.0%     │
│  商品作成               417   3.4ms  12.1ms  28.7ms  0.2%     │
│                                                                │
├────────────────────────────────────────────────────────────────┤
│  Latency Distribution (ユーザー一覧)                           │
│                                                                │
│  0-2ms   ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  52%                   │
│  2-5ms   ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓           35%                    │
│  5-10ms  ▓▓▓▓▓                          10%                   │
│  10-20ms ▓▓                               3%                  │
│  20ms+   ░                                 0%                  │
│                                                                │
├────────────────────────────────────────────────────────────────┤
│  Throughput (RPS)                                              │
│  2000 ┤                                                        │
│  1500 ┤    ╭──────────╮                                        │
│  1000 ┤───╯            ╰───────────────                        │
│   500 ┤                                                        │
│     0 ┼────┼────┼────┼────┼────┼────┼                          │
│       0    5   10   15   20   25   30                          │
│                                                                │
├────────────────────────────────────────────────────────────────┤
│ [q] 終了  [p] 一時停止  [↑↓] エンドポイント選択  [r] リセット  │
└────────────────────────────────────────────────────────────────┘
```

---

## レポート出力

### JSON サマリー

```json
{
  "scenario": "API ベンチマーク",
  "timestamp": "2026-03-29T15:30:00+09:00",
  "config": {
    "concurrency": 50,
    "duration_sec": 30
  },
  "summary": {
    "total_requests": 62_340,
    "total_errors": 12,
    "error_rate": 0.019,
    "total_bytes": 48_293_120,
    "elapsed_sec": 30.01
  },
  "endpoints": [
    {
      "name": "ユーザー一覧",
      "method": "GET",
      "path": "/api/v1/users",
      "stats": {
        "count": 31_170,
        "rps": 1039.0,
        "latency": {
          "min_ms": 0.4,
          "mean_ms": 2.8,
          "p50_ms": 2.1,
          "p95_ms": 8.3,
          "p99_ms": 15.1,
          "max_ms": 45.2
        },
        "status_codes": { "200": 31168, "500": 2 },
        "histogram": [
          { "range": "0-1ms", "count": 4200 },
          { "range": "1-2ms", "count": 12000 },
          { "range": "2-5ms", "count": 11000 },
          { "range": "5-10ms", "count": 3100 },
          { "range": "10-20ms", "count": 700 },
          { "range": "20ms+", "count": 170 }
        ]
      }
    }
  ],
  "comparison": {
    "baseline": "2026-03-28T15:30:00+09:00",
    "regressions": [
      {
        "endpoint": "商品作成",
        "metric": "p99",
        "baseline_ms": 20.1,
        "current_ms": 28.7,
        "change_pct": 42.8
      }
    ]
  }
}
```

### CSV 出力

全リクエストの生データを出力し、外部ツール（pandas, gnuplot 等）での分析を可能にする。

```csv
timestamp_ns,endpoint,method,status,latency_us,bytes,error
1711700000000000,ユーザー一覧,GET,200,2134,1024,
1711700000001000,商品作成,POST,500,28712,0,connection_reset
```

---

## プロジェクト構成

```
reqbench/
├── build.zig
├── build.zig.zon
├── README.md
│
├── src/
│   ├── main.zig              # CLI エントリ、引数パース
│   │
│   ├── config/
│   │   ├── parser.zig        # TOML パーサー
│   │   ├── scenario.zig      # シナリオ構造体定義
│   │   └── env.zig           # 環境変数展開
│   │
│   ├── http/
│   │   ├── client.zig        # HTTP/1.1 クライアント
│   │   ├── request.zig       # リクエスト構築
│   │   ├── response.zig      # レスポンスパース
│   │   └── pool.zig          # コネクションプール
│   │
│   ├── engine/
│   │   ├── worker.zig        # ワーカースレッド
│   │   ├── scheduler.zig     # リクエストスケジューラ (weight制御)
│   │   └── controller.zig    # 開始/停止/一時停止制御
│   │
│   ├── metrics/
│   │   ├── collector.zig     # lock-free リングバッファ
│   │   ├── histogram.zig     # HDR Histogram (固定メモリ)
│   │   ├── stats.zig         # p50/p95/p99 計算
│   │   └── timeseries.zig    # 時系列データ (RPS推移)
│   │
│   ├── tui/
│   │   ├── render.zig        # 描画ループ
│   │   ├── widgets.zig       # テーブル、バー、グラフ
│   │   ├── layout.zig        # レイアウト管理
│   │   └── input.zig         # キーボード入力
│   │
│   ├── report/
│   │   ├── json.zig          # JSON 出力
│   │   ├── csv.zig           # CSV 出力
│   │   └── compare.zig       # 前回比較ロジック
│   │
│   └── utils/
│       ├── allocator.zig     # Arena Allocator ラッパー
│       ├── time.zig          # 高精度タイマー
│       └── ring_buffer.zig   # SPSC リングバッファ
│
└── examples/
    ├── simple.toml           # 最小シナリオ
    ├── multi_endpoint.toml   # 複数エンドポイント
    └── auth_flow.toml        # 認証フロー
```

---

## 実装フェーズ

### Phase 1: 基盤 (Week 1-2)

HTTP クライアントと計測コアを作る。TUI なし、stdout にサマリー出力。

```
目標: reqbench simple.toml でベンチが走り、結果が stdout に出る

タスク:
  [1] build.zig セットアップ、CI (GitHub Actions)
  [2] TOML パーサー (zig-toml を依存に追加、またはシンプルな自作)
  [3] HTTP/1.1 クライアント (std.net.Stream ベース)
  [4] Worker Pool (std.Thread で N 並列)
  [5] メトリクス収集 (Mutex ベースで OK、後で lock-free 化)
  [6] stdout サマリー出力 (p50/p95/p99, RPS, エラー率)
```

### Phase 2: TUI (Week 3-4)

リアルタイムダッシュボードを実装。

```
目標: ベンチ中にライブ統計がターミナルに描画される

タスク:
  [1] ANSI エスケープベースの TUI レンダラー
      (外部依存なし、raw terminal mode で直接描画)
  [2] エンドポイント別テーブル
  [3] レイテンシヒストグラム (ASCII バー)
  [4] RPS 時系列グラフ (ASCII)
  [5] キーボード入力 (q:終了, p:一時停止, ↑↓:選択)
  [6] TUI スレッド分離 (計測への影響をゼロに)
```

### Phase 3: レポート + 比較 (Week 5-6)

CI/CD 組み込み用のレポート出力と前回比較。

```
目標: --report json,csv でファイル出力、--compare で差分表示

タスク:
  [1] JSON レポート出力
  [2] CSV 生データ出力
  [3] 前回結果との比較ロジック
  [4] リグレッション検知 (閾値ベース)
  [5] 終了コード制御 (リグレッションで exit 1 → CI 連携)
```

### Phase 4: 最適化 + 仕上げ (Week 7-8)

```
目標: hey/vegeta とのベンチマーク比較で勝つ

タスク:
  [1] lock-free リングバッファ (Mutex → atomic に置き換え)
  [2] io_uring 対応 (Linux、epoll フォールバック)
  [3] コネクションプーリング (Keep-Alive 再利用)
  [4] HDR Histogram 実装 (固定メモリ、高精度パーセンタイル)
  [5] README / ドキュメント
  [6] ベンチマーク比較スクリプト (reqbench vs hey vs oha)
```

---

## CLI インターフェース

```bash
# 基本
reqbench run bench.toml

# オプション
reqbench run bench.toml \
  --concurrency 100 \          # TOML のデフォルト値を上書き
  --duration 60s \
  --report json,csv \
  --output ./results \
  --compare ./results/previous.json \
  --no-tui                     # CI 用、プログレスバーのみ

# ワンライナー (TOML なし)
reqbench quick http://localhost:8080/api/health \
  -c 50 -d 10s

# 結果比較
reqbench compare result1.json result2.json
```

---

## Zigの特性が活きるポイント

### 1. comptime でリクエスト構築を最適化

```zig
// HTTP リクエストのヘッダー部分をコンパイル時に構築
fn buildRequestLine(comptime method: []const u8, path: []const u8) []const u8 {
    // method は comptime 既知なので、分岐コストゼロ
    return method ++ " " ++ path ++ " HTTP/1.1\r\n";
}
```

### 2. Arena Allocator でリクエスト単位のメモリ管理

```zig
// 1リクエストの処理サイクル
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();  // レスポンス処理後に全メモリ一括解放

const response = try client.send(request, arena.allocator());
try collector.record(metrics);
// arena.deinit() で全解放 — free() の呼び忘れがない
```

### 3. ゼロオーバーヘッド計測

```zig
// std.time.Timer で高精度計測、GCの割り込みがない
const start = std.time.nanoTimestamp();
const response = try client.send(request);
const elapsed = std.time.nanoTimestamp() - start;
// elapsed はリクエスト処理「だけ」の純粋な時間
```

---

## 成功指標

1. **ベンチマーク**: reqbench 自体のオーバーヘッドが hey/oha の 50% 以下
2. **バイナリサイズ**: < 2MB (静的リンク、ゼロ依存)
3. **メモリ使用量**: 10万リクエスト計測時に < 50MB RSS
4. **起動時間**: < 10ms (TOML パース含む)
5. **GitHub Stars**: 公開1ヶ月で 100+（差別化記事とセット）

---

## プロモーション案

- **ブログ記事**: 「Zig で HTTP ベンチマーカーを作って hey/vegeta と比較した」
    - Zig の学習記録 + ベンチマーク結果で HackerNews 投稿
- **比較ベンチマーク**: reqbench vs hey vs oha vs wrk の定量比較
    - ツール自体のメモリ使用量、レイテンシ精度を計測
- **日本語記事**: Zenn / Qiita に Zig 入門 + reqbench 開発記を連載