---
name: test-backend
description: Improve test coverage for a single Go backend file to near 100%. Measures coverage, identifies untested functions, adds tests, and iterates until all tests pass. Uses backend-test-runner agent for efficient context management.
---
# Backend Test Coverage Improvement Skill

## Purpose
単一のGoバックエンドファイルに対してテストカバレッジを100%に近づける。
カバレッジ計測 → 未テスト箇所特定 → テスト追加 → テスト成功まで修正ループを実行する。

## Trigger Keywords
- バックエンドテスト、カバレッジ改善、テストカバレッジ
- テストを追加、カバレッジ100%、テスト不足
- `backend/internal/` 配下のファイルパス指定

## Usage

```bash
# Usecase のカバレッジ改善
/test-backend backend/internal/usecase/product_usecase.go

# Handler のカバレッジ改善
/test-backend backend/internal/handler/product_handler.go

# Datastore のカバレッジ改善
/test-backend backend/internal/infra/datastore/product_datastore.go
```

## Context Management

**重要: このスキルを実行する前に、必ず `/clear` でコンテキストをクリアすること。**

テストカバレッジ改善ループはコンテキストを大量に消費するため、
最大限のコンテキストウィンドウを確保した状態で開始する必要がある。

## Workflow

```
┌─────────────────────────────────────────────────────────────┐
│         /test-backend <target_file.go> Workflow              │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   ┌──────────────┐                                          │
│   │ 0. CLEAR     │  /clear でコンテキストをクリア            │
│   │   準備       │  → 最大コンテキストウィンドウを確保        │
│   └──────┬───────┘                                          │
│          │                                                  │
│          ▼                                                  │
│   ┌──────────────┐                                          │
│   │ 1. MEASURE   │  対象パッケージのみテスト実行              │
│   │   計測       │  → 対象ファイルのカバレッジ取得            │
│   └──────┬───────┘                                          │
│          │                                                  │
│          ▼                                                  │
│   ┌──────────────┐                                          │
│   │ 2. IDENTIFY  │  go tool cover -func で分析              │
│   │   特定       │  → 未テスト関数をリストアップ              │
│   └──────┬───────┘                                          │
│          │                                                  │
│          ▼                                                  │
│   ┌──────────────┐                                          │
│   │ 3. ADD TESTS │  プロジェクトのパターンに従う              │
│   │   追加       │  → *_test.go にテストケース追加           │
│   └──────┬───────┘                                          │
│          │                                                  │
│          ▼                                                  │
│   ┌──────────────┐         ┌──────────┐                     │
│   │ 4. FIX LOOP  │────────→│ 失敗？   │                     │
│   │   修正       │         └────┬─────┘                     │
│   └──────────────┘              │                           │
│          ▲                      │ Yes                       │
│          │                      ▼                           │
│          │              ┌──────────────┐                    │
│          └──────────────│ エラー修正   │                    │
│                         └──────────────┘                    │
│                                                             │
│   完了: 対象ファイルのカバレッジ100%達成                      │
└─────────────────────────────────────────────────────────────┘
```

## Step 1: Coverage Measurement (計測)

対象パッケージのみテストを実行し、カバレッジを計測する。

### コマンド
```bash
# パッケージパスを特定（例: internal/usecase）
PACKAGE_PATH="./internal/usecase/..."

# カバレッジ計測（backend ディレクトリから実行）
cd backend && go test -coverprofile=coverage.out -count=1 ${PACKAGE_PATH}

# 対象ファイルのカバレッジ確認
cd backend && go tool cover -func=coverage.out | grep "product_usecase.go"
```

### 出力例
```
github.com/.../internal/usecase/product_usecase.go:25:    NewProductUsecase      100.0%
github.com/.../internal/usecase/product_usecase.go:32:    ListProducts            85.7%
github.com/.../internal/usecase/product_usecase.go:58:    GetProduct             100.0%
github.com/.../internal/usecase/product_usecase.go:72:    DeleteProduct            0.0%
total:                                                     (statements)           71.4%
```

## Step 2: Identify Untested Functions (特定)

カバレッジが100%未満の関数を特定し、テストすべきコードパスを洗い出す。

### 分析手順
1. `go tool cover -func` の出力から100%未満の関数を抽出
2. 対象ファイルのソースコードを読み、未テストのコードパスを特定
3. 以下のパターンを重点的にチェック:
   - エラーハンドリング（`if err != nil`）
   - `apperror.NewXxx()` のエラー生成パス
   - バリデーション失敗パス
   - 条件分岐の全パス（`pgx.ErrNoRows` チェック等）
   - `pgtype.Numeric` ↔ `string` 変換エラー

### 未テストパターンの例
```go
// エラーハンドリングパス
if err != nil {
    return nil, fmt.Errorf("get product: %w", err)  // ← テスト不足の可能性
}

// pgx.ErrNoRows の分岐
if errors.Is(err, pgx.ErrNoRows) {
    return oapi.GetProduct404JSONResponse{...}, nil   // ← 404パスのテスト
}

// apperror の生成
return nil, apperror.NewNotFound("product not found")  // ← エラーコードの検証

// pgtype.Numeric のパースエラー
price, err := parseNumeric(input.Price)
if err != nil {
    return nil, apperror.NewValidation("invalid price") // ← 不正な価格文字列
}
```

