import { semanticEnvironment, recoverChannelNote } from '@popomore/github-actions/release/apple';
import semanticRelease from 'semantic-release';
import config from '../../release.config.mjs';
import { appendFileSync, existsSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { git, readJSON, writeJSON, validatePlan, validateAssets } from './state.mjs';
import { publishPlan } from './macos.mjs';

const mode = process.argv[2];
if (!['plan', 'publish'].includes(mode)) throw new Error('Use plan or publish');
const env = semanticEnvironment({ ...process.env, RELEASE_MODE: mode });
if (env.GITHUB_ACTIONS !== 'true' || !(env.GITHUB_TOKEN || env.GH_TOKEN)) throw new Error('Run release automation in GitHub Actions');
if (env.GITHUB_REF !== 'refs/heads/release' || env.GITHUB_EVENT_NAME !== 'workflow_dispatch') {
  throw new Error('Use a dispatch on the tested release branch');
}
const planFile = env.RELEASE_PLAN = resolve(env.RELEASE_PLAN || 'target/release-plan/plan.json');
env.RELEASE_ARTIFACTS = resolve(env.RELEASE_ARTIFACTS || 'dist');
const expected = { branch: 'release', repository: env.GITHUB_REPOSITORY, sourceSha: env.SOURCE_SHA,
  runId: env.GITHUB_RUN_ID, ciRunId: env.CI_RUN_ID };
if (git('rev-parse', 'HEAD') !== expected.sourceSha) throw new Error('Checkout is not the tested source');
git('merge-base', '--is-ancestor', expected.sourceSha, 'origin/main');
const options = { ...config, repositoryUrl: `https://github.com/${env.GITHUB_REPOSITORY}.git`, dryRun: mode === 'plan', ci: true };

function assertCurrent(plan) {
  const tip = git('ls-remote', 'origin', 'refs/heads/release').split(/\s/)[0];
  if (tip !== plan.sourceSha) throw new Error('Branch advanced after CI; wait for the newer push');
}

function recover(plan) {
  recoverChannelNote({ plan, env, channel: null });
  publishPlan(plan, env.RELEASE_ARTIFACTS, env);
}

let plan;
if (existsSync(planFile)) {
  plan = validatePlan(readJSON(planFile), expected);
} else if (mode === 'plan') {
  assertCurrent(expected);
  const result = await semanticRelease(options, { env });
  const next = result && result.nextRelease;
  plan = { schema: 1, ...expected, release: Boolean(next) };
  if (next) Object.assign(plan, { version: next.version, tag: next.gitTag, channel: 'stable', notes: next.notes });
  validatePlan(plan, expected);
  mkdirSync(dirname(planFile), { recursive: true });
  writeJSON(planFile, plan);
} else throw new Error('Publication requires the original release plan artifact');

if (mode === 'publish') {
  if (!plan.release) throw new Error('No planned release');
  validateAssets(plan, env.RELEASE_ARTIFACTS, planFile);
  const remote = git('ls-remote', '--tags', 'origin', `refs/tags/${plan.tag}`, `refs/tags/${plan.tag}^{}`);
  const lines = remote ? remote.split('\n') : [];
  const existing = (lines.find(line => line.endsWith('^{}')) || lines[0])?.split(/\s/)[0];
  if (existing && existing !== plan.sourceSha) throw new Error('Existing tag points to another source; refusing to move it');
  if (existing) recover(plan);
  else {
    assertCurrent(plan);
    const result = await semanticRelease(options, { env });
    if (!result?.nextRelease || result.nextRelease.gitTag !== plan.tag) throw new Error('The planned release was not published');
  }
}
if (env.GITHUB_OUTPUT) {
  appendFileSync(env.GITHUB_OUTPUT, `release=${plan.release}\n`);
  if (plan.release) for (const name of ['tag', 'version']) appendFileSync(env.GITHUB_OUTPUT, `${name}=${plan[name]}\n`);
}
