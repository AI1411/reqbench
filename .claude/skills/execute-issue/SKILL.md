---
name: execute-issue
description: Issueに対応する修正を実施。Issue内容の確認、ブランチ作成、実装、テストまで自動実行。トリガー: "/execute-issue", "Issue対応", "Issue修正"
argument-hint: "Issue番号 または IssueのURL"
---

# Issue対応修正

Issue番号またはURL: $ARGUMENTS

## 手順

1. **Issue内容の確認**
    - `gh issue view` でIssueの内容を取得
    - 要件、受け入れ条件、関連情報を把握

2. **ブランチ作成**
    - `git fetch origin main && git checkout main && git pull origin main` でmainブランチを最新化
    - mainブランチをベースに新しいブランチを作成
    - ブランチ名: `feature/{番号}`
    - 例: `feature/123`

3. **実装**
    - Issueの要件に基づいて修正を実施
    - 既存コードのパターンを参照して統一する

4. **コード整形**
    - formatter / lint を実行

5. **テスト**
    - テストを実行。必要に応じてテストを追加

## 注意事項

- **コミットは行わない**
- 実装完了後、変更内容のサマリーを報告する
- 不明点があれば実装前にユーザーに確認する
