import fs from 'fs';
import https from 'https';
import { TypedDataEncoder } from 'ethers';
import { STAKING_ATTESTATION_TYPES, eip712Domain, jsonStringify } from '../shared/codec.js';

function readBody(request, maxBytes = 128 * 1024) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    request.on('data', chunk => {
      total += chunk.length;
      if (total > maxBytes) {
        reject(new Error('request body too large'));
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    request.on('error', reject);
  });
}

export function startAttestorServer({ host, port, certPath, keyPath, caPath, validator, signer, verifierAddress, epochId }) {
  const metrics = { requests: 0, signatures: 0, rejected: 0 };
  const server = https.createServer({
    cert: fs.readFileSync(certPath),
    key: fs.readFileSync(keyPath),
    ca: fs.readFileSync(caPath),
    requestCert: true,
    rejectUnauthorized: true,
    minVersion: 'TLSv1.3',
  }, async (request, response) => {
    metrics.requests += 1;
    try {
      if (!request.socket.authorized) throw new Error('unauthorized mTLS client');
      if (request.method === 'GET' && request.url === '/healthz') {
        response.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' });
        response.end(JSON.stringify({ ok: true, attestor: signer.address, epochId }));
        return;
      }
      if (request.method === 'GET' && request.url === '/metrics') {
        response.writeHead(200, { 'content-type': 'text/plain; version=0.0.4', 'cache-control': 'no-store' });
        response.end([
          `synergy_staking_attestor_requests_total ${metrics.requests}`,
          `synergy_staking_attestor_signatures_total ${metrics.signatures}`,
          `synergy_staking_attestor_rejected_total ${metrics.rejected}`,
          '',
        ].join('\n'));
        return;
      }
      if (request.method !== 'POST' || request.url !== '/v1/attest') {
        response.writeHead(404);
        response.end('not found');
        return;
      }

      const payload = JSON.parse(await readBody(request));
      const attestation = await validator.validate(payload, epochId);
      const domain = eip712Domain(verifierAddress);
      const signature = await signer.signTypedData(domain, STAKING_ATTESTATION_TYPES, attestation);
      const digest = TypedDataEncoder.hash(domain, STAKING_ATTESTATION_TYPES, attestation);
      metrics.signatures += 1;
      response.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' });
      response.end(jsonStringify({ address: signer.address, epochId, digest, signature }));
    } catch (error) {
      metrics.rejected += 1;
      response.writeHead(400, { 'content-type': 'application/json', 'cache-control': 'no-store' });
      response.end(JSON.stringify({ error: error.message }));
    }
  });
  server.listen(port, host, () => console.log(`[Attestor] HTTPS/mTLS listening on ${host}:${port}`));
  return server;
}
