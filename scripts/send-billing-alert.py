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


def safe(value: str) -> str:
    return (value or '').replace('\r', ' ').replace('\n', ' ').replace('\x00', ' ')


def main() -> int:
    if not truthy('BILLING_EMAIL_ENABLED', False):
        print('[INFO] billing email disabled')
        return 0

    host = safe(os.getenv('BILLING_SMTP_HOST', ''))
    port_raw = safe(os.getenv('BILLING_SMTP_PORT', '587'))
    sender = safe(os.getenv('BILLING_SMTP_FROM', ''))
    recipient = safe(os.getenv('BILLING_ALERT_EMAIL_TO', ''))
    username = os.getenv('BILLING_SMTP_USER', '')
    password = os.getenv('BILLING_SMTP_PASSWORD', '')
    if not host or not sender or not recipient:
        print('[WARN] billing email configuration incomplete', file=sys.stderr)
        return 2
    try:
        port = int(port_raw)
        if port < 1 or port > 65535:
            raise ValueError
    except ValueError:
        print('[WARN] invalid billing SMTP port', file=sys.stderr)
        return 2

    provider = safe(os.getenv('BUDGET_PROVIDER', 'unknown'))
    state = safe(os.getenv('BUDGET_STATE', 'unknown'))
    available = safe(os.getenv('BUDGET_AVAILABLE_USD', '')) or 'unknown'
    floor = safe(os.getenv('BUDGET_HARD_FLOOR_USD', '')) or 'unknown'
    reserve = safe(os.getenv('BUDGET_REQUIRED_JOB_RESERVE_USD', '')) or 'unknown'
    task_id = safe(os.getenv('TASK_ID', '')) or 'n/a'
    run_url = safe(os.getenv('RUN_URL', '')) or 'n/a'
    alert_url = safe(os.getenv('BILLING_ALERT_URL', '')) or 'n/a'

    if state == 'recovered':
        subject = f'[Agent Dispatch] {provider} budget recovered'
        intro = 'Provider budget is back above the configured runnable threshold.'
    elif state == 'warning':
        subject = f'[Agent Dispatch] {provider} balance low - top-up review requested'
        intro = 'Provider balance is low. Please review or add funds while the protected floor and per-job reserve are still available.'
    elif state == 'blocked':
        subject = f'[Agent Dispatch] {provider} budget blocked - top-up required'
        intro = 'Paid inference was blocked because the protected minimum balance plus the configured per-job reserve could not both be preserved. Please add funds or increase the approved budget.'
    else:
        subject = f'[Agent Dispatch] {provider} budget status unknown - billing check required'
        intro = 'Paid inference was blocked because the budget state could not be established safely. Please check billing credentials and provider status.'

    msg = EmailMessage()
    msg['From'] = sender
    msg['To'] = recipient
    msg['Subject'] = subject
    msg.set_content(
        f'{intro}\n\n'
        f'Provider: {provider}\n'
        f'State: {state}\n'
        f'Observed available/budget USD: {available}\n'
        f'Protected floor USD: {floor}\n'
        f'Required per-job reserve USD: {reserve}\n'
        f'Task ID: {task_id}\n'
        f'Workflow run: {run_url}\n'
        f'GitHub billing alert: {alert_url}\n\n'
        'No API key, prompt, authorization header, or model response is included in this message.\n'
    )

    if truthy('BILLING_EMAIL_DRY_RUN', False):
        print(f'[INFO] billing email dry-run: {subject}')
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
        print('[WARN] billing email delivery failed', file=sys.stderr)
        return 3

    print('[INFO] billing email sent')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
