import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { assetNames, digest, git, readJSON, writeJSON, validateAssets, validatePlan } from './state.mjs';

const planFile = process.env.RELEASE_PLAN || 'target/release-plan/plan.json';
const directory = resolve(process.env.RELEASE_ARTIFACTS || 'dist');
const plan = validatePlan(readJSON(planFile), {
  sourceSha: git('rev-parse', 'HEAD'), repository: process.env.GITHUB_REPOSITORY,
  runId: process.env.GITHUB_RUN_ID, ciRunId: process.env.CI_RUN_ID,
});
if (!plan.release) throw new Error('No planned release');
switch (process.argv[2]) {
  case 'env':
    mkdirSync(directory, { recursive: true });
    writeFileSync(resolve(directory, 'release-notes.txt'), plan.notes);
    appendFileSync(process.env.GITHUB_ENV, `FOLIO_VERSION=${plan.version}\nFOLIO_TAG=${plan.tag}\n`
      + `FOLIO_RELEASE_CHANNEL=stable\nFOLIO_RELEASE_NOTES_FILE=${resolve(directory, 'release-notes.txt')}\n`);
    break;
  case 'record':
    writeJSON(resolve(directory, 'validated-artifacts.json'), {
      schema: 1, planSha256: digest(readFileSync(planFile)), sourceSha: plan.sourceSha,
      tag: plan.tag, signingMode: 'developer-id',
      files: Object.fromEntries(assetNames(plan).map(name => [name, digest(readFileSync(resolve(directory, name)))])),
    });
    break;
  case 'verify':
    validateAssets(plan, directory, planFile);
    break;
  default: throw new Error('Use env, record or verify');
}
