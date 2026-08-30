const http = require('http');

function request(method, host, port, path, auth, body) {
  return new Promise((resolve, reject) => {
    const headers = { 'Content-Type': 'application/json' };
    if (auth) headers['Authorization'] = 'Bearer ' + auth;
    const opts = { hostname: host, port: Number(port), path, method, headers };
    const r = http.request(opts, (res) => {
      let data = '';
      res.on('data', c => data += c);
      res.on('end', () => resolve({ status: res.statusCode, body: data }));
    });
    r.on('error', reject);
    if (body) r.end(JSON.stringify(body));
    else r.end();
  });
}

async function main() {
  const [method, host, port, path, auth, bodyStr] = process.argv.slice(2);
  const body = bodyStr ? JSON.parse(bodyStr) : null;
  try {
    const result = await request(method, host, port, path, auth || null, body);
    process.stdout.write(JSON.stringify(result));
  } catch (e) {
    process.stdout.write(JSON.stringify({ status: 0, body: 'error: ' + e.message }));
  }
}

main();