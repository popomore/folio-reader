import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { assetNames, digest, readJSON, validateAssets, validatePlan, writeJSON } from './state.mjs';

const root = fileURLToPath(new URL('../../', import.meta.url));

function fixture(t) {
  const directory = mkdtempSync(resolve(tmpdir(), 'folio-release-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const remote = resolve(directory, 'origin.git');
  const cwd = resolve(directory, 'work');
  const repository = 'folio-fixture/local';
  const env = { PATH: process.env.PATH, HOME: process.env.HOME, CI: 'true', GITHUB_ACTIONS: 'true',
    GITHUB_EVENT_NAME: 'workflow_dispatch', GITHUB_REF: 'refs/heads/release', GITHUB_REF_NAME: 'release',
    GITHUB_REPOSITORY: repository, GH_TOKEN: 'fixture', GIT_TERMINAL_PROMPT: '0',
    GIT_AUTHOR_NAME: 'Release fixture', GIT_AUTHOR_EMAIL: 'fixture@example.invalid',
    GIT_COMMITTER_NAME: 'Release fixture', GIT_COMMITTER_EMAIL: 'fixture@example.invalid',
    GIT_CONFIG_COUNT: '2', GIT_CONFIG_KEY_0: 'commit.gpgsign', GIT_CONFIG_VALUE_0: 'false',
    GIT_CONFIG_KEY_1: 'core.hooksPath', GIT_CONFIG_VALUE_1: '/dev/null' };
  const command = (dir, ...args) => execFileSync('git', args, { cwd: dir, env, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  command(directory, 'init', '--bare', '--initial-branch=release', remote);
  command(directory, 'clone', remote, cwd);
  const git = (...args) => command(cwd, ...args);
  for (const url of [`https://github.com/${repository}.git`, `https://x-access-token:fixture@github.com/${repository}.git`]) {
    git('config', '--add', `url.${remote}.insteadOf`, url);
  }
  mkdirSync(resolve(cwd, 'scripts'), { recursive: true });
  cpSync(resolve(root, 'scripts/semantic-release'), resolve(cwd, 'scripts/semantic-release'), { recursive: true });
  cpSync(resolve(root, 'scripts/macos-version'), resolve(cwd, 'scripts/macos-version'));
  cpSync(resolve(root, 'release.config.mjs'), resolve(cwd, 'release.config.mjs'));
  symlinkSync(resolve(root, 'node_modules'), resolve(cwd, 'node_modules'), 'dir');
  writeFileSync(resolve(cwd, 'package.json'), '{"type":"module","private":true}\n');
  writeFileSync(resolve(cwd, 'Cargo.toml'), '[package]\nname = "fixture"\nversion = "0.1.0"\n');
  writeFileSync(resolve(cwd, '.gitignore'), 'node_modules/\ntarget/\ndist/\n.fixture*\n');
  // Only the external publication effects are replaced; the real runner tags the bare remote.
  writeFileSync(resolve(cwd, 'scripts/stage-macos-release'), '#!/bin/bash\nset -eu\n'
    + 'if [[ "$1" == inspect && ! -f .fixture-published ]]; then echo draft=false; else\n'
    + '  if [[ "$1" == stage ]]; then test -s "$2"; shift 2; for file in "$@"; do test -s "$file"; done; fi\n'
    + '  echo release-id=123\nfi\n');
  writeFileSync(resolve(cwd, 'scripts/publish-macos-channel'), '#!/bin/bash\nset -eu\n'
    + 'test "$FOLIO_RELEASE_REPOSITORY" = folio-fixture/local\n'
    + 'test "$FOLIO_RELEASE_CHANNEL" = stable\n'
    + 'test "$FOLIO_VERSION" = "$1"\ntest "$FOLIO_TAG" = "v$1"\ntest "$2" = 123\n'
    + 'test ! -f .fixture-fail-publish\nprintf "%s\\n" "$FOLIO_TAG" > .fixture-published\n');
  git('add', '.'); git('commit', '-m', 'chore: initialize'); git('tag', 'v1.0.0');
  git('branch', 'main'); git('push', 'origin', 'release', 'main', '--tags');
  const commit = message => {
    git('commit', '--allow-empty', '-m', message);
    git('branch', '-f', 'main', 'HEAD');
    git('push', 'origin', 'release', 'main');
    return git('rev-parse', 'HEAD');
  };
  function run(runId = '42', sourceSha = git('rev-parse', 'HEAD')) {
    const runEnv = { ...env, GITHUB_RUN_ID: runId, CI_RUN_ID: String(Number(runId) - 1), SOURCE_SHA: sourceSha,
      RELEASE_PLAN: resolve(cwd, `target/${runId}/plan.json`), RELEASE_ARTIFACTS: resolve(cwd, 'dist'),
      GITHUB_OUTPUT: resolve(cwd, `target/${runId}/outputs`), GITHUB_ENV: resolve(cwd, `target/${runId}/env`) };
    mkdirSync(resolve(cwd, `target/${runId}`), { recursive: true });
    const execute = (script, mode, success = true) => {
      const result = spawnSync(process.execPath, [`scripts/semantic-release/${script}.mjs`, mode],
        { cwd, env: runEnv, encoding: 'utf8' });
      const output = result.stdout + result.stderr;
      if (success) assert.equal(result.status, 0, output);
      else assert.notEqual(result.status, 0, output);
      return output;
    };
    return {
      env: runEnv,
      plan: () => { execute('run', 'plan'); return readJSON(runEnv.RELEASE_PLAN); },
      publish: (success = true) => execute('run', 'publish', success),
      packages: () => {
        const plan = readJSON(runEnv.RELEASE_PLAN);
        execute('artifacts', 'env');
        for (const name of assetNames(plan)) writeFileSync(resolve(cwd, 'dist', name), `signed fixture: ${name}\n`);
        execute('artifacts', 'record'); execute('artifacts', 'verify');
      },
    };
  }
  return { cwd, remote, git, commit, run };
}

test('the real runner plans without tagging, publishes once, and skips documentation', t => {
  const { cwd, git, commit, run } = fixture(t);
  commit('feat(reader): browse archives');
  const first = run();
  const plan = first.plan();
  assert.equal(plan.version, '1.1.0');
  assert.match(plan.notes, /browse archives/);
  assert.match(plan.notes, /Download the Apple Silicon DMG/);
  assert.equal(git('tag', '--list', 'v1.1.0'), '');
  assert.equal(existsSync(resolve(cwd, '.fixture-published')), false);
  first.packages(); first.publish();
  assert.equal(git('rev-parse', 'v1.1.0'), plan.sourceSha);
  assert.equal(readFileSync(resolve(cwd, '.fixture-published'), 'utf8').trim(), 'v1.1.0');
  assert.equal(readFileSync(resolve(cwd, 'dist/release-notes.txt'), 'utf8'), plan.notes);
  first.publish();
  commit('docs: explain the archive viewer');
  assert.equal(run('43').plan().release, false);
  commit('fix(reader): retain the selected archive entry');
  const patch = run('44').plan();
  assert.equal(patch.version, '1.1.1');
  assert.match(patch.notes, /retain the selected archive entry/);
  assert.doesNotMatch(patch.notes, /browse archives/);
  assert.equal(git('show', 'HEAD:Cargo.toml'), '[package]\nname = "fixture"\nversion = "0.1.0"');
});

test('breaking headers and footers plan a major version', t => {
  const { commit, run } = fixture(t);
  commit('feat(core)!: replace the reader contract');
  assert.equal(run().plan().version, '2.0.0');
  commit('fix(core): validate input\n\nBREAKING CHANGE: require the new document contract');
  assert.equal(run('43').plan().version, '2.0.0');
});

test('the first stable version ignores existing timestamp preview tags', t => {
  const { git, commit, run } = fixture(t);
  git('push', 'origin', ':refs/tags/v1.0.0'); git('tag', '-d', 'v1.0.0');
  git('tag', 'v0.1.1.1795480060-ab49598'); git('push', 'origin', '--tags');
  commit('feat(reader): browse archives');
  assert.equal(run().plan().version, '1.0.0');
});

test('publication resumes an existing tag and repairs a missing channel note', t => {
  const { cwd, git, commit, run } = fixture(t);
  commit('fix(reader): repair navigation');
  const original = run();
  const plan = original.plan();
  original.packages();
  writeFileSync(resolve(cwd, '.fixture-fail-publish'), 'fail');
  original.publish(false);
  assert.equal(git('rev-parse', plan.tag), plan.sourceSha);
  const note = `refs/notes/semantic-release-${plan.tag}`;
  git('push', 'origin', `:${note}`); git('update-ref', '-d', note);
  rmSync(resolve(cwd, '.fixture-fail-publish'));
  commit('fix(reader): follow-up after the interrupted release');
  git('checkout', '--detach', plan.sourceSha);
  assert.deepEqual(original.plan(), plan);
  original.publish();
  assert.equal(git('rev-parse', plan.tag), plan.sourceSha);
  assert.deepEqual(JSON.parse(git('notes', '--ref', note, 'show', plan.tag)), { channels: [null] });
});

test('changed packages and stale sources fail before creating a tag', t => {
  const { cwd, git, commit, run } = fixture(t);
  commit('fix(reader): repair navigation');
  const original = run();
  const plan = original.plan();
  original.packages();
  writeFileSync(resolve(cwd, 'dist', assetNames(plan)[0]), 'different bytes');
  assert.match(original.publish(false), /Artifact digest mismatch/);
  assert.equal(git('tag', '--list', plan.tag), '');
  original.packages();
  commit('fix(reader): a newer tested source');
  git('checkout', '--detach', plan.sourceSha);
  assert.match(original.publish(false), /Branch advanced after CI/);
  assert.equal(git('tag', '--list', plan.tag), '');
});

test('publication resumes a matching annotated tag using its peeled commit', t => {
  const { cwd, git, commit, run } = fixture(t);
  commit('fix(reader): repair navigation');
  const original = run();
  const plan = original.plan();
  original.packages();
  git('tag', '-a', plan.tag, '-m', 'Annotated release fixture', plan.sourceSha);
  git('push', 'origin', plan.tag);
  assert.notEqual(git('rev-parse', plan.tag), plan.sourceSha);
  original.publish();
  assert.equal(git('rev-parse', `${plan.tag}^{}`), plan.sourceSha);
  assert.equal(readFileSync(resolve(cwd, '.fixture-published'), 'utf8').trim(), plan.tag);
});

test('a conflicting tag, another run, or a source outside main is rejected', t => {
  const { cwd, git, commit, run } = fixture(t);
  commit('fix(reader): repair navigation');
  const original = run();
  const plan = original.plan();
  original.packages();
  git('tag', '-a', plan.tag, '-m', 'Conflicting annotated fixture', 'v1.0.0'); git('push', 'origin', plan.tag);
  assert.match(original.publish(false), /refusing to move/);
  assert.equal(git('rev-parse', `${plan.tag}^{}`), git('rev-parse', 'v1.0.0'));
  const changed = { ...plan, runId: '99' };
  writeJSON(original.env.RELEASE_PLAN, changed);
  assert.match(original.publish(false), /Release plan mismatch: runId/);
  git('commit', '--allow-empty', '-m', 'fix: release-only source'); git('push', 'origin', 'release');
  const outside = run('43');
  const result = spawnSync(process.execPath, ['scripts/semantic-release/run.mjs', 'plan'],
    { cwd, env: outside.env, encoding: 'utf8' });
  assert.notEqual(result.status, 0);
  assert.equal(existsSync(outside.env.RELEASE_PLAN), false);
});

test('plans and receipts bind version, repository, run, notes, source, and exact files', t => {
  const { cwd, commit, run } = fixture(t);
  commit('fix(reader): repair navigation');
  const original = run();
  const plan = original.plan();
  for (const change of [{ branch: 'main' }, { sourceSha: 'bad' }, { version: '../bad' },
    { version: '9999.0.0', tag: 'v9999.0.0' }, { release: null }, { ciRunId: '0' }, { notes: '' }, { channel: 'preview' }]) {
    assert.throws(() => validatePlan({ ...plan, ...change }));
  }
  assert.throws(() => validatePlan(plan, { repository: 'another/repository' }));
  original.packages();
  assert.equal(validateAssets(plan, resolve(cwd, 'dist'), original.env.RELEASE_PLAN).sourceSha, plan.sourceSha);
  writeJSON(original.env.RELEASE_PLAN, { ...plan, notes: 'Different notes' });
  assert.throws(() => validateAssets(plan, resolve(cwd, 'dist'), original.env.RELEASE_PLAN), /original release plan/);
  assert.equal(digest(Buffer.from('fixture')).length, 64);
});
