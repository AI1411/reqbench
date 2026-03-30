# reqbench

Zig製の軽量HTTPベンチマーカー。ゼロアロケーション計測ループ、リアルタイムTUI、HDR Histogramによる高精度パーセンタイル計算を備える。

## 特徴

- **ゼロアロケーション計測ループ**: スタックバッファ + Arena でヒープアロケーションなし
- **HDR Histogram**: 対数スケールバケットによる高精度なp50/p95/p99計算
- **Keep-Alive コネクションプール**: コネクション再利用によるスループット向上
- **TOML シナリオ定義**: 重み付きエンドポイント・環境変数展開をサポート
- **並列ワーカー**: SPSCリングバッファ経由で Collector にサンプルを送信

## 必要環境

- [Zig](https://ziglang.org/) 0.13 以上

## ビルド

```bash
git clone https://github.com/AI1411/reqbench
cd reqbench
zig build
```

バイナリは `zig-out/bin/reqbench` に生成される。

## 使い方

```bash
reqbench <scenario.toml>
```

### 実行例

```bash
# シンプルなスモークテスト (httpbin.org)
./zig-out/bin/reqbench examples/simple.toml

# 複数エンドポイントの重み付きベンチマーク
./zig-out/bin/reqbench examples/multi_endpoint.toml

# ローカルサーバーのベンチマーク
./zig-out/bin/reqbench examples/localhost.toml
```

### 出力例

```
=== smoke test ===

Endpoint              Count      RPS      p50      p95      p99
get                     342     34.2    85ms    210ms    380ms
```

## シナリオファイルの書き方

```toml
[scenario]
name = "my benchmark"
description = "任意の説明"

[defaults]
base_url = "http://localhost:8080"
concurrency = 50        # 同時接続数
duration = "30s"        # 計測時間 (s/m 単位)
timeout_ms = 5000       # タイムアウト (ms)

[[endpoints]]
name = "health"
method = "GET"
path = "/health"
weight = 1              # ラウンドロビンの重み

[[endpoints]]
name = "create"
method = "POST"
path = "/api/items"
weight = 2
[endpoints.body]
type = "json"           # json / form / raw
data = '{"name": "test"}'
```

### 環境変数展開

```toml
[defaults]
base_url = "http://${API_HOST}:${API_PORT}"
```

## サンプルシナリオ

| ファイル | 内容 |
|---|---|
| `examples/simple.toml` | httpbin.org へのシンプルなGETリクエスト |
| `examples/multi_endpoint.toml` | 複数エンドポイントへの重み付きベンチマーク |
| `examples/localhost.toml` | ローカルサーバーのAPI負荷テスト |

## テスト実行

```bash
zig build test
```

## アーキテクチャ

```
Worker N本 → SPSC RingBuffer → Collector thread
                                     ↓
                               EndpointStats (HDR Histogram)
                                     ↓
                               stdout サマリー出力
```

- **Worker**: ゼロアロケーションHTTPループ。Keep-Aliveプールからコネクションを取得。
- **Scheduler**: atomic カウンタによる重み付きラウンドロビン。
- **Collector**: ロックフリーリングバッファからサンプルを消費してHistogramに記録。
- **HDR Histogram**: 対数スケールで~1400バケット (~11KB) に幅広いレンジを高精度記録。
