#!/usr/bin/env python3
import os
import smtplib
import ssl
import sys
from email.message import EmailMessage


def truthy(name: str, default: bool = False) -> bool:
    raw = os.getenv(name, '').strip().lower()
    if not raw:
        return default
    return raw in {'1', 'true', 'yes'}


def safe(value: str, limit: int = 1000) -> str:
    return (value or '').replace('\r', ' ').replace('\n', ' ').replace('\x00', ' ')[:limit]


def main() -> int:
    if not truthy('AGENT_NOTIFICATION_EMAIL_ENABLED', False):
        print('[INFO] agent notification email disabled')
        return 0

    host = safe(os.getenv('BILLING_SMTP_HOST', ''))
    port_raw = safe(os.getenv('BILLING_SMTP_PORT', '587'))
    sender = safe(os.getenv('BILLING_SMTP_FROM', ''))
    recipient = safe(os.getenv('AGENT_NOTIFICATION_EMAIL_TO', ''))
    username = os.getenv('BILLING_SMTP_USER', '')
    password = os.getenv('BILLING_SMTP_PASSWORD', '')
    if not host or not sender or not recipient:
        print('[WARN] agent notification email configuration incomplete', file=sys.stderr)
        return 2

    try:
        port = int(port_raw)
        if port < 1 or port > 65535:
            raise ValueError
    except ValueError:
        print('[WARN] invalid agent notification SMTP port', file=sys.stderr)
        return 2

    event = safe(os.getenv('NOTIFICATION_EVENT', 'unknown'))
    title = safe(os.getenv('NOTIFICATION_TITLE', 'Agent Dispatch notification'))
    task_id = safe(os.getenv('NOTIFICATION_TASK_ID', 'n/a'))
    target = safe(os.getenv('NOTIFICATION_TARGET_REPOSITORY', 'n/a'))
    reason = safe(os.getenv('NOTIFICATION_REASON', 'none'))
    run_url = safe(os.getenv('NOTIFICATION_RUN_URL', 'n/a'))
    source_url = safe(os.getenv('NOTIFICATION_SOURCE_URL', 'n/a')) or 'n/a'

    subject = f'[Agent Dispatch][{event}] {title}'[:200]
    msg = EmailMessage()
    msg['From'] = sender
    msg['To'] = recipient
    msg['Subject'] = subject
    msg.set_content(
        f'Event: {event}\n'
        f'Title: {title}\n'
        f'Task ID: {task_id}\n'
        f'Target repository: {target}\n'
        f'Reason: {reason}\n'
        f'Workflow run: {run_url}\n'
        f'Source: {source_url}\n\n'
        'This message contains lifecycle metadata only. No API key, prompt, '
        'authorization header, model response, or repository file content is included.\n'
    )

    if truthy('AGENT_NOTIFICATION_EMAIL_DRY_RUN', False):
        print(f'[INFO] agent notification email dry-run: {event}')
        return 0

    timeout = float(os.getenv('BILLING_SMTP_TIMEOUT_SECONDS', '15'))
    use_ssl = truthy('BILLING_SMTP_SSL', False)
    starttls = truthy('BILLING_SMTP_STARTTLS', True)
    context = ssl.create_default_context()
    try:
        if use_ssl:
            smtp = smtplib.SMTP_SSL(host, port, timeout=timeout, context=context)
        else:
            smtp = smtplib.SMTP(host, port, timeout=timeout)
        with smtp:
            smtp.ehlo()
            if starttls and not use_ssl:
                smtp.starttls(context=context)
                smtp.ehlo()
            if username:
                smtp.login(username, password)
            smtp.send_message(msg)
    except Exception:
        print('[WARN] agent notification email delivery failed', file=sys.stderr)
        return 3

    print('[INFO] agent notification email sent')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
