import { verifyPlannedRelease } from '@popomore/release-actions/apple';
import { generateNotes as conventionalNotes } from '@semantic-release/release-notes-generator';
import { execFileSync } from 'node:child_process';
import { resolve } from 'node:path';
import { writeFileSync } from 'node:fs';
import { assetNames, git, readJSON, validateAssets, validatePlan } from './state.mjs';

function planned(context) {
  return validatePlan(readJSON(context.env.RELEASE_PLAN), {
    sourceSha: git('rev-parse', 'HEAD'), branch: context.branch.name,
    repository: context.env.GITHUB_REPOSITORY, runId: context.env.GITHUB_RUN_ID, ciRunId: context.env.CI_RUN_ID,
  });
}

export async function generateNotes(_config, context) {
  if (context.env.RELEASE_MODE === 'publish') return planned(context).notes;
  const notes = await conventionalNotes({ preset: 'conventionalcommits' }, context);
  if (/[\u3400-\u9fff\u3040-\u30ff\uac00-\ud7af]/u.test(notes)) throw new Error('Release notes must be in English');
  return `${notes}\n\nDownload the Apple Silicon DMG and drag Folio to Applications. Requires macOS 14 or later.\n\n`
    + 'Signed with Developer ID, notarized by Apple, and stapled. Automatic updates use signed Sparkle metadata.\n';
}

export async function verifyRelease(_config, context) {
  if (context.env.RELEASE_MODE !== 'publish') return;
  const plan = planned(context);
  verifyPlannedRelease(plan, context.nextRelease);
  validateAssets(plan, context.env.RELEASE_ARTIFACTS, context.env.RELEASE_PLAN);
}

export function publishPlan(plan, directory, env = process.env) {
  validateAssets(plan, directory, env.RELEASE_PLAN);
  const notesFile = resolve(directory, 'release-notes.txt');
  writeFileSync(notesFile, plan.notes);
  const releaseEnv = { ...env, GH_TOKEN: env.GITHUB_TOKEN || env.GH_TOKEN,
    FOLIO_VERSION: plan.version, FOLIO_TAG: plan.tag, FOLIO_RELEASE_CHANNEL: 'stable',
    FOLIO_RELEASE_REPOSITORY: plan.repository };
  const stage = (...args) => execFileSync('bash', [resolve('scripts/stage-macos-release'), ...args],
    { env: releaseEnv, encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'] });
  let result = stage('inspect');
  if (!/^release-id=/m.test(result)) {
    result = stage('stage', notesFile, ...assetNames(plan).map(name => resolve(directory, name)));
  }
  const id = /^release-id=([1-9]\d*)$/m.exec(result)?.[1];
  if (!id) throw new Error('No staged release ID');
  execFileSync('bash', [resolve('scripts/publish-macos-channel'), plan.version, id],
    { env: releaseEnv, stdio: 'inherit' });
  return { name: 'Folio macOS', url: `https://github.com/${plan.repository}/releases/tag/${plan.tag}` };
}

export async function publish(_config, context) {
  return publishPlan(planned(context), context.env.RELEASE_ARTIFACTS, context.env);
}
