# Test Templates

このプロジェクトのバックエンドテストテンプレート集。
各レイヤーの実際のテストパターンに基づく。

## 基本ルール

- **標準ライブラリのみ**: `testify`, `gomock` は使わない
- **外部テストパッケージ**: `package xxx_test` を使用
- **手動モック**: `mock_test.go` に `*Fn` フィールドパターンで定義
- **テーブル駆動 or 個別サブテスト**: 状況に応じて使い分け
- **アサーション**: `t.Fatalf` / `t.Errorf` を直接使用

## Handler テスト

### テストパターン（oapi-codegen strict-server）

Handler テストは **HTTP サーバーを使わない**。`StrictServerInterface` のメソッドを直接呼び出す。

```go
package handler_test

import (
	"context"
	"errors"
	"testing"

	"github.com/sou-project/commerce-hub/internal/apperror"
	"github.com/sou-project/commerce-hub/internal/gen/oapi"
	"github.com/sou-project/commerce-hub/internal/usecase"
)

func TestListProducts(t *testing.T) {
	sampleProduct := oapi.Product{
		Id:   1,
		Name: "Test Product",
	}

	tests := []struct {
		name     string
		request  oapi.ListProductsRequestObject
		mockFn   func(context.Context, usecase.ListProductsInput) ([]oapi.Product, int64, error)
		wantType string // "200" or "500"
		wantCount int
	}{
		{
			name:    "success with default params",
			request: oapi.ListProductsRequestObject{},
			mockFn: func(_ context.Context, input usecase.ListProductsInput) ([]oapi.Product, int64, error) {
				return []oapi.Product{sampleProduct}, 1, nil
			},
			wantType:  "200",
			wantCount: 1,
		},
		{
			name:    "usecase error returns 500",
			request: oapi.ListProductsRequestObject{},
			mockFn: func(_ context.Context, _ usecase.ListProductsInput) ([]oapi.Product, int64, error) {
				return nil, 0, errors.New("db error")
			},
			wantType: "500",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h := newTestHandler(&mockProductUsecase{
				ListProductsFn: tt.mockFn,
			}, nil, nil, nil, nil, nil)

			resp, err := h.ListProducts(context.Background(), tt.request)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}

			switch tt.wantType {
			case "200":
				got, ok := resp.(oapi.ListProducts200JSONResponse)
				if !ok {
					t.Fatalf("expected 200 response, got %T", resp)
				}
				if len(got.Products) != tt.wantCount {
					t.Errorf("expected %d products, got %d", tt.wantCount, len(got.Products))
				}
			case "500":
				_, ok := resp.(oapi.ListProducts500JSONResponse)
				if !ok {
					t.Fatalf("expected 500 response, got %T", resp)
				}
			}
		})
	}
}
```

### Handler テスト - 単一エンドポイント（パスパラメータあり）

```go
func TestGetProduct(t *testing.T) {
	t.Run("success", func(t *testing.T) {
		h := newTestHandler(&mockProductUsecase{
			GetProductFn: func(_ context.Context, id int64) (*oapi.ProductDetail, error) {
				return &oapi.ProductDetail{Id: id, Name: "Test"}, nil
			},
		}, nil, nil, nil, nil, nil)

		resp, err := h.GetProduct(context.Background(), oapi.GetProductRequestObject{
			ProductId: 1,
		})
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		got, ok := resp.(oapi.GetProduct200JSONResponse)
		if !ok {
			t.Fatalf("expected 200 response, got %T", resp)
		}
		if got.Name != "Test" {
			t.Errorf("expected name %q, got %q", "Test", got.Name)
		}
	})

	t.Run("not found returns 404", func(t *testing.T) {
		h := newTestHandler(&mockProductUsecase{
			GetProductFn: func(_ context.Context, _ int64) (*oapi.ProductDetail, error) {
				return nil, apperror.NewNotFound("product not found")
			},
		}, nil, nil, nil, nil, nil)

		resp, err := h.GetProduct(context.Background(), oapi.GetProductRequestObject{
			ProductId: 999,
		})
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		_, ok := resp.(oapi.GetProduct404JSONResponse)
		if !ok {
			t.Fatalf("expected 404 response, got %T", resp)
		}
	})
}
```

