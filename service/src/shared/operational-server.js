import http from 'node:http';

function writeJson(res, statusCode, body) {
  res.writeHead(statusCode, {
    'cache-control': 'no-store',
    'content-type': 'application/json; charset=utf-8',
    'x-content-type-options': 'nosniff',
  });
  res.end(JSON.stringify(body));
}

export class OperationalStatus {
  constructor(serviceName, snapshotProvider = () => ({})) {
    this.serviceName = serviceName;
    this.snapshotProvider = snapshotProvider;
    this.ready = false;
    this.errors = 0;
    this.lastSuccessAt = 0;
  }

  markReady() { this.ready = true; this.lastSuccessAt = Math.floor(Date.now() / 1000); }
  markError() { this.ready = false; this.errors += 1; }

  snapshot() {
    const source = this.snapshotProvider() || {};
    return {
      ready: this.ready,
      errors: this.errors,
      lastSuccessAt: this.lastSuccessAt,
      finalizedBaseBlock: Number(source.finalizedBaseBlock || 0),
      finalizedEthereumBlock: Number(source.finalizedEthereumBlock || 0),
      pendingEvents: Number(source.pendingEvents || 0),
      processingEvents: Number(source.processingEvents || 0),
      submittedEvents: Number(source.submittedEvents || 0),
    };
  }
}

function prometheusMetric(name, value) {
  return `${name} ${Number.isFinite(Number(value)) ? Number(value) : 0}`;
}

export async function startOperationalServer({ status, host = '127.0.0.1', port = 9468 }) {
  if (!(status instanceof OperationalStatus)) throw new Error('OperationalStatus is required');
  if (!['127.0.0.1', '::1', 'localhost'].includes(host)) throw new Error('Operational endpoint may only bind a loopback host');
  const server = http.createServer((req, res) => {
    const state = status.snapshot();
    if (req.method === 'GET' && (req.url === '/healthz' || req.url === '/readyz')) {
      const readiness = req.url === '/readyz';
      writeJson(res, readiness && !state.ready ? 503 : 200, {
        ok: readiness ? state.ready : true,
        service: status.serviceName,
        status: state.ready ? 'ready' : 'degraded',
      });
      return;
    }
    if (req.method === 'GET' && req.url === '/metrics') {
      const metrics = [
        '# HELP snrg_sxcp_relayer_ready Finalized-chain event cycle completed successfully.',
        '# TYPE snrg_sxcp_relayer_ready gauge',
        prometheusMetric('snrg_sxcp_relayer_ready', state.ready ? 1 : 0),
        '# HELP snrg_sxcp_relayer_errors_total Non-sensitive operational failures since process start.',
        '# TYPE snrg_sxcp_relayer_errors_total counter',
        prometheusMetric('snrg_sxcp_relayer_errors_total', state.errors),
        '# HELP snrg_sxcp_relayer_last_success_unixtime Last successful finalized-chain cycle.',
        '# TYPE snrg_sxcp_relayer_last_success_unixtime gauge',
        prometheusMetric('snrg_sxcp_relayer_last_success_unixtime', state.lastSuccessAt),
        '# HELP snrg_sxcp_finalized_base_block Last persisted finalized Base block.',
        '# TYPE snrg_sxcp_finalized_base_block gauge',
        prometheusMetric('snrg_sxcp_finalized_base_block', state.finalizedBaseBlock),
        '# HELP snrg_sxcp_finalized_ethereum_block Last observed finalized Ethereum block.',
        '# TYPE snrg_sxcp_finalized_ethereum_block gauge',
        prometheusMetric('snrg_sxcp_finalized_ethereum_block', state.finalizedEthereumBlock),
        '# HELP snrg_sxcp_pending_events Pending source events.',
        '# TYPE snrg_sxcp_pending_events gauge',
        prometheusMetric('snrg_sxcp_pending_events', state.pendingEvents),
        '# HELP snrg_sxcp_processing_events Claimed source events.',
        '# TYPE snrg_sxcp_processing_events gauge',
        prometheusMetric('snrg_sxcp_processing_events', state.processingEvents),
        '# HELP snrg_sxcp_submitted_events Submitted but not yet fully reconciled events.',
        '# TYPE snrg_sxcp_submitted_events gauge',
        prometheusMetric('snrg_sxcp_submitted_events', state.submittedEvents),
        '',
      ].join('\n');
      res.writeHead(200, {
        'cache-control': 'no-store',
        'content-type': 'text/plain; version=0.0.4; charset=utf-8',
        'x-content-type-options': 'nosniff',
      });
      res.end(metrics);
      return;
    }
    res.writeHead(404, { 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' });
    res.end();
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(Number(port), host, () => {
      server.off('error', reject);
      resolve();
    });
  });
  return server;
}
