---
name: code-review
description: PRを指定してCodex CLIでコードレビューを実施。差分を分析し、prefix付き（[must]/[imo]/[nits]/[ask]/[fyi]）でレビューコメントを投稿する。トリガー: "レビューして", "コードレビュー", "PRレビュー", "/code-review"
---

# コードレビュー（Codex版）

PR番号またはURL: $ARGUMENTS

## 手順

1. **PR情報の取得**
    - `gh pr view {番号}` でPRの概要・本文を取得
    - `gh pr diff {番号}` で差分を取得し、ファイルに保存: `gh pr diff {番号} > /tmp/pr_{番号}.diff`
    - `gh pr view {番号} --json commits` でコミット一覧を取得

2. **Codexによるコードレビュー実行**

    以下のコマンドでCodex CLIにレビューを依頼する:

    ```bash
    codex exec --full-auto --sandbox read-only --cd {プロジェクトディレクトリ} "$(cat <<'EOF'
    以下のPR差分をコードレビューしてください。

    ## レビュー観点
    - 正確性・ロジック: バグ、論理エラー、エッジケースの考慮漏れ
    - セキュリティ: SQLインジェクション、XSS、機密情報ハードコーディング
    - コード品質: 命名の一貫性、既存パターンへの準拠、不要コード、重複
    - テスト: テストの追加・更新の有無、カバレッジ
    - パフォーマンス: N+1クエリ、不要な処理、メモリリーク

    ## 出力形式
    各指摘を以下のJSON Lines形式で出力してください（1行1指摘）:
    {"prefix":"[must]","file":"ファイルパス","line":行番号,"end_line":終了行番号or null,"body":"指摘内容"}

    prefixは以下から選択:
    - [must]: 必須修正（バグ、セキュリティ、重大な設計問題）
    - [imo]: 意見・提案（修正任意）
    - [nits]: 些細な指摘（タイポ、フォーマット）
    - [ask]: 質問（意図・仕様の確認）
    - [fyi]: 参考情報

    最後に総評を以下の形式で出力:
    {"summary":"総評テキスト","must":件数,"imo":件数,"nits":件数,"ask":件数,"fyi":件数}

    ## レビュー対象の差分
    差分ファイル: /tmp/pr_{番号}.diff を読んでレビューしてください。
    変更されたコードのみをレビュー対象とし、既存コードへの指摘は [fyi] としてください。
    レビューは日本語で実施してください。良い実装には積極的に褒めてください。
    指摘は具体的に、可能なら修正案を添えてください。
    EOF
    )"
    ```

3. **Codex出力の解析**
    - Codexの出力からJSON Lines形式の指摘を抽出
    - 総評（summary）を抽出
    - JSON解析できない場合は、Codexの出力をそのまま活用してインラインコメントを手動構成

4. **レビュー結果の投稿（インラインコメント）**

    **重要: すべての指摘はインラインコメントとして対象コードの行に直接投稿する。まとめてPRコメントに投稿してはならない。**

    ### 事前準備
    - `gh pr view {番号} --json headRefOid --jq '.headRefOid'` で最新コミットSHAを取得
    - `gh api repos/{owner}/{repo}/pulls/{番号} --jq '.head.repo.full_name'` でリポジトリ名を取得

    ### インラインコメントの投稿
    各指摘ごとに以下のコマンドを実行する:

    ```bash
    gh api repos/{owner}/{repo}/pulls/{番号}/comments \
      --method POST \
      -f body="$(cat <<'EOF'
    {prefix} {コメント内容}
    EOF
    )" \
      -f commit_id="{コミットSHA}" \
      -f path="{ファイルパス}" \
      -F line={行番号} \
      -f side="RIGHT"
    ```

    複数行にまたがる指摘の場合は `start_line` と `start_side` も指定する:
    ```bash
    gh api repos/{owner}/{repo}/pulls/{番号}/comments \
      --method POST \
      -f body="$(cat <<'EOF'
    {prefix} {コメント内容}
    EOF
    )" \
      -f commit_id="{コミットSHA}" \
      -f path="{ファイルパス}" \
      -F start_line={開始行番号} \
      -f start_side="RIGHT" \
      -F line={終了行番号} \
      -f side="RIGHT"
    ```

    ### 総評コメントの投稿
    すべてのインラインコメント投稿後、PRに総評コメントを1つ投稿する:

    ```bash
    gh pr comment {番号} --body "$(cat <<'EOF'
    ## コードレビュー 総評

    {Codexによる総評}

    ### 指摘サマリー
    | Prefix | 件数 |
    |--------|------|
    | [must] | {件数} |
    | [imo] | {件数} |
    | [nits] | {件数} |
    | [ask] | {件数} |
    | [fyi] | {件数} |

    各指摘は対象コードにインラインコメントとして投稿済みです。

    ---
    📝 Reviewed by Codex + Claude Code
    EOF
    )"
    ```

5. **レビュー結果のサマリー（ユーザーへの報告）**
    - 指摘の総数をprefix別に集計
    - [must] がある場合は修正を強く推奨
    - 全体的な品質評価を報告

## 注意事項

- レビューは日本語で実施する
- 変更されたコードのみをレビュー対象とする（既存コードへの指摘は [fyi] で）
- 良い実装には積極的に褒める
- 指摘は具体的に、可能なら修正案を添える
- Codexの出力がJSON形式でない場合は、内容を解釈してインラインコメントを構成する
