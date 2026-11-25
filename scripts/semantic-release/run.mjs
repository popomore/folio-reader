import semanticRelease from 'semantic-release';
import config from '../../release.config.mjs';
import { appendFileSync, existsSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { execFileSync } from 'node:child_process';
import { git, readJSON, writeJSON, validatePlan, validateAssets } from './state.mjs';
import { publishPlan } from './macos.mjs';

const mode = process.argv[2];
if (!['plan', 'publish'].includes(mode)) throw new Error('Use plan or publish');
const env = { ...process.env, RELEASE_MODE: mode };
if (env.GITHUB_ACTIONS !== 'true' || !(env.GITHUB_TOKEN || env.GH_TOKEN)) throw new Error('Run release automation in GitHub Actions');
// Use the installation-token path in the pinned engine, as in MusicX.
env.GITHUB_TOKEN = env.GITHUB_TOKEN || env.GH_TOKEN;
delete env.GH_TOKEN;
env.GITHUB_ACTION ||= 'semantic-release';
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
  const ref = `refs/notes/semantic-release-${plan.tag}`;
  const authEnv = { ...env, GIT_AUTHOR_NAME: 'semantic-release-bot', GIT_AUTHOR_EMAIL: 'semantic-release-bot@martynus.net',
    GIT_COMMITTER_NAME: 'semantic-release-bot', GIT_COMMITTER_EMAIL: 'semantic-release-bot@martynus.net',
    GIT_CONFIG_COUNT: '1', GIT_CONFIG_KEY_0: 'http.https://github.com/.extraheader',
    GIT_CONFIG_VALUE_0: `AUTHORIZATION: basic ${Buffer.from(`x-access-token:${env.GITHUB_TOKEN}`).toString('base64')}` };
  const command = args => {
    try { return execFileSync('git', args, { env: authEnv, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim(); }
    catch { throw new Error('Release note recovery failed; remote output was suppressed'); }
  };
  if (git('ls-remote', 'origin', ref)) {
    command(['fetch', 'origin', `${ref}:${ref}`]);
    const note = JSON.parse(command(['notes', '--ref', ref, 'show', plan.tag]));
    if (!note.channels?.includes(null)) throw new Error('Existing tag channel note conflicts with the plan');
  } else {
    command(['notes', '--ref', ref, 'add', '-m', JSON.stringify({ channels: [null] }), plan.tag]);
    command(['push', 'origin', ref]);
  }
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
