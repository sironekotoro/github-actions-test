#!/usr/bin/env python3
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def send_json(self, status, body):
        raw = json.dumps(body).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        path = urlparse(self.path).path
        mode = os.environ.get('MOCK_MODE', 'ok')
        if mode == 'http500':
            self.send_json(500, {'error': 'fixture'})
            return
        if path == '/credits':
            self.send_json(200, {
                'data': {
                    'total_credits': float(os.environ.get('MOCK_TOTAL_CREDITS', '10')),
                    'total_usage': float(os.environ.get('MOCK_TOTAL_USAGE', '9')),
                }
            })
            return
        if path == '/key':
            raw = os.environ.get('MOCK_KEY_REMAINING', 'null')
            remaining = None if raw == 'null' else float(raw)
            self.send_json(200, {'data': {'limit_remaining': remaining}})
            return
        if path == '/openai-costs':
            amount = float(os.environ.get('MOCK_OPENAI_COST', '0.75'))
            self.send_json(200, {
                'object': 'page',
                'data': [{'results': [{'amount': {'value': amount, 'currency': 'usd'}}]}],
                'has_more': False,
                'next_page': None,
            })
            return
        if path.endswith('/actions/runners'):
            labels = [
                {'name': 'self-hosted'}, {'name': 'review-repair'},
                {'name': 'macOS'}, {'name': 'ARM64'},
            ]
            if mode == 'runner-idle':
                runners = [{'name': 'mock-idle', 'status': 'online', 'busy': False, 'labels': labels}]
            elif mode == 'runner-busy':
                runners = [{'name': 'mock-busy', 'status': 'online', 'busy': True, 'labels': labels}]
            elif mode == 'runner-offline':
                runners = [{'name': 'mock-offline', 'status': 'offline', 'busy': False, 'labels': labels}]
            elif mode == 'runner-wrong-labels':
                runners = [{'name': 'mock-other', 'status': 'online', 'busy': False, 'labels': [{'name': 'self-hosted'}]}]
            else:
                runners = []
            self.send_json(200, {'total_count': len(runners), 'runners': runners})
            return
        self.send_json(404, {'error': 'not found'})


def main():
    port = int(os.environ.get('MOCK_PORT', '0'))
    server = HTTPServer(('127.0.0.1', port), Handler)
    actual = server.server_address[1]
    print(actual, flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