### Handler テスト - エラーレスポンスの検証

```go
// apperror のエラーコードに応じたレスポンス型を検証
t.Run("validation error returns 400", func(t *testing.T) {
	h := newTestHandler(&mockProductUsecase{
		CreateProductFn: func(_ context.Context, _ usecase.CreateProductInput) (*oapi.ProductDetail, error) {
			return nil, apperror.NewValidation("name is required")
		},
	}, nil, nil, nil, nil, nil)

	resp, err := h.CreateProduct(context.Background(), oapi.CreateProductRequestObject{
		Body: &oapi.CreateProductRequest{},
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	got, ok := resp.(oapi.CreateProduct400JSONResponse)
	if !ok {
		t.Fatalf("expected 400 response, got %T", resp)
	}
	if got.Message != "name is required" {
		t.Errorf("expected message %q, got %q", "name is required", got.Message)
	}
})
```

### Handler モック構造体（mock_test.go）

```go
package handler_test

// Handler テスト用: Usecase interface の手動モック
type mockProductUsecase struct {
	ListProductsFn  func(context.Context, usecase.ListProductsInput) ([]oapi.Product, int64, error)
	GetProductFn    func(context.Context, int64) (*oapi.ProductDetail, error)
	CreateProductFn func(context.Context, usecase.CreateProductInput) (*oapi.ProductDetail, error)
	// ... 全メソッド分の Fn フィールド
}

func (m *mockProductUsecase) ListProducts(ctx context.Context, input usecase.ListProductsInput) ([]oapi.Product, int64, error) {
	return m.ListProductsFn(ctx, input)
}

func (m *mockProductUsecase) GetProduct(ctx context.Context, id int64) (*oapi.ProductDetail, error) {
	return m.GetProductFn(ctx, id)
}

// ... 全メソッドの実装
```

### ヘルパー関数（mock_test.go）

```go
// ptr はジェネリクスでポインタを返す
func ptr[T any](v T) *T {
	return &v
}

// newTestHandler は全 usecase をモック付きで Handler を生成
// nil を渡すとゼロ値モックが使われる
func newTestHandler(
	product *mockProductUsecase,
	asset *mockAssetUsecase,
	auth *mockAuthUsecase,
	org *mockOrganizationUsecase,
	member *mockMemberUsecase,
	ai *mockAIUsecase,
	landingPage ...*mockLandingPageUsecase,
) *handler.Handler {
	if product == nil { product = &mockProductUsecase{} }
	if asset == nil { asset = &mockAssetUsecase{} }
	// ... nil ガード
	return handler.NewHandler(product, asset, auth, org, member, ai, &mockPostUsecase{}, lp)
}
```

---

## Usecase テスト

### テストパターン（個別サブテスト）

Usecase テストは個別の `TestXxx_Success` / `TestXxx_Error` サブテストで構成する。

