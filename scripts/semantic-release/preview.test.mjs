import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { previewCompatibilityPlan } from '@popomore/release-actions/tags';

test('semantic preview versions retain the existing installed-client tag and asset format', () => {
  const plan = previewCompatibilityPlan({ version: '1.1.0-preview.12', tag: 'v1.1.0-preview.12', channel: 'prerelease', source_sha: 'a'.repeat(40) }, '1793840000');
  assert.equal(plan.tag, 'v1.1.0.1793840000-aaaaaaa');
  assert.equal(plan.version, '1.1.0-1793840000.gaaaaaaa');
  assert.equal(plan.semantic_version, '1.1.0-preview.12');
  assert.equal(plan.kind, 'semantic-release-compatibility');
});
test('preview publication rejects PR context before any tag or dispatch write', () => {
  const result = spawnSync(process.execPath, ['scripts/semantic-release/preview.mjs'], {
    env: { ...process.env, GITHUB_ACTIONS: 'true', GITHUB_EVENT_NAME: 'pull_request', GITHUB_REF: 'refs/pull/1/merge' }, encoding: 'utf8' });
  assert.notEqual(result.status, 0); assert.match(result.stderr, /tested official main push/);
});

import { hasPublishedPreview } from './releases.mjs';
test('preview recovery looks up the exact release tag without buffering the release history', async () => {
  const identity = { repository: 'fixture/folio', tag: 'v1.1.0.1793840000-aaaaaaa', token: 'fixture-token' };
  const fetchImpl = async (url, options) => {
    assert.equal(url, 'https://api.github.com/repos/fixture/folio/releases/tags/' + identity.tag);
    assert.equal(options.headers.Authorization, 'Bearer fixture-token');
    return Response.json({ tag_name: identity.tag, draft: false, prerelease: true, immutable: true, body: 'x'.repeat(2 * 1024 * 1024) });
  };
  assert.equal(await hasPublishedPreview(identity, { fetchImpl }), true);
  for (const change of [{ draft: true }, { prerelease: false }, { immutable: false }, { tag_name: 'other' }]) {
    assert.equal(await hasPublishedPreview(identity, { fetchImpl: async () => Response.json({ tag_name: identity.tag, draft: false, prerelease: true, immutable: true, ...change }) }), false);
  }
  assert.equal(await hasPublishedPreview(identity, { fetchImpl: async () => new Response('', { status: 404 }) }), false);
  await assert.rejects(hasPublishedPreview(identity, { fetchImpl: async () => new Response('', { status: 403 }) }), /HTTP 403/);
});
