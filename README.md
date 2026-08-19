# github-actions-test

ChatGPT / Issue から投入したタスクを、GitHub Actions 経由で OpenCode（OpenRouter）を起動して処理する **中央 dispatch 基盤** の動作確認リポジトリ。

## 目的

- **どの repository に対するタスクなのかを機械的に保証** し、wrong-repository execution を構造的に防ぐ。
- Issue / `workflow_dispatch` から投入したタスクが確実に agent job まで到達し、失敗時には原因（failure category）が明確に分かる。

## アーキテクチャ

```
ChatGPT / ユーザー
  ↓  (Issue 作成 + label 付与)  or  (workflow_dispatch)
GitHub Issue / dispatch inputs
  ↓  GitHub Actions: agent-dispatch.yml
1. Authorize actor        → UNAUTHORIZED_ACTOR で停止
2. Parse task             → task.json (JSON payload)
3. Repository identity guard → 不一致なら REPOSITORY_IDENTITY_MISMATCH で agent 起動前に停止
4. Prepare branch         → dirty tree / duplicate 検査、agent/<task_id> ブランチ
5. Run coding agent       → opencode (OpenRouter)、bounded runtime / retry
6. Commit / push / PR     → メタデータ付き PR 作成
7. Feedback               → Issue コメント + Step summary
```

詳細は [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) を参照。

## タスクの投入方法（Issue 経由）

1. **対象 repository を確認**（`sironekotoro/github-actions-test` で起動するため、タスク先も同じ repository であること）。
2. Issue 本文に **JSON payload** を書く（全体、` ```json ` fenced block、または JSON 1 行のいずれか）。

```json
{
  "task_id": "example-001",
  "target_repository": "sironekotoro/github-actions-test",
  "title": "README の冒頭に一行追記",
  "prompt": "このリポジトリの README.md を読み、repository name を確認し、コードを変更せず診断結果のみを出力してください。"
}
```

3. Issue に **`opencode-run` または `agent:ready`** ラベルを付与すると Actions が起動する（ラベルを付けなければ何も実行されない）。
4. Actions 完了後、Issue に結果コメント（Run / Branch / PR or Failure category）が投稿される。
5. 生成された Draft/通常 PR を確認して merge する。

## タスクの投入方法（workflow_dispatch 経由）

Actions タブ → **Agent Dispatch** → **Run workflow** を選択し、`target_repository` / `task_id` / `title` / `prompt` を入力。

```text
target_repository: sironekotoro/github-actions-test
task_id: manual-001
title: 診断のみ
prompt: README を読み、リポジトリ名を確認して診断結果のみ出力してください。
```

## 重要な制約

- **`target_repository` は必ず `sironekotoro/github-actions-test` にする**。別 repository（例: `sironekotoro/zengin-pl`）を指定すると、agent は起動せず `REPOSITORY_IDENTITY_MISMATCH` で fail-safe 停止する。
- agent は **1 task = 1 fresh session**。過去 task の context は引き継がない。
- agent は main/master に直接 commit しない。`agent/<task_id>` ブランチで作業し、workflow が commit / push / PR まで行う。
- agent prompt には target repository の identity guard が自動挿入される（`scripts/build-agent-prompt.sh`）。

## 開発

```bash
# 基盤のローカルテスト（identity guard / injection / duplicate / parse など）
bash tests/run-all.sh

# リポジトリの unit test
npm test
```

CI（`.github/workflows/ci.yml`）が push / PR 時に両方を実行する。

## インシデント時の対応

- `REPOSITORY_IDENTITY_MISMATCH` が出た場合 → [docs/RUNBOOK.md](docs/RUNBOOK.md) を参照。