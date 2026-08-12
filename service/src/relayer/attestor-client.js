import fs from 'fs';
import https from 'https';
import { Contract, JsonRpcProvider, TypedDataEncoder, getAddress, verifyTypedData } from 'ethers';
import { ATTESTOR_REGISTRY_ABI } from '../shared/abis.js';
import { STAKING_ATTESTATION_TYPES, eip712Domain, jsonStringify } from '../shared/codec.js';

function requestJson(url, { method = 'GET', body, agent, timeoutMs }) {
  return new Promise((resolve, reject) => {
    const parsed = new URL(url);
    if (parsed.protocol !== 'https:') return reject(new Error('attestor URL must use HTTPS'));
    const headers = body === undefined
      ? undefined
      : { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) };
    const request = https.request(parsed, {
      method,
      agent,
      timeout: timeoutMs,
      headers,
    }, response => {
      const chunks = [];
      response.on('data', chunk => chunks.push(chunk));
      response.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8');
        if (response.statusCode !== 200) return reject(new Error(`attestor ${parsed.host} rejected request`));
        try { resolve(JSON.parse(text)); } catch { reject(new Error(`attestor ${parsed.host} returned invalid JSON`)); }
      });
    });
    request.on('timeout', () => request.destroy(new Error(`attestor ${parsed.host} timed out`)));
    request.on('error', reject);
    request.end(body);
  });
}

export function evaluateAttestorReadiness({ epoch, configuredAddresses, authorizedAddresses, healthResponses }) {
  const configured = configuredAddresses.map(address => getAddress(address));
  const authorized = new Set(authorizedAddresses.map(address => getAddress(address).toLowerCase()));
  const epochActive = epoch.active === true
    && Number(epoch.threshold) === 2
    && Number(epoch.attestorCount) === 3;
  const registryEpochActive = epochActive
    && configured.every(address => authorized.has(address.toLowerCase()));
  const reachable = new Set();
  if (registryEpochActive) {
    for (const response of healthResponses) {
      if (response.status !== 'fulfilled') continue;
      try {
        const address = getAddress(response.value.attestor);
        if (response.value.ok !== true) continue;
        if (Number(response.value.epochId) !== Number(epoch.epochId)) continue;
        if (!authorized.has(address.toLowerCase())) continue;
        reachable.add(address.toLowerCase());
      } catch {
        // Malformed or unauthorised health responses do not count toward quorum.
      }
    }
  }
  return {
    registryEpochActive,
    attestorQuorumReady: registryEpochActive && reachable.size >= 2,
    reachableAttestors: reachable.size,
  };
}

export class ThresholdAttestorClient {
  constructor({ configPath, caPath, certPath, keyPath, ethereumRpcUrl, registryAddress, verifierAddress, timeoutMs = 20000 }) {
    this.config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    this.agent = new https.Agent({
      ca: fs.readFileSync(caPath),
      cert: fs.readFileSync(certPath),
      key: fs.readFileSync(keyPath),
      minVersion: 'TLSv1.3',
      keepAlive: true,
    });
    this.timeoutMs = timeoutMs;
    this.verifierAddress = getAddress(verifierAddress);
    this.registry = new Contract(
      getAddress(registryAddress),
      ATTESTOR_REGISTRY_ABI,
      new JsonRpcProvider(ethereumRpcUrl, 1),
    );
    if (!Number.isSafeInteger(this.config.epochId) || this.config.epochId <= 0) throw new Error('invalid attestor epoch');
    if (!Array.isArray(this.config.attestors) || this.config.attestors.length !== 3) throw new Error('exactly three attestors required');
    const addresses = this.config.attestors.map(item => getAddress(item.address));
    if (new Set(addresses.map(address => address.toLowerCase())).size !== 3) throw new Error('attestor addresses must be unique');
  }

  get epochId() { return this.config.epochId; }

  async assertOnChainConfiguration() {
    const epoch = await this.registry.epoch(this.epochId);
    if (!epoch.active || Number(epoch.threshold) !== 2 || Number(epoch.attestorCount) !== 3) {
      throw new Error('on-chain epoch is not active 2-of-3');
    }
    for (const item of this.config.attestors) {
      if (!await this.registry.isAttestor(this.epochId, getAddress(item.address))) {
        throw new Error(`configured attestor ${item.address} is not authorized on-chain`);
      }
    }
  }

  async readiness() {
    const configuredAddresses = this.config.attestors.map(item => getAddress(item.address));
    let epoch;
    let authorizedAddresses = [];
    try {
      const onChainEpoch = await this.registry.epoch(this.epochId);
      epoch = {
        epochId: this.epochId,
        active: onChainEpoch.active,
        threshold: Number(onChainEpoch.threshold),
        attestorCount: Number(onChainEpoch.attestorCount),
      };
      const membership = await Promise.all(configuredAddresses.map(address => (
        this.registry.isAttestor(this.epochId, address)
      )));
      authorizedAddresses = configuredAddresses.filter((_, index) => membership[index]);
    } catch {
      return { registryEpochActive: false, attestorQuorumReady: false, reachableAttestors: 0 };
    }

    const healthResponses = await Promise.allSettled(this.config.attestors.map(item => (
      requestJson(new URL('/healthz', item.url), {
        method: 'GET',
        agent: this.agent,
        timeoutMs: this.timeoutMs,
      })
    )));
    return evaluateAttestorReadiness({ epoch, configuredAddresses, authorizedAddresses, healthResponses });
  }

  async collect(request) {
    const body = jsonStringify(request);
    const domain = eip712Domain(this.verifierAddress);
    const digest = TypedDataEncoder.hash(domain, STAKING_ATTESTATION_TYPES, request.attestation);
    const configured = new Map(this.config.attestors.map(item => [getAddress(item.address).toLowerCase(), item]));
    const settled = await Promise.allSettled(this.config.attestors.map(item => (
      requestJson(new URL('/v1/attest', item.url), {
        method: 'POST',
        body,
        agent: this.agent,
        timeoutMs: this.timeoutMs,
      })
    )));
    const signatures = [];
    for (const result of settled) {
      if (result.status !== 'fulfilled') continue;
      const response = result.value;
      if (String(response.digest).toLowerCase() !== digest.toLowerCase()) continue;
      let recovered;
      try {
        recovered = getAddress(verifyTypedData(domain, STAKING_ATTESTATION_TYPES, request.attestation, response.signature));
      } catch {
        continue;
      }
      if (!configured.has(recovered.toLowerCase())) continue;
      signatures.push({ signer: recovered, signature: response.signature });
    }
    const unique = new Map(signatures.map(item => [item.signer.toLowerCase(), item]));
    const ordered = [...unique.values()].sort((left, right) => (
      BigInt(left.signer) < BigInt(right.signer) ? -1 : 1
    ));
    if (ordered.length < 2) throw new Error(`attestor threshold not met (${ordered.length}/2)`);
    for (const item of ordered) {
      if (!await this.registry.isAttestor(this.epochId, item.signer)) {
        throw new Error(`recovered signer ${item.signer} is no longer authorized`);
      }
    }
    return ordered.map(item => item.signature);
  }
}
