import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

export const digest = bytes => createHash('sha256').update(bytes).digest('hex');
export const readJSON = file => JSON.parse(readFileSync(file, 'utf8'));
export const writeJSON = (file, value) => writeFileSync(file, JSON.stringify(value, null, 2) + '\n');
export const git = (...args) => execFileSync('git', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
export const assetNames = plan => [`Folio-${plan.version}.zip`, `Folio-${plan.version}.dmg`, 'appcast.xml'];

export function validatePlan(plan, expected = {}) {
  if (plan.schema !== 1 || plan.branch !== 'release'
      || !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(plan.repository)
      || !/^[0-9a-f]{40}$/.test(plan.sourceSha)
      || !/^[1-9]\d*$/.test(String(plan.runId)) || !/^[1-9]\d*$/.test(String(plan.ciRunId))
      || typeof plan.release !== 'boolean') throw new Error('Invalid release plan provenance');
  for (const [key, value] of Object.entries(expected)) {
    if (String(plan[key]) !== String(value)) throw new Error(`Release plan mismatch: ${key}`);
  }
  if (!plan.release) return plan;
  if (typeof plan.version !== 'string' || plan.tag !== `v${plan.version}`
      || plan.channel !== 'stable' || typeof plan.notes !== 'string' || !plan.notes.trim()) {
    throw new Error('Invalid release plan metadata');
  }
  execFileSync('scripts/macos-version', [plan.version], { stdio: 'pipe' });
  return plan;
}

export function validateAssets(plan, directory, planFile) {
  const receipt = readJSON(resolve(directory, 'validated-artifacts.json'));
  if (receipt.schema !== 1 || receipt.planSha256 !== digest(readFileSync(planFile))
      || receipt.sourceSha !== plan.sourceSha || receipt.tag !== plan.tag
      || receipt.signingMode !== 'developer-id'
      || Object.keys(receipt.files).sort().join('\n') !== assetNames(plan).sort().join('\n')) {
    throw new Error('Artifacts do not match the original release plan');
  }
  for (const name of assetNames(plan)) {
    if (digest(readFileSync(resolve(directory, name))) !== receipt.files[name]) throw new Error(`Artifact digest mismatch: ${name}`);
  }
  return receipt;
}