```go
package usecase_test

import (
	"context"
	"errors"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/sou-project/commerce-hub/internal/appctx"
	"github.com/sou-project/commerce-hub/internal/apperror"
	"github.com/sou-project/commerce-hub/internal/config"
	db "github.com/sou-project/commerce-hub/internal/gen/db"
	"github.com/sou-project/commerce-hub/internal/usecase"
)

// --- ヘルパー ---

func ctxWithCompany(companyID int64) context.Context {
	return appctx.WithCompanyID(context.Background(), companyID)
}

func newTestConfig() *config.Config {
	return &config.Config{MinIOBucket: "test-bucket"}
}

func sampleDBProduct() db.Product {
	return db.Product{
		ID:        1,
		CompanyID: 100,
		Name:      "Test Product",
		Price:     pgtype.Numeric{Int: big.NewInt(1000), Exp: -2, Valid: true},
		// ... 必要なフィールド
	}
}

// --- テスト ---

func TestGetProduct_Success(t *testing.T) {
	ds := &mockProductDatastore{
		GetProductFn: func(_ context.Context, id int64) (db.Product, error) {
			if id != 1 {
				t.Fatalf("expected id 1, got %d", id)
			}
			return sampleDBProduct(), nil
		},
		ListProductSkusByProductIDFn: func(_ context.Context, _ int64) ([]db.ProductSku, error) {
			return nil, nil
		},
		ListProductMeritsByProductIDFn: func(_ context.Context, _ int64) ([]db.ProductMerit, error) {
			return nil, nil
		},
		ListProductTagsByProductIDFn: func(_ context.Context, _ int64) ([]db.ListProductTagsByProductIDRow, error) {
			return nil, nil
		},
		ListProductAssetLinksByProductIDFn: func(_ context.Context, _ int64) ([]db.ListProductAssetLinksByProductIDRow, error) {
			return nil, nil
		},
	}

	uc := usecase.NewProductUsecase(ds, nil, nil, nil, nil, newTestConfig())
	got, err := uc.GetProduct(ctxWithCompany(100), 1)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.Name != "Test Product" {
		t.Errorf("expected name %q, got %q", "Test Product", got.Name)
	}
}

func TestGetProduct_NotFound(t *testing.T) {
	ds := &mockProductDatastore{
		GetProductFn: func(_ context.Context, _ int64) (db.Product, error) {
			return db.Product{}, pgx.ErrNoRows
		},
	}

	uc := usecase.NewProductUsecase(ds, nil, nil, nil, nil, newTestConfig())
	_, err := uc.GetProduct(ctxWithCompany(100), 999)
	if err == nil {
		t.Fatal("expected error, got nil")
	}

	var apiErr *apperror.APIError
	if !errors.As(err, &apiErr) {
		t.Fatalf("expected APIError, got %T", err)
	}
	if apiErr.Code != apperror.CodeDataNotFound {
		t.Errorf("expected code %s, got %s", apperror.CodeDataNotFound, apiErr.Code)
	}
}

func TestGetProduct_DBError(t *testing.T) {
	ds := &mockProductDatastore{
		GetProductFn: func(_ context.Context, _ int64) (db.Product, error) {
			return db.Product{}, errors.New("connection refused")
		},
	}

	uc := usecase.NewProductUsecase(ds, nil, nil, nil, nil, newTestConfig())
	_, err := uc.GetProduct(ctxWithCompany(100), 1)
	if err == nil {
		t.Fatal("expected error, got nil")
	}
}
```

### Usecase テスト - テーブル駆動（パターンが似ている場合）

```go
func TestDeleteProduct(t *testing.T) {
	tests := []struct {
		name    string
		mockFn  func(context.Context, int64) error
		wantErr bool
	}{
		{
			name: "success",
			mockFn: func(_ context.Context, _ int64) error {
				return nil
			},
			wantErr: false,
		},
		{
			name: "db error",
			mockFn: func(_ context.Context, _ int64) error {
				return errors.New("db error")
			},
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ds := &mockProductDatastore{
				DeleteProductFn: tt.mockFn,
			}
			uc := usecase.NewProductUsecase(ds, nil, nil, nil, nil, newTestConfig())
			err := uc.DeleteProduct(ctxWithCompany(100), 1)

			if tt.wantErr && err == nil {
				t.Fatal("expected error, got nil")
			}
			if !tt.wantErr && err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
		})
	}
}
```

### Usecase モック構造体（mock_test.go）

```go
package usecase_test

// Usecase テスト用: Datastore interface の手動モック
type mockProductDatastore struct {
	GetProductFn                         func(context.Context, int64) (db.Product, error)
	ListProductsFn                       func(context.Context, int32, int32) ([]db.Product, error)
	CountProductsFn                      func(context.Context) (int64, error)
	CreateProductFn                      func(context.Context, db.CreateProductParams) (db.Product, error)
	// ... 全メソッド分の Fn フィールド
}

func (m *mockProductDatastore) GetProduct(ctx context.Context, id int64) (db.Product, error) {
	return m.GetProductFn(ctx, id)
}

// nil ガードパターン（新しいメソッドで推奨）
func (m *mockProductDatastore) ListProductTagMasters(ctx context.Context) ([]db.ProductTagMaster, error) {
	if m.ListProductTagMastersFn != nil {
		return m.ListProductTagMastersFn(ctx)
	}
	return nil, nil
}
```

