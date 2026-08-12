import Database from 'better-sqlite3';
import fs from 'fs';
import path from 'path';
import { jsonStringify } from '../shared/codec.js';

const SCHEMA_VERSION = 3;

export class StakingRelayerStore {
  constructor(dbPath) {
    this.dbPath = dbPath;
    this.db = null;
  }

  initialize() {
    fs.mkdirSync(path.dirname(this.dbPath), { recursive: true });
    this.db = new Database(this.dbPath);
    this.db.pragma('journal_mode = WAL');
    this.db.pragma('synchronous = FULL');
    this.db.pragma('foreign_keys = ON');
    const version = this.db.pragma('user_version', { simple: true });
    if (version !== 0 && version !== SCHEMA_VERSION) {
      throw new Error(`unsupported relayer database schema ${version}; explicit migration required`);
    }
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS reward_commitments (
        reward_id TEXT PRIMARY KEY,
        commitment_json TEXT NOT NULL,
        open_locator_json TEXT NOT NULL,
        created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
      );
      CREATE TABLE IF NOT EXISTS source_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        source_event_id TEXT NOT NULL UNIQUE,
        chain_id INTEGER NOT NULL,
        block_number INTEGER NOT NULL,
        block_hash TEXT NOT NULL,
        block_timestamp INTEGER NOT NULL,
        tx_hash TEXT NOT NULL,
        log_index INTEGER NOT NULL,
        event_name TEXT NOT NULL,
        action TEXT NOT NULL,
        reward_id TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        attestation_json TEXT,
        signatures_json TEXT,
        ethereum_tx_hash TEXT,
        reward_token_id TEXT,
        status TEXT NOT NULL DEFAULT 'pending',
        attempt_count INTEGER NOT NULL DEFAULT 0,
        next_attempt_at INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        UNIQUE(chain_id, tx_hash, log_index)
      );
      CREATE TABLE IF NOT EXISTS checkpoints (
        chain_id INTEGER PRIMARY KEY,
        last_scanned_block INTEGER NOT NULL DEFAULT 0,
        finalized_block INTEGER NOT NULL DEFAULT 0,
        finalized_hash TEXT,
        updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
      );
      CREATE INDEX IF NOT EXISTS idx_source_events_status ON source_events(status,next_attempt_at,id);
      CREATE INDEX IF NOT EXISTS idx_source_events_reward ON source_events(reward_id);
      CREATE INDEX IF NOT EXISTS idx_source_events_eth_tx ON source_events(ethereum_tx_hash);
    `);
    this.db.pragma(`user_version = ${SCHEMA_VERSION}`);
  }

  recoverInterrupted() {
    this.db.prepare(`
      UPDATE source_events
      SET status='retry',next_attempt_at=0,last_error='Recovered after relayer restart',updated_at=CURRENT_TIMESTAMP
      WHERE status IN ('processing','submitted')
    `).run();
  }

  getCheckpoint(chainId) {
    return this.db.prepare('SELECT * FROM checkpoints WHERE chain_id=?').get(Number(chainId)) || {
      chain_id: Number(chainId), last_scanned_block: 0, finalized_block: 0, finalized_hash: null,
    };
  }

  setCheckpoint(chainId, lastScannedBlock, finalizedBlock, finalizedHash) {
    this.db.prepare(`
      INSERT INTO checkpoints(chain_id,last_scanned_block,finalized_block,finalized_hash,updated_at)
      VALUES(?,?,?,?,CURRENT_TIMESTAMP)
      ON CONFLICT(chain_id) DO UPDATE SET
        last_scanned_block=excluded.last_scanned_block,
        finalized_block=excluded.finalized_block,
        finalized_hash=excluded.finalized_hash,
        updated_at=CURRENT_TIMESTAMP
    `).run(Number(chainId), Number(lastScannedBlock), Number(finalizedBlock), finalizedHash);
  }

  putCommitment(commitment, openLocator) {
    const existing = this.getCommitment(commitment.rewardId);
    if (existing && jsonStringify(existing.commitment) !== jsonStringify(commitment)) {
      throw new Error(`reward commitment mismatch for ${commitment.rewardId}`);
    }
    this.db.prepare(`
      INSERT INTO reward_commitments(reward_id,commitment_json,open_locator_json)
      VALUES(?,?,?) ON CONFLICT(reward_id) DO NOTHING
    `).run(commitment.rewardId, jsonStringify(commitment), jsonStringify(openLocator));
  }

  getCommitment(rewardId) {
    const row = this.db.prepare('SELECT commitment_json,open_locator_json FROM reward_commitments WHERE reward_id=?').get(rewardId);
    if (!row) return null;
    return { commitment: JSON.parse(row.commitment_json), openLocator: JSON.parse(row.open_locator_json) };
  }

  recordSourceEvent(event) {
    try {
      const info = this.db.prepare(`
        INSERT INTO source_events(
          source_event_id,chain_id,block_number,block_hash,block_timestamp,tx_hash,log_index,event_name,action,reward_id,payload_json
        ) VALUES(?,?,?,?,?,?,?,?,?,?,?)
      `).run(
        event.sourceEventId,
        Number(event.chainId),
        Number(event.locator.sourceBlockNumber),
        event.locator.sourceBlockHash,
        Number(event.locator.sourceBlockTimestamp),
        event.locator.sourceTxHash,
        Number(event.locator.sourceLogIndex),
        event.eventName,
        event.action,
        event.rewardId,
        jsonStringify(event),
      );
      return Number(info.lastInsertRowid);
    } catch (error) {
      if (String(error.message).includes('UNIQUE constraint failed')) return null;
      throw error;
    }
  }

  pendingEvents(limit = 25) {
    const now = Math.floor(Date.now() / 1000);
    return this.db.prepare(`
      SELECT * FROM source_events
      WHERE status IN ('pending','retry','signed') AND next_attempt_at <= ?
      ORDER BY id ASC LIMIT ?
    `).all(now, limit).map(row => ({
      ...row,
      payload: JSON.parse(row.payload_json),
      attestation: row.attestation_json ? JSON.parse(row.attestation_json) : null,
      signatures: row.signatures_json ? JSON.parse(row.signatures_json) : null,
    }));
  }

  markProcessing(id) {
    this.db.prepare(`
      UPDATE source_events SET status='processing',attempt_count=attempt_count+1,updated_at=CURRENT_TIMESTAMP WHERE id=?
    `).run(id);
  }

  saveAttestation(id, attestation, signatures) {
    this.db.prepare(`
      UPDATE source_events SET attestation_json=?,signatures_json=?,status='signed',last_error=NULL,updated_at=CURRENT_TIMESTAMP
      WHERE id=?
    `).run(jsonStringify(attestation), jsonStringify(signatures), id);
  }

  markSubmitted(id, transactionHash) {
    this.db.prepare(`
      UPDATE source_events SET status='submitted',ethereum_tx_hash=?,updated_at=CURRENT_TIMESTAMP WHERE id=?
    `).run(transactionHash, id);
  }

  markDone(id, transactionHash = null, rewardTokenId = null) {
    this.db.prepare(`
      UPDATE source_events SET status='done',ethereum_tx_hash=COALESCE(?,ethereum_tx_hash),reward_token_id=?,last_error=NULL,updated_at=CURRENT_TIMESTAMP
      WHERE id=?
    `).run(transactionHash, rewardTokenId === null ? null : String(rewardTokenId), id);
  }

  markRetry(id, error, seconds) {
    const nextAttempt = Math.floor(Date.now() / 1000) + seconds;
    this.db.prepare(`
      UPDATE source_events SET status='retry',last_error=?,next_attempt_at=?,updated_at=CURRENT_TIMESTAMP WHERE id=?
    `).run(String(error).slice(0, 4000), nextAttempt, id);
  }

  operationalSnapshot() {
    const byStatus = Object.fromEntries(this.db.prepare(`
      SELECT status,COUNT(*) AS count FROM source_events GROUP BY status
    `).all().map(row => [row.status, Number(row.count)]));
    const latest = this.db.prepare(`
      SELECT updated_at,last_error FROM source_events ORDER BY updated_at DESC,id DESC LIMIT 1
    `).get() || null;
    return { byStatus, latest };
  }

  close() {
    if (this.db) this.db.close();
  }
}
