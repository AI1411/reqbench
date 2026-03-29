# サブエージェント ディスパッチガイド

> このファイルは SessionStart Hook でセッション開始時に自動注入される。
> サブエージェントの使用は **任意ではなく必須** である。

## 7ステップ開発ワークフロー

```
1.設計 → 2.ブランチ → 3.計画 → 4.サブエージェント実装 → 5.TDD → 6.レビュー → 7.完了
```

各ステップには承認ゲートがあり、ゲート通過なしに次へ進めない。
詳細は CLAUDE.md「開発ワークフロー（7ステップ・必須）」を参照。

## ディスパッチテーブル

| トリガー | エージェント (`subagent_type`) | 必須 |
|---------|-------------------------------|------|
| バックエンドコード調査（3+ファイル） | `backend-explorer` | - |
| フロントエンドコード調査（3+ファイル） | `frontend-explorer` | - |
| Go コード実装完了 | `backend-code-reviewer` | **必須** |
| React コード実装完了 | `frontend-quality-manager` | **必須** |
| Go テスト実行・カバレッジ | `backend-test-runner` | - |
| React テスト実行・カバレッジ | `frontend-test-runner` | - |
| Go 包括的品質検証 | `backend-quality-manager` | - |
| 要件書ドラフト完了 | `spec-requirements-validator` | **必須** |
| 設計書ドラフト完了 | `spec-design-validator` | **必須** |
| タスク分解完了 | `spec-task-validator` | **必須** |
| タスク実装 | `spec-task-executor` | - |

## 2段階レビュー（Step 6）

1. **Stage 1: 仕様準拠** → 不足・過剰チェック → Critical なら実装に戻る
2. **Stage 2: コード品質** → Stage 1 通過後のみ実施

## 検証ゲート（Step 7）

完了を主張する前に必ず以下を実行し、**証拠を提示**する：
- `make test` / `pnpm test` → 全パス確認
- `make lint` → エラーゼロ確認
- `make fe-typecheck` → エラーゼロ確認

「should work」「probably fine」は完了ではない。

## スキップ禁止

以下の合理化でエージェント呼び出しをスキップしてはならない：

| 言い訳 | 反論 |
|-------|------|
| 変更が小さい | 小さな変更ほどバグが見逃される |
| テストは後で | TDD原則違反 |
| 自分でレビュー済み | 第三者レビューは別物 |
| シンプルなCRUD | RLS・RBAC バグの温床 |
| 仕様が明確 | validator は省略不可 |
| explorer 不要 | コンテキスト汚染防止 |

## Skills との連携

- **Skills**（`/コマンド`）= ユーザーが明示的に起動するエントリーポイント
- **Agents**（`subagent_type`）= Claude が自動ディスパッチする内部ワーカー
- Skills → Agents の呼び出しは OK。Agents → Skills は禁止。