### Usecase テスト - apperror の検証

```go
// errors.As で APIError を取得し、Code を検証
var apiErr *apperror.APIError
if !errors.As(err, &apiErr) {
	t.Fatalf("expected APIError, got %T: %v", err, err)
}
if apiErr.Code != apperror.CodeDataNotFound {
	t.Errorf("expected error code %s, got %s", apperror.CodeDataNotFound, apiErr.Code)
}
```

### Usecase テスト - pgtype.Numeric の扱い

```go
import "math/big"

// 価格の pgtype.Numeric ヘルパー
func numericPrice(cents int64) pgtype.Numeric {
	return pgtype.Numeric{Int: big.NewInt(cents), Exp: -2, Valid: true}
}

// 使用例
product := db.Product{
	Price: numericPrice(1000), // "10.00"
}
```

---

## Datastore テスト

### テストパターン（tx 有無の確認）

Datastore テストは **実 DB を使わない**。
tx がコンテキストにない場合のエラーと、tx がある場合のクエリ委譲を確認する。

```go
package datastore_test

import (
	"context"
	"testing"

	db "github.com/sou-project/commerce-hub/internal/gen/db"
	"github.com/sou-project/commerce-hub/internal/infra/datastore"
)

func TestNewProductDatastore(t *testing.T) {
	ds := datastore.NewProductDatastore()
	if ds == nil {
		t.Fatal("expected non-nil ProductDatastore")
	}
}

// tx なしで全メソッドが "no transaction in context" エラーを返すことを確認
func TestProductDatastore_NoTx(t *testing.T) {
	ds := datastore.NewProductDatastore()
	ctx := context.Background()

	t.Run("GetProduct", func(t *testing.T) {
		_, err := ds.GetProduct(ctx, 1)
		assertNoTxError(t, err)
	})

	t.Run("ListProducts", func(t *testing.T) {
		_, err := ds.ListProducts(ctx, 10, 0)
		assertNoTxError(t, err)
	})

	t.Run("CreateProduct", func(t *testing.T) {
		_, err := ds.CreateProduct(ctx, db.CreateProductParams{})
		assertNoTxError(t, err)
	})

	// ... 全メソッドについて同様にテスト
}

// tx ありでクエリがエラーを返すことを確認（mockTx が errMock を返す）
func TestProductDatastore_WithTx(t *testing.T) {
	ds := datastore.NewProductDatastore()
	ctx := ctxWithTx()

	t.Run("GetProduct", func(t *testing.T) {
		_, err := ds.GetProduct(ctx, 1)
		assertMockError(t, err)
	})

	// ... 全メソッドについて同様にテスト
}
```

### 非 RLS Datastore テスト（pool 直接使用）

```go
package datastore_test

import (
	"testing"

	"github.com/sou-project/commerce-hub/internal/infra/datastore"
)

func TestNewUserDatastore(t *testing.T) {
	// MigrationPool (mockDBTX) を注入
	ds := datastore.NewUserDatastore(&mockDBTX{})
	if ds == nil {
		t.Fatal("expected non-nil UserDatastore")
	}
}

func TestUserDatastore_GetUserByEmail(t *testing.T) {
	ds := datastore.NewUserDatastore(&mockDBTX{})
	_, err := ds.GetUserByEmail(context.Background(), "test@example.com")
	// mockDBTX は errMock を返す
	assertMockError(t, err)
}
```

### Datastore モック構造体（mock_test.go）

