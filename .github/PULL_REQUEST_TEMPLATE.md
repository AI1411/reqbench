<!-- I want to review in Japanese. -->

## レビューに関して
レビューする際には、以下のprefix(接頭辞)を付けましょう。
<!-- for GitHub Copilot review rule -->
[must] → かならず変更してね
[imo] → 自分の意見だとこうだけど修正必須ではないよ(in my opinion)
[nits] → ささいな指摘(nitpick)
[ask] → 質問
[fyi] → 参考情報
<!-- for GitHub Copilot review rule-->

## Issues No
close #{issue番号を記載}

## 概要
このプルリクエストで何を実装・修正したかを簡潔に説明してください。

## 変更内容
### 追加機能
- [ ] 新機能A
- [ ] 新機能B

### 修正内容
- [ ] バグ修正A
- [ ] バグ修正B

### その他の変更
- [ ] リファクタリング
- [ ] ドキュメント更新
- [ ] テスト追加

## 動作確認手順
1. 環境構築
   ```bash
   task up       # Postgres / Redis 起動
   task migrate  # マイグレーション実行
   ```

2. 確認手順
   - [ ] 手順1: XXXを確認
   - [ ] 手順2: YYYを確認
   - [ ] 手順3: ZZZを確認

## テスト
- [ ] 単体テストを追加・更新しました
- [ ] 統合テストを追加・更新しました
- [ ] 手動テストを実施しました

### テスト実行結果
```bash
task test         # 全クレート（backend / shared）
task test-backend # バックエンドのみ
task test-shared  # shared クレートのみ
```

## 品質チェック
- [ ] `task lint` (Clippy) でコード品質チェックを通過
- [ ] `task fmt` でコード整形を実行
- [ ] 不要なコメントやデバッグコードを削除

## マイグレーション（DBスキーマ変更がある場合）
- [ ] マイグレーションファイルを `backend/migrations/` に追加しました
- [ ] `task migrate` で正常に適用されることを確認しました
- [ ] `task migrate-revert` でロールバックできることを確認しました
- [ ] RLS ポリシーの変更がある場合、全操作（SELECT/INSERT/UPDATE/DELETE）のポリシーを確認しました

## スクリーンショット（UI変更がある場合）
Before:
（変更前のスクリーンショット）

After:
（変更後のスクリーンショット）

## 破壊的変更
- [ ] 破壊的変更を含む場合は、変更内容と影響範囲を明確に記載してください
- [ ] DBスキーマの破壊的変更がある場合は、マイグレーション手順を記載してください
- [ ] `backend/.env` の変更（環境変数の追加・変更）がある場合は明記してください