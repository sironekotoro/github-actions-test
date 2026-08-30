#!/usr/bin/env node
const http = require('http');
const port = parseInt(process.env.MOCK_PORT || '0', 10);

const server = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://localhost');
  const path = u.pathname;
  const send = (status, body) => {
    const raw = Buffer.from(JSON.stringify(body));
    res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': raw.length });
    res.end(raw);
  };
  const collectBody = () => new Promise((resolve) => {
    let data = '';
    req.on('data', c => data += c);
    req.on('end', () => resolve(data ? JSON.parse(data) : {}));
  });

  if (req.method === 'GET') {
    if (path === '/api/v1/models') {
      return send(200, { data: [{ id: process.env.MOCK_MODEL || 'openrouter/deepseek/deepseek-v4-flash' }] });
    }
    if (path === '/health') return send(200, { status: 'ok' });
    return send(404, { error: 'not found' });
  }

  if (req.method === 'POST') {
    if (path === '/api/v1/keys') {
      const mgmt = process.env.MOCK_MANAGEMENT_MODE || 'ok';
      if (mgmt === 'http500') return send(500, { error: 'fixture error' });
      collectBody().then(parsed => {
        // Reject models field: official API does not support it
        if (parsed.models) {
          return send(400, { error: 'unsupported field: models' });
        }
        send(201, {
          key: 'sk-or-mock-provisioned-key-123456789',
          data: { hash: 'mock-hash-001', limit: parsed.limit || 0.25, limit_reset: null, expires_at: parsed.expires_at || null }
        });
      });
      return;
    }
    if (path.startsWith('/api/v1/keys/')) {
      return send(200, { deleted: true });
    }
    if (path === '/api/v1/chat/completions' || path === '/api/v1/completions') {
      collectBody().then(async parsed => {
        const delay = parseInt(process.env.MOCK_DELAY_MS || '0', 10);
        if (delay > 0) await new Promise(r => setTimeout(r, delay));
        const model = parsed.model || '';
        send(200, {
          id: 'mock-completion', object: 'chat.completion', model,
          choices: [{ message: { role: 'assistant', content: 'mock response' } }]
        });
      });
      return;
    }
    return send(404, { error: 'not found' });
  }

  if (req.method === 'DELETE') {
    if (path.startsWith('/api/v1/keys/')) {
      const delMode = process.env.MOCK_DELETE_MODE || 'ok';
      if (delMode === 'http500') return send(500, { error: 'delete failed' });
      return send(200, { deleted: true });
    }
    return send(404, { error: 'not found' });
  }

  send(405, { error: 'method not allowed' });
});

server.listen(port, '127.0.0.1', () => {
  console.log(String(server.address().port));
});