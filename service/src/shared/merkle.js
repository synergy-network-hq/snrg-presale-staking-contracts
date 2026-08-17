import { AbiCoder, hexlify, keccak256 } from 'ethers';
import { WITNESS_LEAF_TYPEHASH } from './codec.js';

const coder = AbiCoder.defaultAbiCoder();

function hashPair(a, b) {
  const [left, right] = BigInt(a) < BigInt(b) ? [a, b] : [b, a];
  return keccak256(new Uint8Array(Buffer.concat([Buffer.from(left.slice(2), 'hex'), Buffer.from(right.slice(2), 'hex')])));
}

export function witnessLeaf(witness, keyVersion) {
  const publicKey = hexlify(Buffer.from(witness.publicKeyBase64, 'base64'));
  return keccak256(coder.encode(['bytes32', 'bytes32', 'uint8', 'bytes32', 'uint64'], [WITNESS_LEAF_TYPEHASH, witness.witnessId, 1, keccak256(publicKey), BigInt(keyVersion)]));
}

export function buildWitnessTree(witnesses, keyVersion) {
  if (!Array.isArray(witnesses) || witnesses.length === 0) throw new Error('witness set is empty');
  const ordered = [...witnesses].sort((a, b) => BigInt(a.witnessId) < BigInt(b.witnessId) ? -1 : 1);
  const leaves = ordered.map(w => witnessLeaf(w, keyVersion));
  const layers = [leaves];
  while (layers.at(-1).length > 1) {
    const current = layers.at(-1);
    const next = [];
    for (let index = 0; index < current.length; index += 2) next.push(index + 1 === current.length ? current[index] : hashPair(current[index], current[index + 1]));
    layers.push(next);
  }
  const proofs = new Map();
  for (let leafIndex = 0; leafIndex < leaves.length; leafIndex += 1) {
    const proof = [];
    let index = leafIndex;
    for (let layerIndex = 0; layerIndex < layers.length - 1; layerIndex += 1) {
      const layer = layers[layerIndex];
      const sibling = index % 2 === 0 ? index + 1 : index - 1;
      if (sibling < layer.length) proof.push(layer[sibling]);
      index = Math.floor(index / 2);
    }
    proofs.set(ordered[leafIndex].witnessId.toLowerCase(), proof);
  }
  return { root: layers.at(-1)[0], ordered, leaves, proofs };
}
