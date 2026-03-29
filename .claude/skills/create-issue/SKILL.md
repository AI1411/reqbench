---
name: create-issue
description: GitHub Issue の作成。テンプレート（bug/feature/refactor/empty）に従ってIssueを対話的に作成。トリガー: "/create-issue", "Issue作成", "バグ報告"
argument-hint: "[テンプレート: bug|feature|refactor|empty] [タイトル（省略可）]"
---

# Issue作成

引数: $ARGUMENTS

## 手順

1. **テンプレート選択**
   - 第1引数でテンプレート種別を判定（bug, feature, refactor, empty）
   - 未指定または不正な値の場合、以下から選択を促す:
     1. `bug` - バグ報告
     2. `feature` - 機能追加リクエスト
     3. `refactor` - リファクタリング
     4. `empty` - 空のテンプレート

2. **テンプレート読み込み**
   - `.github/ISSUE_TEMPLATE/{template}.yml` を読み込む
   - テンプレートの `title`, `labels`, `body` 構造を把握

3. **タイトル確定**
   - 第2引数以降があれば、それをタイトルとして使用
   - なければユーザーに入力を求める
   - テンプレートの title prefix を自動付与:
     - bug: `[Bug] `
     - feature: `[Feature] `
     - refactor: `[Refactor] `
     - empty: prefix なし

4. **主要情報の収集**

   **bug テンプレートの場合:**
   - バグの概要（テキスト入力、必須）
   - 影響範囲（選択: 1.致命的 / 2.高 / 3.中 / 4.低）
   - 再現手順（テキスト入力、任意）

   **feature テンプレートの場合:**
   - 機能の概要（テキスト入力、必須）
   - 解決する課題（テキスト入力、任意）
   - 優先度（選択: 1.最高 / 2.高 / 3.中 / 4.低）

   **refactor テンプレートの場合:**
   - 概要（テキスト入力、必須）
   - 現状の問題点（テキスト入力、任意）
   - 技術的アプローチ（テキスト入力、任意）

   **empty テンプレートの場合:**
   - 内容（テキスト入力、必須）

5. **Issue本文の生成**
   - テンプレート構造に従ったMarkdownを生成
   - 未入力のフィールドは省略または「（未入力）」

   **bugの本文例:**
   ```markdown
   ## バグの概要
   {入力内容}

   ## 影響範囲
   {選択内容}

   ## 再現手順
   {入力内容 or （未入力）}

   ---
   *詳細は Issue ページで編集してください*
   ```

   **featureの本文例:**
   ```markdown
   ## 機能の概要
   {入力内容}

   ## 解決する課題・ユーザーニーズ
   {入力内容 or （未入力）}

   ## 優先度・ビジネス価値
   {選択内容}

   ---
   *詳細は Issue ページで編集してください*
   ```

6. **Issue作成の実行**
   ```bash
   gh issue create \
     --title "{タイトル}" \
     --body "$(cat <<'EOF'
   {生成した本文}
   EOF
   )" \
     --label "{ラベル}" \
     --assignee "AI1411"
   ```

   ラベルの対応:
   - bug: `--label "bug"`
   - feature: `--label "enhancement"`
   - refactor: `--label "refactor"`
   - empty: ラベルなし

7. **結果出力**
   - 作成された Issue の URL を表示

## 補足

- checkboxes型のフィールド（発生箇所、影響する機能領域など）はCLIでは収集しない
- 詳細な情報は Issue 作成後に GitHub 上で編集可能
- `gh` CLI が認証されていない場合は `gh auth login` を案内

## 出力

- 作成した Issue の URL を報告
