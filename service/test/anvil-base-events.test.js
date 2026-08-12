import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import net from 'node:net';
import { spawn } from 'node:child_process';
import {
  ContractFactory,
  Interface,
  JsonRpcProvider,
  NonceManager,
  Wallet,
  parseUnits,
} from 'ethers';

const artifacts = JSON.parse(
  fs.readFileSync(new URL('./fixtures/anvil-contracts.json', import.meta.url), 'utf8'),
);

const ANVIL_FIRST_ACCOUNT =
  'ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';
const DAY = 24 * 60 * 60;

async function reservePort() {
  const server = net.createServer();
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const { port } = server.address();
  await new Promise((resolve) => server.close(resolve));
  return port;
}

async function waitForRpc(url, child) {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    if (child.exitCode !== null) throw new Error(`Anvil exited with status ${child.exitCode}`);
    try {
      const response = await fetch(url, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_chainId', params: [] }),
      });
      if (response.ok) return;
    } catch {
      // The process is still booting.
    }
    await new Promise((resolve) => setTimeout(resolve, 40));
  }
  throw new Error('Timed out waiting for the local Anvil fixture');
}

function decodedEvent(receipt, contractInterface, name) {
  for (const log of receipt.logs) {
    try {
      const parsed = contractInterface.parseLog(log);
      if (parsed?.name === name) return parsed;
    } catch {
      // This log belongs to one of the mock ERC-20s.
    }
  }
  throw new Error(`Expected ${name} in receipt`);
}

test('Anvil fixture emits and reads the three canonical Base staking events', async (t) => {
  const port = await reservePort();
  const rpcUrl = `http://127.0.0.1:${port}`;
  const anvil = spawn(process.env.ANVIL_BIN ?? 'anvil', [
    '--host', '127.0.0.1',
    '--port', String(port),
    '--chain-id', '8453',
    '--silent',
  ], { stdio: 'ignore' });
  t.after(() => {
    if (anvil.exitCode === null) anvil.kill('SIGTERM');
  });
  await waitForRpc(rpcUrl, anvil);

  const provider = new JsonRpcProvider(rpcUrl, 8453, { staticNetwork: true });
  const signer = new NonceManager(new Wallet(ANVIL_FIRST_ACCOUNT, provider));
  const deploy = async (artifact, args) => {
    const factory = new ContractFactory(artifact.abi, artifact.bytecode, signer);
    const contract = await factory.deploy(...args);
    await contract.waitForDeployment();
    return contract;
  };

  const unlocked = await deploy(artifacts.mockStakeToken, ['Unlocked SNRG', 'uSNRG', 18]);
  const locked = await deploy(artifacts.mockStakeToken, ['Locked SNRG', 'lSNRG', 9]);
  // The adapter only needs a deployed contract address for this ERC-20-only fixture.
  const adapter = await deploy(artifacts.mockBaseVoucherAdapter, [await unlocked.getAddress()]);
  const staking = await deploy(artifacts.synergyBaseStaking, [
    await signer.getAddress(),
    await unlocked.getAddress(),
    await locked.getAddress(),
    await adapter.getAddress(),
    0,
    0,
  ]);
  const stakingAddress = await staking.getAddress();
  const stakeInterface = new Interface(artifacts.synergyBaseStaking.abi);

  const signerAddress = await signer.getAddress();
  await (await unlocked.mint(signerAddress, parseUnits('2000', 18))).wait();
  await (await unlocked.approve(stakingAddress, parseUnits('2000', 18))).wait();

  const openReceipt = await (await staking.stakeUnlockedSNRG(parseUnits('1000', 18), 0)).wait();
  const opened = decodedEvent(openReceipt, stakeInterface, 'RewardCommitmentOpened');
  assert.equal(opened.args.positionId, 1n);
  assert.equal(opened.args.beneficiary, signerAddress);
  assert.equal(opened.args.destinationChainId, 1n);
  assert.equal(opened.args.source, 0n);
  assert.equal(opened.args.principalNwei, 1_000_000_000_000n);
  assert.equal(opened.args.rewardNwei, 40_000_000_000n);

  await provider.send('evm_increaseTime', [90 * DAY + 1]);
  await provider.send('evm_mine', []);
  const settleReceipt = await (await staking.settle(1)).wait();
  const settled = decodedEvent(settleReceipt, stakeInterface, 'RewardSettlementAuthorized');
  assert.equal(settled.args.positionId, 1n);
  assert.equal(settled.args.rewardId, opened.args.rewardId);
  assert.equal(settled.args.rewardNwei, opened.args.rewardNwei);

  await (await staking.stakeUnlockedSNRG(parseUnits('500', 18), 1)).wait();
  const exitReceipt = await (await staking.earlyUnstake(2)).wait();
  const cancelled = decodedEvent(exitReceipt, stakeInterface, 'RewardCommitmentCancelled');
  assert.equal(cancelled.args.positionId, 2n);
  assert.equal(cancelled.args.beneficiary, signerAddress);
  assert.equal(cancelled.args.reason, 1n);
  assert.equal(cancelled.args.rewardNwei, 30_000_000_000n);
});