```go
package datastore_test

import (
	"context"
	"errors"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/sou-project/commerce-hub/internal/appctx"
)

var errMock = errors.New("mock error")

// mockTx implements pgx.Tx for tx-based datastore testing.
type mockTx struct{}

func (m *mockTx) Begin(_ context.Context) (pgx.Tx, error)     { return nil, nil }
func (m *mockTx) Commit(_ context.Context) error               { return nil }
func (m *mockTx) Rollback(_ context.Context) error             { return nil }
func (m *mockTx) Conn() *pgx.Conn                              { return nil }
func (m *mockTx) CopyFrom(_ context.Context, _ pgx.Identifier, _ []string, _ pgx.CopyFromSource) (int64, error) {
	return 0, nil
}
func (m *mockTx) SendBatch(_ context.Context, _ *pgx.Batch) pgx.BatchResults { return nil }
func (m *mockTx) LargeObjects() pgx.LargeObjects { return pgx.LargeObjects{} }
func (m *mockTx) Prepare(_ context.Context, _, _ string) (*pgconn.StatementDescription, error) {
	return nil, nil
}
func (m *mockTx) Exec(_ context.Context, _ string, _ ...any) (pgconn.CommandTag, error) {
	return pgconn.CommandTag{}, nil
}
func (m *mockTx) Query(_ context.Context, _ string, _ ...any) (pgx.Rows, error) {
	return nil, errMock
}
func (m *mockTx) QueryRow(_ context.Context, _ string, _ ...any) pgx.Row {
	return &mockRow{err: errMock}
}

// mockRow implements pgx.Row.
type mockRow struct{ err error }
func (r *mockRow) Scan(_ ...any) error { return r.err }

// mockDBTX implements db.DBTX for pool-based datastore testing.
type mockDBTX struct{}
func (m *mockDBTX) Exec(_ context.Context, _ string, _ ...any) (pgconn.CommandTag, error) {
	return pgconn.CommandTag{}, nil
}
func (m *mockDBTX) Query(_ context.Context, _ string, _ ...any) (pgx.Rows, error) {
	return nil, errMock
}
func (m *mockDBTX) QueryRow(_ context.Context, _ string, _ ...any) pgx.Row {
	return &mockRow{err: errMock}
}

// --- ヘルパー ---

func ctxWithTx() context.Context {
	return appctx.WithTx(context.Background(), &mockTx{})
}

func assertNoTxError(t *testing.T, err error) {
	t.Helper()
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if err.Error() != "no transaction in context" {
		t.Fatalf("expected 'no transaction in context', got %q", err.Error())
	}
}

func assertMockError(t *testing.T, err error) {
	t.Helper()
	if !errors.Is(err, errMock) {
		t.Fatalf("expected errMock, got %v", err)
	}
}

func assertNoError(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
}
```

---

## export_test.go パターン

テスト対象パッケージの非公開関数をテストから参照する場合:

```go
// usecase/export_test.go
package usecase

// Export internal functions for testing.
var HashInvitationTokenForTest = hashInvitationToken
```

---

## テスト追加時の注意事項

### モック Fn の nil ガード

新しいメソッドを追加する場合、既存テストが nil panic しないよう nil ガードを推奨:

```go
func (m *mockProductDatastore) NewMethod(ctx context.Context) (db.Result, error) {
	if m.NewMethodFn != nil {
		return m.NewMethodFn(ctx)
	}
	return db.Result{}, nil // 安全なデフォルト値
}
```

### レスポンス型アサーションのパターン

```go
// Handler テストでのレスポンス判定
resp, err := h.SomeMethod(ctx, request)
if err != nil {
	t.Fatalf("unexpected error: %v", err)
}

// 成功レスポンス
got, ok := resp.(oapi.SomeMethod200JSONResponse)
if !ok {
	t.Fatalf("expected 200 response, got %T", resp)
}

// エラーレスポンス（apperror → handler の toErrorResponse() 経由）
got, ok := resp.(oapi.SomeMethod404JSONResponse)
if !ok {
	t.Fatalf("expected 404 response, got %T", resp)
}
```

### Context ヘルパーの使い分け

| ヘルパー | 用途 | パッケージ |
|---------|------|-----------|
| `context.Background()` | Handler テスト全般 | handler_test |
| `ctxWithCompany(100)` | Usecase テスト（CompanyID 必要） | usecase_test |
| `ctxWithTx()` | Datastore テスト（RLS tx あり） | datastore_test |
| `context.Background()` | Datastore テスト（tx なしエラー確認） | datastore_test |