## Step 3: Add Tests (追加)

プロジェクトのテストパターンに従ってテストケースを追加する。

### テストファイルの配置
- 対象ファイルと同じディレクトリに `*_test.go` を配置
- 外部テストパッケージ（`_test` サフィックス）を使用

### テスト規約（重要）
- **標準ライブラリのみ使用**: `testify` / `gomock` は使わない
- **手動モック**: `mock_test.go` の `*Fn` フィールドパターン
- **oapi-codegen strict-server**: Handler テストは HTTP 不使用、メソッド直接呼び出し
- **レスポンス型アサーション**: `resp.(oapi.XxxNNNJSONResponse)` で型判定

### テンプレート
→ `references/test-templates.md` を参照

## Step 4: Fix Loop (修正)

テストを実行し、失敗したら修正して再実行する。

### ループ手順
```
REPEAT until all tests pass:
  1. テスト実行
     cd backend && go test -v -count=1 ./internal/usecase/...

  2. 失敗した場合
     - エラーメッセージを分析
     - テストコードまたは実装コードを修正

  3. 成功するまで繰り返し
```

### よくある失敗パターンと修正

| 失敗パターン | 原因 | 修正方法 |
|-------------|------|---------|
| `nil pointer dereference` | モックの `*Fn` フィールドが未設定 | nil ガード追加 or Fn を設定 |
| `expected X, got Y` | 戻り値の不一致 | テストの期待値を修正 |
| `no transaction in context` | RLS データストアで ctx に tx がない | `ctxWithTx()` を使用 |
| `compile error: missing method` | mock_test.go にメソッド未実装 | interface のメソッドを追加 |
| `undefined: mockXxxDatastore` | mock_test.go にモック構造体がない | モック構造体を追加 |

## Step 5: Verify 100% Coverage (検証)

最終的なカバレッジを確認する。

```bash
# 最終カバレッジ確認
cd backend && go test -coverprofile=coverage.out -count=1 ./internal/usecase/...
cd backend && go tool cover -func=coverage.out | grep "product_usecase.go"
```

### 期待する出力
```
github.com/.../internal/usecase/product_usecase.go:25:    NewProductUsecase      100.0%
github.com/.../internal/usecase/product_usecase.go:32:    ListProducts           100.0%
github.com/.../internal/usecase/product_usecase.go:58:    GetProduct             100.0%
github.com/.../internal/usecase/product_usecase.go:72:    DeleteProduct          100.0%
total:                                                     (statements)          100.0%
```

## Coverage Targets (目標)

| レイヤー | 目標 | 優先度 | 理由 |
|---------|------|--------|------|
| Usecase | 90%+ | 高 | ビジネスロジックの中核 |
| Handler | 80%+ | 高 | API エンドポイント |
| Datastore | 70%+ | 中 | tx 取得 + クエリ委譲の確認 |

## Agent Delegation

このスキルは `backend-test-runner` エージェントを使用して実行される。

### コンテキスト効率化
- メインコンテキストは対象ファイルパスのみ保持
- 詳細な分析・テスト追加・修正ループはエージェント内で完結
- 結果サマリーのみメインに返却

### エージェント起動
```
Task(backend-test-runner):
  入力: 対象ファイルパス
  実行: MEASURE → IDENTIFY → ADD TESTS → FIX LOOP
  出力: カバレッジ達成結果
```

## Quick Commands

### カバレッジ計測
```bash
# パッケージ全体
cd backend && go test -coverprofile=coverage.out -count=1 ./internal/usecase/...
cd backend && go tool cover -func=coverage.out

# 特定ファイルのみフィルタ
cd backend && go tool cover -func=coverage.out | grep "product_usecase.go"
```

### テスト実行
```bash
# 特定パッケージ
cd backend && go test -v -count=1 ./internal/usecase/...

# 特定テスト
cd backend && go test -v -count=1 ./internal/usecase/... -run TestGetProduct

# 全テスト
make test
```

### Lint
```bash
make be-lint
```

## Troubleshooting

### カバレッジが上がらない
1. テストケースが正しいコードパスを通っているか確認
2. モックの `*Fn` 戻り値がエラーパスをトリガーしているか確認
3. 条件分岐の全パスがテストされているか確認

### テストが失敗する
1. エラーメッセージを確認
2. モックの `*Fn` 設定と実際の呼び出しを比較
3. `mock_test.go` に必要なメソッドが実装されているか確認

### モックメソッドが足りない
```bash
# datastore interface の定義を確認
# backend/internal/infra/datastore/datastore.go

# 不足メソッドを mock_test.go に追加
# パターン: XxxFn フィールド + メソッド実装
```

## Checklist

### 実行前
- [ ] 対象ファイルのパスを確認
- [ ] テストファイルの存在を確認
- [ ] `mock_test.go` に必要なモックがあるか確認

### 実行中
- [ ] カバレッジ計測完了
- [ ] 未テスト関数を特定
- [ ] テストケースを追加
- [ ] テストが成功するまで修正

### 完了後
- [ ] カバレッジ100%達成（または目標達成）
- [ ] 全テストが成功
- [ ] リントエラーなし（`make be-lint`）
