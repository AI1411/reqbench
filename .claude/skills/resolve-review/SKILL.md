---
name: resolve-review
description: レビュー指摘対応（修正のみ、コミットなし）。PRのレビューコメントを取得し、指摘を修正して返信。トリガー: "/resolve-review", "レビュー対応", "指摘修正"
argument-hint: "PR番号 または PRのURL"
---

# レビュー指摘対応

PR番号またはURL: $ARGUMENTS

## 手順

1. **レビューコメントの取得**
    - `gh pr view {番号} --comments` でPRのコメントを取得
    - `gh api repos/{owner}/{repo}/pulls/{番号}/comments` でインラインコメントを取得
    - 未解決のレビュー指摘を一覧化

2. **指摘内容の分析**
    - 各コメントの内容を理解
    - 対応が必要な項目をリストアップ
    - 不明点があればユーザーに確認

3. **修正実施**
    - 各指摘に対して修正を実施
    - 修正内容を記録
    - 各指摘に対して指摘ごとのコミットを作成

4. **コード整形**
    - formatter / lint を実行

5. **テスト**
    - 修正によって既存テストが壊れていないか確認

6. **レビューに直接返信**

    **重要: 各インラインコメントに対して、そのスレッドへ直接返信すること。PRへの一括コメントではなく、指摘ごとのスレッドに返信する。**

    ### 事前準備
    - `gh api repos/{owner}/{repo}/pulls/{番号}/comments --jq '.[] | {id, path, line, body}'` でコメントIDを取得

    ### インラインコメントへの直接返信
    各コメントIDに対して以下のコマンドを実行する:

    ```bash
    gh api repos/{owner}/{repo}/pulls/{番号}/comments/{comment_id}/replies \
      --method POST \
      -f body="対応内容の説明（何をどう修正したか）"
    ```

    ### PRへの総括コメント（任意）
    全指摘への返信後、必要に応じて総括コメントを投稿する:

    ```bash
    gh pr comment {番号} --body "## レビュー対応完了\n\n{対応サマリー}"
    ```

    - 対応した指摘は `Resolve conversation` する

## 出力

- 対応した指摘の一覧
