import assert from 'node:assert/strict';
import test from 'node:test';
import { evaluateAttestorReadiness } from '../src/relayer/attestor-client.js';

const ATTETSTORS = [
  '0x3Cf391B9896bbB03E27450eC045476e0536E35e1',
  '0x8FfCD5F979e934b5a09b8b078359FcaDD1636F12',
  '0xD915c5C5e0535abe875bF556C545A6c3ce025D24',
];

const epoch = { epochId: 1, active: true, threshold: 2, attestorCount: 3 };
const healthy = address => ({ status: 'fulfilled', value: { ok: true, attestor: address, epochId: 1 } });

test('readiness requires an active authorized epoch and two distinct live attestors', () => {
  const result = evaluateAttestorReadiness({
    epoch,
    configuredAddresses: ATTETSTORS,
    authorizedAddresses: ATTETSTORS,
    healthResponses: [healthy(ATTETSTORS[0]), healthy(ATTETSTORS[1]), { status: 'rejected' }],
  });
  assert.deepEqual(result, {
    registryEpochActive: true,
    attestorQuorumReady: true,
    reachableAttestors: 2,
  });
});

test('readiness fails closed when live attestor quorum is lost', () => {
  const result = evaluateAttestorReadiness({
    epoch,
    configuredAddresses: ATTETSTORS,
    authorizedAddresses: ATTETSTORS,
    healthResponses: [healthy(ATTETSTORS[0]), { status: 'rejected' }, { status: 'rejected' }],
  });
  assert.equal(result.registryEpochActive, true);
  assert.equal(result.attestorQuorumReady, false);
  assert.equal(result.reachableAttestors, 1);
});

test('readiness rejects wrong epochs, duplicate responses, and incomplete registry membership', () => {
  const wrongEpoch = healthy(ATTETSTORS[0]);
  wrongEpoch.value.epochId = 2;
  const result = evaluateAttestorReadiness({
    epoch,
    configuredAddresses: ATTETSTORS,
    authorizedAddresses: ATTETSTORS.slice(0, 2),
    healthResponses: [wrongEpoch, healthy(ATTETSTORS[1]), healthy(ATTETSTORS[1])],
  });
  assert.deepEqual(result, {
    registryEpochActive: false,
    attestorQuorumReady: false,
    reachableAttestors: 0,
  });
});
