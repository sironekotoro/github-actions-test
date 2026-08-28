# Runbook — Agent Dispatch failures

Agent Dispatch は、異常時に agent を起動するより **fail-safe 停止**を優先します。Issue/Actions summary の failure category を起点に確認してください。

## Agent Dispatch の runner 選択

通常の Agent Dispatch は `runner_mode` 未指定／`github` のとき従来どおり
GitHub-hosted `ubuntu-latest` で実行される。`self-hosted` は明示指定した task だけが
既存 `REVIEW_REPAIR_RUNNER_LABELS` の Mac runner を選ぶ実験経路である。未知の値は
`INVALID_PAYLOAD`、label variable が欠落・不正なら `AGENT_EXECUTOR_UNAVAILABLE` で停止し、
hosted runner へ fallback しない。

self-hosted 経路には、review-repair と同様に Docker daemon と non-root runner user の
利用権限が必要。agent と repository tests は Docker container 内でのみ実行され、host
HOME、SSH、他 repository、GitHub/App credential、Docker socket は container に渡さない。

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

## Review repair controls

Review repairは通常dispatchとは独立しており、repository variable
`REVIEW_REPAIR_ENABLED=true` のときだけ起動します。緊急停止/rollbackは
このvariableを `false` にするか削除します。既存agent PR、通常Issue
dispatch、cross-repo dispatchのfeature gateには影響しません。

`REVIEW_REPAIR_MAX` は既定3（許容1..10）。上限到達時は
`REPAIR_LIMIT_REACHED` とPRコメントを残し、agentを起動しません。上限を
引き上げる前にPRのrepair markerと履歴を確認してください。

executorにはrepository variable `REVIEW_REPAIR_RUNNER_LABELS`をJSON arrayで
設定します。最低限 `["self-hosted","review-repair"]` が必要です。
実runnerにもこれらのlabelを付与し、必要なOS/architecture labelを
追加してください。未設定時はhosted runnerへfallbackせず
`REPAIR_EXECUTOR_UNAVAILABLE` で停止します。

executor開始時にも GitHub API で現在の `REVIEW_REPAIR_ENABLED` を再確認します。
OFFまたは安全に確認できない場合は `REPAIR_DISABLED` で停止し、checkout、agent、
target writeは行いません。
`REVIEW_REPAIR_VARIABLES_TOKEN` にはdispatcher repositoryだけを対象にした
fine-grained PATを設定し、Repository permissionsの **Variables: read** だけを
付与してください（GitHubが必須とするMetadata: readは自動的に含まれます）。未設定・
期限切れ・権限不足は安全な停止となります。このtokenをagent、target repository、
Docker containerへ渡してはいけません。

review-repair executor runnerにはDocker daemonとnon-root runner userのDocker利用権限が
必要です。Dockerまたはtrusted image buildが使えない場合は、agentをhost上で実行せず
`AGENT_START_FAILED`で停止します。agentとrepository testsは`.git`なしのtarget作業コピー
だけをmountした使い捨てcontainerで実行され、host HOME、SSH、`gh`/Codex/OpenCode/
Claude credentials、GitHub/App token、Docker socketはcontainerへ渡しません。agent
networkはinternalで、OpenRouter / OpenAI / Anthropic API HTTPSだけを許可する別proxy
経由で通信します。選択した一つのAPI credentialだけがagent実行時にcontainer内の
対応variableとして存在し、repository test実行前にunsetされます。subscription profile
は安全なhandoffが実装されるまで `AGENT_AUTH_FAILED` で実行前に停止します。agent
log/promptはhostのartifactやPR feedbackへ渡しません。

## Review repair failure categories

- `REPAIR_METADATA_INVALID`: PR内のtask metadata、review、ID、input sizeが不正。手動でbranchを再利用せず、dispatcher作成PRか確認する。
- `REPAIR_PR_IDENTITY_MISMATCH`: target/base/head repo、dispatcher identity、PR bot principalのいずれかが不一致。forkや手作成PRは対象外。
- `REPAIR_BRANCH_MISMATCH`: `agent/<task_id>`、base/default branch、review時head SHA、現在のremote SHAが不一致。新しいreviewが必要な場合がある。
- `REPAIR_LIMIT_REACHED`: 既定3回のstart markerを消化。自動処理は停止済み。
- `REPAIR_STATE_WRITE_FAILED`: agent起動前のreview ID markerを書けなかったため停止。App/GITHUB_TOKENのPull requests write権限を確認する。
- `REPAIR_EXECUTOR_UNAVAILABLE`: runner label variableが未設定・不正。JSONとrunner labelsを確認する。
- `REPAIR_EXECUTOR_DISPATCH_FAILED`: executor workflowがdefault branchに存在するか、Actions write権限、Actions制限を確認する。hosted dispatcherからexecutorの完了待ちはしない。
- `REPAIR_EXECUTOR_REQUEST_INVALID`: target/PR/review/head SHA/attempt/refのdispatch inputが許容形式外。手動で書き換えず元reviewとdispatcher logを確認する。
- `REPAIR_DISABLED`: executor開始時のauthoritativeなrepository variable確認でfeature flagがOFF、または安全に確認できなかった。agent・checkout・target writeは行われていない。

`APP_TOKEN_FAILED`、`TARGET_CHECKOUT_FAILED`、`TARGET_PUSH_FAILED` は通常の
cross-repo runbookと同じ確認手順を使います。review本文やsecret値をログへ
貼らないでください。review本文はtrusted commandではありません。

## Duplicate / interrupted review repair

PRコメントの次のhidden markerが正本です。

```text
<!-- agent-review-repair:v1 status=started review_id=... attempt=... -->
```

`started` はagent起動前に記録されるため、同じreview IDは失敗時も自動再投入
されません。失敗原因を直した後はauthorized reviewerが新しい
`CHANGES_REQUESTED` reviewを現在のhead SHAへ提出してください。コメントを
削除して強制再実行する運用は推奨しません。

`dispatched` 後にexecutorがqueuedのままなら、Actions画面で
`Agent Review Repair Executor`とself-hosted runnerのonline/busy、label一致を確認します。
dispatcherは意図的にexecutor完了を待たないため、dispatcher成功はrepair成功を
意味しません。`executor-started` と最終 `completed` / `failed`
marker、executor run URL、agent runtimeを確認してください。
