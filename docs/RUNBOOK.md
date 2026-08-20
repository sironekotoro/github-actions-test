# Runbook — Agent Dispatch failures

Agent Dispatch は、異常時に agent を起動するより **fail-safe 停止**を優先します。Issue/Actions summary の failure category を起点に確認してください。

## `REPOSITORY_IDENTITY_MISMATCH`

意味: task の `target_repository` と、dispatcher checkout または cross-repo target checkout の `git remote` が一致しません。

**agent は起動していません。**

確認:

1. task JSON / dispatch input の `target_repository`
2. Actions summary の dispatcher / target identity
3. 対象repo名を修正して再dispatch

Cross-repoでも target checkout 後に同じguardが走るため、誤repoをcheckoutした場合はここで停止します。

## `TARGET_REPOSITORY_NOT_ALLOWED`

対象repoが `config/allowed-repositories.txt` にありません。

- typoならtaskを修正
- 本当に新しい対象repoなら、repo所有権・必要性を確認してallowlistへ明示追加
- prompt本文の指定だけではallowlistを変更できません

## `CROSS_REPO_AUTH_UNAVAILABLE`

Cross-repo pathが無効、またはGitHub App secretsが未設定です。

Actions variable:

```text
CROSS_REPO_ENABLED=true
```

Repository secrets:

```text
GH_APP_ID
GH_APP_PRIVATE_KEY
```

未設定の場合は `docs/CROSS_REPO_DISPATCH.md` の5分セットアップを実施してください。ログに `LIVE_CROSS_REPO_E2E_BLOCKED_BY_APP_SETUP` が出る場合、実装ではなくoperator setup待ちです。

## `APP_TOKEN_FAILED` / `APP_INSTALLATION_NOT_FOUND`

GitHub App installation tokenを作成できません。

確認:

1. Appがtarget repoにinstallされているか
2. Contents / Pull requests permissionが承認済みか
3. `GH_APP_ID` / `GH_APP_PRIVATE_KEY` secret名が正しいか
4. App権限変更後にinstallation側で再承認が必要になっていないか

Secret値をIssueやログへ貼らないでください。

## `TARGET_CHECKOUT_FAILED` / `TARGET_PERMISSION_DENIED`

App token生成後のtarget checkout/API操作に失敗しました。

- App installation対象repoか確認
- repo名/visibilityを確認
- App permissionを確認
- 403は無条件retryしない

## `TARGET_DEFAULT_BRANCH_NOT_FOUND`

Target repoのdefault branchを判定できません。

通常は origin/HEAD -> GitHub API -> `master`/`main` probe の順で判定します。repo metadataとremote branchを確認してください。

## `TASK_ALREADY_RUNNING`

同じ `agent/<task_id>` branchまたはopen PRが既に存在します。

既存run/PRを確認し、新しい仕事なら新しいtask idを発行してください。既存branchを強制上書きしないでください。

## `TARGET_PUSH_FAILED` / `TARGET_PR_CREATE_FAILED`

Agent作業後のtarget repo writeで失敗しました。

- installation tokenのContents / Pull requests write権限
- branch protection
- target remote
- default branch

を確認。main/masterへ直接pushする回避策は使いません。

## Dry-runでの確認

初回cross-repo設定では `dry_run=true` を使用してください。以下だけを確認し、targetを変更しません。

- actor authorization
- allowlist
- GitHub App token
- target checkout
- double identity guard
- default branch
- final agent prompt build

Dry-run成功後にharmless docs-only E2Eを実施し、生成PRはmergeせず確認用に残す/closeします。
