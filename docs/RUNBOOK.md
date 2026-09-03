# Runbook — Agent Dispatch failures

Agent Dispatch は、異常時に agent を起動するより **fail-safe 停止**を優先します。Issue/Actions summary の failure category を起点に確認してください。

## Agent Dispatch の runner 選択

通常の Agent Dispatch は `runner_mode` 未指定時も `self-hosted` を選びます。coding agent を実行できるのは self-hosted isolated path だけです。

- `runner_mode=self-hosted`: 通常実行または dry-run
- `runner_mode=github` + `dry_run=true`: GitHub-hosted control-plane inspectionのみ
- `runner_mode=github` + `dry_run=false`: `INVALID_PAYLOAD` で停止
- unknown runner mode: `INVALID_PAYLOAD`
- self-hosted label variable が欠落・不正: `AGENT_EXECUTOR_UNAVAILABLE`

GitHub-hosted runner へ coding agent をfallbackする経路はありません。composite action も `execution_mode=self-hosted` 以外を独立して拒否します。

self-hosted 経路には、review-repair と同様に Docker daemon と non-root runner user の利用権限が必要です。agent と repository tests は Docker container 内でのみ実行され、host HOME、SSH、他 repository の `.git`、GitHub/App mutation credential、Docker socket は container に渡しません。

## `INVALID_PAYLOAD` — GitHub-hosted live execution requested

`runner_mode=github` なのに `dry_run=true` ではない場合は、agent開始前に停止します。

対応:

1. 通常の coding task なら `runner_mode=self-hosted` にする、またはrunner_modeを省略する
2. GitHub-hosted で確認だけしたい場合は `dry_run=true` にする
3. hosted agent path を再追加して回避しない

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

未設定の場合は `docs/CROSS_REPO_DISPATCH.md` のセットアップを実施してください。Secret値をIssueやログへ貼らないでください。

## `APP_TOKEN_FAILED` / `APP_INSTALLATION_NOT_FOUND`

GitHub App installation tokenを作成できません。

確認:

1. Appがtarget repoにinstallされているか
2. Contents / Pull requests permissionが承認済みか
3. `GH_APP_ID` / `GH_APP_PRIVATE_KEY` secret名が正しいか
4. App権限変更後にinstallation側で再承認が必要になっていないか

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

## `WORKFLOW_PUSH_AUTH_NOT_CONFIGURED` / `CROSS_REPO_WORKFLOW_PUSH_UNSUPPORTED`

Agentが `.github/workflows/**` を変更した場合の安全停止です。

現在のpolicyでは **agent-generated workflow filesを自動publishしません**。

- same-repo → `WORKFLOW_PUSH_AUTH_NOT_CONFIGURED`
- cross-repo → `CROSS_REPO_WORKFLOW_PUSH_UNSUPPORTED`

これはGitHub Appの権限不足を直して再実行する種類のエラーではありません。Agent Dispatchには `permission-workflows: write` の昇格経路を置いていません。

workflow変更が必要な場合:

1. agent runをそのまま再実行して回避しない
2. 必要な変更内容を人間が確認する
3. Agent Dispatchとは別のtrusted manual process/PRで適用する
4. workflow trigger / secrets / permissions / self-hosted runner利用有無をレビューしてからpublishする

## `TARGET_PUSH_FAILED` / `TARGET_PR_CREATE_FAILED`

Agent作業後のtarget repo writeで失敗しました。

- installation tokenのContents / Pull requests write権限
- branch protection
- target remote
- default branch

を確認。main/masterへ直接pushする回避策は使いません。

## Dry-runでの確認

初回cross-repo設定では dry-run を使用してください。

GitHub-hostedで実施する場合は明示的に:

```text
runner_mode=github
dry_run=true
```

またはself-hostedで `dry_run=true` を指定できます。

Dry-runでは以下だけを確認し、targetを変更しません。

- actor authorization
- allowlist
- GitHub App token / target read
- target checkout
- double identity guard
- default branch
- final agent prompt build

agent / branch / commit / push / PR は実行しません。

## `AGENT_EXECUTOR_UNAVAILABLE`

self-hosted executionに必要なrunner label設定またはisolated execution条件がありません。

確認:

- `REVIEW_REPAIR_RUNNER_LABELS` が有効なJSON arrayか
- `self-hosted` と専用labelが含まれるか
- runnerがonlineか
- ordinary Agent Dispatchを `runner_mode=github` へ変更して回避しないこと

## `AGENT_START_FAILED`

Docker daemon、trusted image、isolated staging、patch producerなどagent execution基盤の起動に失敗しています。

self-hosted runnerでは次を確認:

- runner userがrootではない
- Docker daemonが利用可能
- disk容量
- per-run image build
- temporary workspace作成権限

agentをhost上で直接実行して回避しないでください。

## `AGENT_AUTH_FAILED`

選択したagent credentialが欠落・不正、または未実装subscription profileです。

Repository secret source:

- OpenCode: `OPENROUTER_API_KEY`
- Codex: `OPENAI_API_KEY`（Codex processでは `CODEX_API_KEY` に変換）
- Claude Code: `ANTHROPIC_API_KEY`

`PROVIDER_BROKER_ENABLED=true` の通常 Claude Dispatch では、この secret は
trusted broker container だけに渡り、agent には opaque capability だけが渡ります。
ただし production workflow は `ANTHROPIC_BROKER_LIVE_ALLOWED=false` に固定され、
Phase A も Anthropic を `PROVIDER_BUDGET_UNKNOWN` として待機させます。実 Anthropic
forwarding は別途承認・review・明示的な live rollout が完了するまで有効化しないでください。

