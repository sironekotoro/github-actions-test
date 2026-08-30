# Immediate Agent Notifications

Agent Dispatch and Review Repair expose lifecycle state without polling.

## Event flow

1. The source workflow finishes normally or reaches a deliberate waiting state.
2. A trusted no-op step records one machine-readable step name:
   - `TASK_COMPLETED`
   - `TASK_FAILED`
   - `ACTION_REQUIRED`
3. GitHub emits `workflow_run: completed` immediately after the source workflow completes.
4. `Agent Notification Gateway` reads the completed run's jobs with `actions: read`, extracts the trusted step marker, and sends configured external notifications.
5. If a source workflow fails before it can write a marker, the gateway falls back to the workflow conclusion and reports a generic `TASK_FAILED` / `ACTION_REQUIRED` event.

There is no scheduled polling loop and no model/provider inference in the notification path.

## Trust boundary

The source Agent Dispatch / Review Repair workflows do **not** receive notification SMTP or Slack credentials. Only the dedicated notification gateway can read them.

The gateway always checks out notifier code from the repository default branch. It never checks out the completed workflow's branch or target repository. It consumes only GitHub job/step metadata and bounded lifecycle fields; prompt text, provider responses, repository file content, and provider API credentials are not part of the notification contract.

## Optional channels

External delivery is opt-in. Until configured, the gateway still classifies lifecycle events and records its Actions summary but does not send email or Slack messages.

### Email

Variables:

- `AGENT_NOTIFICATION_EMAIL_ENABLED=true`
- `AGENT_NOTIFICATION_EMAIL_TO=<recipient>` (falls back to `BILLING_ALERT_EMAIL_TO` in the workflow)
- existing SMTP variables: `BILLING_SMTP_HOST`, `BILLING_SMTP_PORT`, `BILLING_SMTP_FROM`, `BILLING_SMTP_STARTTLS`, `BILLING_SMTP_SSL`

Secrets:

- `BILLING_SMTP_USER`
- `BILLING_SMTP_PASSWORD`

Email subjects use `[Agent Dispatch][TASK_COMPLETED]`, `[TASK_FAILED]`, or `[ACTION_REQUIRED]`, which can be used as a Gmail event-trigger filter in ChatGPT Work.

### Slack

Variable:

- `AGENT_NOTIFICATION_SLACK_ENABLED=true`

Secret:

- `AGENT_NOTIFICATION_SLACK_WEBHOOK_URL`

A dedicated Slack channel can then be monitored by a ChatGPT Work event-triggered task. Add `@ChatGPT` to that channel before creating the task.

## Expected latency

The design is event-driven rather than hourly/five-minute polling. Delivery begins after GitHub publishes the source `workflow_run: completed` event. Exact end-to-end latency is controlled by GitHub, the selected notification service, and ChatGPT's event-trigger processing, so no fixed seconds-level SLA is assumed.

## Failure behavior

Notification delivery is best-effort and never changes the originating agent task result. Missing notification configuration or a mail/Slack delivery outage is logged by the notifier workflow, while the original Agent Dispatch or Review Repair outcome remains authoritative.
