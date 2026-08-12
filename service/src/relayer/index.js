import 'dotenv/config';
import fs from 'fs';
import { TypedDataEncoder, Wallet, getAddress } from 'ethers';
import { required, integer } from '../shared/env.js';
import {
  STAKING_ATTESTATION_TYPES,
  buildAttestation,
  eip712Domain,
  jsonStringify,
} from '../shared/codec.js';
import { startOperationalServer } from '../shared/operational-server.js';
import { ThresholdAttestorClient } from './attestor-client.js';
import { StakingRelayerStore } from './store.js';
import { EthereumGatewaySubmitter } from './submitter.js';
import { BaseStakingWatcher } from './watcher.js';

const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

async function loadRelayerSigner() {
  const encrypted = fs.readFileSync(required('ETHEREUM_RELAYER_KEYSTORE_PATH'), 'utf8');
  const password = fs.readFileSync(required('ETHEREUM_RELAYER_KEYSTORE_PASSWORD_FILE'), 'utf8').trimEnd();
  if (!password) throw new Error('relayer keystore password file is empty');
  return Wallet.fromEncryptedJson(encrypted, password);
}

async function main() {
  const stakingAddress = getAddress(required('BASE_STAKING_ADDRESS'));
  const verifierAddress = getAddress(required('ATTESTATION_VERIFIER_ADDRESS'));
  const pollMs = integer('RELAYER_POLL_MS', 12000);
  const ttlSeconds = integer('ATTESTATION_TTL_SECONDS', 3600);
  if (ttlSeconds < 300 || ttlSeconds > 86400) throw new Error('ATTESTATION_TTL_SECONDS must be 300..86400');

  const store = new StakingRelayerStore(required('SQLITE_DB_PATH'));
  store.initialize();
  store.recoverInterrupted();

  const watcher = new BaseStakingWatcher({
    rpcUrl: required('BASE_RPC_URL'),
    stakingAddress,
    startBlock: integer('BASE_STAKING_DEPLOY_BLOCK'),
    batchSize: integer('BASE_SCAN_BATCH_SIZE', 1500),
    store,
  });
  const attestors = new ThresholdAttestorClient({
    configPath: required('ATTESTOR_SET_CONFIG'),
    caPath: required('MTLS_CA_CERT'),
    certPath: required('MTLS_CLIENT_CERT'),
    keyPath: required('MTLS_CLIENT_KEY'),
    ethereumRpcUrl: required('ETHEREUM_RPC_URL'),
    registryAddress: getAddress(required('ATTESTOR_REGISTRY_ADDRESS')),
    verifierAddress,
    timeoutMs: integer('ATTESTOR_TIMEOUT_MS', 20000),
  });
  await attestors.assertOnChainConfiguration();

  const relayerSigner = await loadRelayerSigner();
  const submitter = new EthereumGatewaySubmitter({
    rpcUrl: required('ETHEREUM_RPC_URL'),
    signer: relayerSigner,
    gatewayAddress: getAddress(required('REWARD_GATEWAY_ADDRESS')),
    confirmations: integer('ETHEREUM_CONFIRMATIONS', 2),
  });

  const state = { ready: true };
  const operational = startOperationalServer({
    host: process.env.RELAYER_HEALTH_HOST || '127.0.0.1',
    port: integer('RELAYER_HEALTH_PORT', 9460),
    snapshot: () => ({ ...state, store: store.operationalSnapshot() }),
  });

  let stopping = false;
  process.on('SIGINT', () => { stopping = true; });
  process.on('SIGTERM', () => { stopping = true; });

  while (!stopping) {
    try {
      const discovered = await watcher.scanOnce();
      if (discovered) console.log(`[Relayer] discovered ${discovered} finalized Base staking events`);
      for (const row of store.pendingEvents()) {
        store.markProcessing(row.id);
        try {
          const event = row.payload;
          const now = BigInt(Math.floor(Date.now() / 1000));
          let attestation = row.attestation;
          let signatures = row.signatures;
          if (!attestation || !signatures || BigInt(attestation.expiry) <= now + 120n) {
            attestation = buildAttestation({
              action: event.action,
              commitment: event.commitment,
              reason: event.reason,
              locator: event.locator,
              epochId: attestors.epochId,
              expiry: now + BigInt(ttlSeconds),
            });
            const request = JSON.parse(jsonStringify({
              version: 1,
              action: event.action,
              reason: event.reason,
              commitment: event.commitment,
              openLocator: event.openLocator,
              actionLocator: event.locator,
              attestation,
            }));
            signatures = await attestors.collect(request);
            store.saveAttestation(row.id, attestation, signatures);
          }

          const domain = eip712Domain(verifierAddress);
          TypedDataEncoder.hash(domain, STAKING_ATTESTATION_TYPES, attestation);
          if (await submitter.alreadyConsumed(event.sourceEventId)) {
            store.markDone(row.id);
            continue;
          }
          const receipt = await submitter.submit({
            action: event.action,
            commitment: event.commitment,
            reason: event.reason,
            attestation,
            signatures,
            onSubmitted: transactionHash => store.markSubmitted(row.id, transactionHash),
          });
          store.markDone(row.id, receipt.hash, receipt.rewardTokenId);
          console.log(`[Relayer] ${event.action} ${event.rewardId} confirmed on Ethereum in ${receipt.hash}`);
        } catch (error) {
          const attempts = Number(row.attempt_count) + 1;
          store.markRetry(row.id, error.message, Math.min(300, 5 * (2 ** Math.min(attempts, 6))));
          console.error(`[Relayer] source event ${row.id} failed: ${error.message}`);
        }
      }
    } catch (error) {
      state.ready = false;
      console.error(`[Relayer] scan loop error: ${error.stack || error.message}`);
    }
    await sleep(pollMs);
    state.ready = true;
  }
  operational.close();
  store.close();
}

main().catch(error => {
  console.error(error.stack || error.message);
  process.exit(1);
});
