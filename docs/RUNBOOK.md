# Runbook — `REPOSITORY_IDENTITY_MISMATCH`

agent が起動せず `REPOSITORY_IDENTITY_MISMATCH` で停止した場合の対応手順。

## 概要

Task の `target_repository` と、実際に workflow が動いている repository（`GITHUB_REPOSITORY`）または checkout された `git remote` が一致しないと発生します。
**agent は起動していません**（fail-safe stop）。

## 原因となりうるケース

1. Issue / dispatch の `target_repository` が別 repo（例: zengin 向けの指示を rapidgator 側 agent へ貼り付けた過去事例に相当）。
2. workflow が想定と異なる repo に配置された。
3. チェックアウトされた remote URL が想定と異なる（clone 元の取り違え）。

## 対応手順

1. **Task の target を確認**
   - Issue の場合は Issue 本文の JSON の `target_repository`
   - dispatch の場合は入力欄の `target_repository`
   - Actions run の Step summary の `target (payload)` 欄にも表示される。

2. **GitHub repository を確認**
   - Actions run の URL から、どの repo で run したかを確認（`GITHUB_REPOSITORY`）。
   - 手元でも確認する場合:
     ```bash
     git remote -v
     ```

3. **一致させる**
   - タスク対象が別 repo の場合: **この中央基盤（`sironekotoro/github-actions-test`）では実行できません。** target をこの repo のタスクに直すか、対象 repo 側に適切な dispatch 基盤を用意してください。
   - 記入ミスの場合: `target_repository` を正しい値に修正して再 dispatch（Issue なら label を外して付け直し、または修正した dispatch を実行）。

4. **再 dispatch**
   - workflow_dispatch: 修正後の inputs で再実行。
   - Issue: `target_repository` を修正 → 新しい Issue か修正後に `opencode-run` label を付け直す。

## 確認ポイント

- 正しい組み合わせ: `target (payload)` = `actual (GITHUB_REPOSITORY)` = `checked-out remote` がすべて同値。
- この run では agent step は実行されず、issue へ `REPOSITORY_IDENTITY_MISMATCH` のコメントが投稿されます。
- どうしても別 repo で agent を動かしたい場合: `GITHUB_TOKEN` は repo 境界を越えられないため、GitHub App / 各 repo 用 token の設計が必要（docs/ARCHITECTURE.md 参照）。