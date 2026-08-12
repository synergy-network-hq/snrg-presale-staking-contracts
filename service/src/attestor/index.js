import 'dotenv/config';
import fs from 'fs';
import { Contract, JsonRpcProvider, Wallet, getAddress } from 'ethers';
import { ATTESTOR_REGISTRY_ABI } from '../shared/abis.js';
import { required, integer } from '../shared/env.js';
import { AttestorSourceValidator } from './source-validator.js';
import { startAttestorServer } from './server.js';

async function loadSigner() {
  const encrypted = fs.readFileSync(required('ATTESTOR_KEYSTORE_PATH'), 'utf8');
  const password = fs.readFileSync(required('ATTESTOR_KEYSTORE_PASSWORD_FILE'), 'utf8').trimEnd();
  if (!password) throw new Error('attestor keystore password file is empty');
  return Wallet.fromEncryptedJson(encrypted, password);
}

async function main() {
  const signer = await loadSigner();
  const epochId = integer('ATTESTOR_EPOCH_ID');
  const registryAddress = getAddress(required('ATTESTOR_REGISTRY_ADDRESS'));
  const ethereumProvider = new JsonRpcProvider(required('ETHEREUM_RPC_URL'), 1);
  const registry = new Contract(registryAddress, ATTESTOR_REGISTRY_ABI, ethereumProvider);
  const [epoch, authorized] = await Promise.all([
    registry.epoch(epochId),
    registry.isAttestor(epochId, signer.address),
  ]);
  if (!epoch.active || Number(epoch.threshold) !== 2 || Number(epoch.attestorCount) !== 3) {
    throw new Error('on-chain attestor epoch is not active 2-of-3');
  }
  if (!authorized) throw new Error(`keystore address ${signer.address} is not authorized in epoch ${epochId}`);

  const validator = new AttestorSourceValidator({
    rpcUrl: required('BASE_RPC_URL'),
    stakingAddress: getAddress(required('BASE_STAKING_ADDRESS')),
    deployBlock: integer('BASE_STAKING_DEPLOY_BLOCK'),
  });
  startAttestorServer({
    host: process.env.ATTESTOR_BIND_HOST || '127.0.0.1',
    port: integer('ATTESTOR_PORT', 9443),
    certPath: required('MTLS_SERVER_CERT'),
    keyPath: required('MTLS_SERVER_KEY'),
    caPath: required('MTLS_CA_CERT'),
    validator,
    signer,
    verifierAddress: getAddress(required('ATTESTATION_VERIFIER_ADDRESS')),
    epochId,
  });
}

main().catch(error => {
  console.error(error.stack || error.message);
  process.exit(1);
});