subscription profileは安全なhandoffが実装されるまでfail-closedです。

## `AGENT_PATCH_INVALID`

isolated workspaceから返されたfilesystem patchがtrusted outer validationを通りません。

Durable reason:

- `NO_CHANGES`
- `EMPTY_PATCH`
- `PATCH_PARSE_FAILED`
- `PATCH_VALIDATION_FAILED`

agentの出力を手動でtrusted checkoutへコピーして回避せず、task/prompt/agent挙動を確認してください。

## Review repair controls

Review repairは通常dispatchとは独立しており、repository variable `REVIEW_REPAIR_ENABLED=true` のときだけ起動します。緊急停止/rollbackはこのvariableを `false` にするか削除します。

`REVIEW_REPAIR_MAX` は既定3（許容1..10）。上限到達時は `REPAIR_LIMIT_REACHED` とPRコメントを残し、agentを起動しません。上限を引き上げる前にPRのrepair markerと履歴を確認してください。

executorにはrepository variable `REVIEW_REPAIR_RUNNER_LABELS`をJSON arrayで設定します。最低限 `["self-hosted","review-repair"]` が必要です。未設定時はhosted runnerへfallbackせず `REPAIR_EXECUTOR_UNAVAILABLE` で停止します。

executor開始時にも GitHub API で現在の `REVIEW_REPAIR_ENABLED` を再確認します。OFFまたは安全に確認できない場合は `REPAIR_DISABLED` で停止し、checkout、agent、target writeは行いません。

`REVIEW_REPAIR_VARIABLES_TOKEN` にはdispatcher repositoryだけを対象にした fine-grained PATを設定し、Repository permissionsの **Variables: read** だけを付与してください（Metadata: readはGitHub側で含まれます）。このtokenをagent、target repository、Docker containerへ渡してはいけません。

review-repair executor runnerにはDocker daemonとnon-root runner userのDocker利用権限が必要です。Dockerまたはtrusted image buildが使えない場合は、agentをhost上で実行せず `AGENT_START_FAILED`で停止します。

agentとrepository testsは`.git`なしのtarget作業コピーだけをmountした使い捨てcontainerで実行されます。host HOME、SSH、GitHub/App token、Docker socketはcontainerへ渡しません。agent networkはinternalで、OpenRouter / OpenAI / Anthropic API HTTPSだけを許可する別proxy経由で通信します。選択した一つのAPI credentialだけがagent実行時にcontainer内の対応variableとして存在し、repository test実行前にunsetされます。

patch作成直前にfinal workspaceのfilename、regular file、symlink target文字列を、選択したcredentialのexact bytesでscanします。一致またはscan errorは`AGENT_CREDENTIAL_LEAK_BLOCKED`でfail-closedし、failure log tail内の同じliteralは固定markerへ置換します。これはraw credentialの永続化・publicationを防ぎますが、agent process自体がkeyを受け取るため完全なcontainmentではありません。長期的な対策はcredentialをagent process外に保つlocal auth broker/relayです。heuristicなsecret patternには依存しません。

## Review repair failure categories

- `AGENT_CREDENTIAL_LEAK_BLOCKED`: final workspaceに選択credentialのexact bytesが残存、または安全にscanできなかったためpublicationを停止。
- `REPAIR_METADATA_INVALID`: PR内のtask metadata、review、ID、input sizeが不正。dispatcher作成PRか確認する。
- `REPAIR_PR_IDENTITY_MISMATCH`: target/base/head repo、dispatcher identity、PR bot principalのいずれかが不一致。
- `REPAIR_BRANCH_MISMATCH`: `agent/<task_id>`、base/default branch、review時head SHA、現在のremote SHAが不一致。
- `REPAIR_LIMIT_REACHED`: 既定3回のstart markerを消化。自動処理は停止済み。
- `REPAIR_STATE_WRITE_FAILED`: agent起動前のreview ID markerを書けなかったため停止。
- `REPAIR_EXECUTOR_UNAVAILABLE`: runner label variableが未設定・不正。
- `REPAIR_EXECUTOR_DISPATCH_FAILED`: executor workflow / Actions write / Actions制限を確認。
- `REPAIR_EXECUTOR_REQUEST_INVALID`: target/PR/review/head SHA/attempt/refのdispatch inputが許容形式外。
- `REPAIR_DISABLED`: executor開始時のauthoritative feature flag確認でOFF、または安全に確認できなかった。

`APP_TOKEN_FAILED`、`TARGET_CHECKOUT_FAILED`、`TARGET_PUSH_FAILED` は通常のcross-repo runbookと同じ確認手順を使います。review本文やsecret値をログへ貼らないでください。

## Duplicate / interrupted review repair

PRコメントのhidden markerが正本です。

```text
<!-- agent-review-repair:v1 status=started review_id=... attempt=... -->
```

`started` はagent起動前に記録されるため、同じreview IDは失敗時も自動再投入されません。失敗原因を直した後はauthorized reviewerが新しい `CHANGES_REQUESTED` reviewを現在のhead SHAへ提出してください。

`dispatched` 後にexecutorがqueuedのままなら、Actions画面で `Agent Review Repair Executor` とself-hosted runnerのonline/busy、label一致を確認します。dispatcher成功はrepair成功を意味しません。`executor-started` と最終 `completed` / `failed` marker、executor run URL、agent runtimeを確認してください。
