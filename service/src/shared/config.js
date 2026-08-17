import fs from 'node:fs';
import { getAddress, isAddress } from 'ethers';

export function required(name, environment = process.env) {
  const value = environment[name];
  if (!value) throw new Error(`Missing required environment variable ${name}`);
  return value;
}

export function optional(name, fallback = '', environment = process.env) {
  return environment[name] || fallback;
}

export function integer(name, fallback = null, environment = process.env) {
  const raw = environment[name];
  if (!raw) {
    if (fallback !== null) return fallback;
    throw new Error(`Missing required integer environment variable ${name}`);
  }
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < 0) throw new Error(`Invalid non-negative integer ${name}`);
  return value;
}

export function requiredAddress(name, environment = process.env) {
  const value = required(name, environment);
  if (!isAddress(value)) throw new Error(`${name} must be a valid EVM address`);
  return getAddress(value);
}

export function requireLoopbackHost(name, fallback = '127.0.0.1', environment = process.env) {
  const host = optional(name, fallback, environment);
  if (!['127.0.0.1', '::1', 'localhost'].includes(host)) throw new Error(`${name} must be loopback; use an authenticated local proxy for remote access`);
  return host;
}

export function requireReadableFile(name, environment = process.env) {
  const candidate = required(name, environment);
  const resolved = fs.realpathSync(candidate);
  if (!fs.statSync(resolved).isFile()) throw new Error(`${name} must resolve to a regular file`);
  return resolved;
}

/**
 * Production acceptance requires an explicitly audited verifier identity,
 * never an address that merely happens to return `true` in a test.
 */
export function rejectKnownMockConfiguration({ mldsaVerifierAddress, mldsaVerifierRuntimeCode, environment = process.env }) {
  const bannedAddresses = new Set((optional('TEST_ONLY_MLDSA_MOCK_ADDRESSES', '', environment)).split(',').map(value => value.trim().toLowerCase()).filter(Boolean));
  const bannedCodeHashes = new Set((optional('TEST_ONLY_MLDSA_MOCK_CODEHASHES', '', environment)).split(',').map(value => value.trim().toLowerCase()).filter(Boolean));
  if (bannedAddresses.has(mldsaVerifierAddress.toLowerCase())) throw new Error('ML-DSA verifier is a configured test-only mock address');
  if (bannedCodeHashes.has(mldsaVerifierRuntimeCode.toLowerCase())) throw new Error('ML-DSA verifier is a configured test-only mock runtime-code hash');
  if (optional('AEGIS_PRODUCTION_VERIFIER_AUDIT_ID', '', environment).trim().length === 0) throw new Error('AEGIS_PRODUCTION_VERIFIER_AUDIT_ID is required for production configuration');
}
