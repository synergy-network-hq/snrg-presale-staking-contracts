import http from 'http';

const LOOPBACK = new Set(['127.0.0.1', '::1', 'localhost']);

export function startOperationalServer({ host = '127.0.0.1', port, snapshot }) {
  if (!LOOPBACK.has(host)) throw new Error('operational server must bind to loopback');
  const server = http.createServer((request, response) => {
    const state = snapshot();
    if (request.method === 'GET' && (request.url === '/healthz' || request.url === '/readyz')) {
      const ready = request.url === '/healthz' || state.ready === true;
      response.writeHead(ready ? 200 : 503, { 'content-type': 'application/json', 'cache-control': 'no-store' });
      response.end(JSON.stringify({ ok: ready, ready: state.ready === true }));
      return;
    }
    if (request.method === 'GET' && request.url === '/metrics') {
      const counts = state.store?.byStatus || {};
      const lines = [
        `synergy_staking_relayer_ready ${state.ready ? 1 : 0}`,
        ...Object.entries(counts).map(([status, count]) => `synergy_staking_relayer_events{status="${status}"} ${count}`),
        '',
      ];
      response.writeHead(200, { 'content-type': 'text/plain; version=0.0.4', 'cache-control': 'no-store' });
      response.end(lines.join('\n'));
      return;
    }
    response.writeHead(404);
    response.end('not found');
  });
  server.listen(port, host);
  return server;
}
