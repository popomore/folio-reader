import { execFileSync } from 'node:child_process';
import { planUnit, git, digest } from '@popomore/release-actions/planner';
import { previewCompatibilityPlan, createTag, verifyBranchTip } from '@popomore/release-actions/tags';
import { readFileSync } from 'node:fs';
import { hasPublishedPreview } from './releases.mjs';

const env = process.env, cwd = process.cwd(), sourceSha = env.SOURCE_SHA, repository = env.GITHUB_REPOSITORY;
if (env.GITHUB_ACTIONS !== 'true' || env.GITHUB_EVENT_NAME !== 'push' || env.GITHUB_REF !== 'refs/heads/main'
    || git(cwd, 'rev-parse', 'HEAD') !== sourceSha || !(env.GH_TOKEN || env.GITHUB_TOKEN)) throw new Error('Preview releases require the tested official main push');
await verifyBranchTip({ repository, branch: 'main', sourceSha }, { token: env.GH_TOKEN || env.GITHUB_TOKEN, apiUrl: env.GITHUB_API_URL });
const manifestPath = '.release/units/folio.json', unit = JSON.parse(readFileSync(manifestPath));
if (!unit.auto_on_main) process.exit(0);
const timestamp = git(cwd, 'log', '-1', '--format=%ct', sourceSha);
const existing = git(cwd, 'tag', '--list', `v*.${timestamp}-${sourceSha.slice(0, 7)}`).split('\n').filter(Boolean);
let plan;
if (existing.length) {
  if (existing.length !== 1) throw new Error('Ambiguous preview tags for the tested source');
  plan = JSON.parse(git(cwd, 'for-each-ref', '--format=%(contents)', `refs/tags/${existing[0]}`));
  if (plan.kind !== 'semantic-release-compatibility' || plan.repository !== repository || plan.source_sha !== sourceSha
      || plan.manifest_sha !== digest(readFileSync(manifestPath)) || plan.unit !== 'folio') throw new Error('Existing preview conflicts with the semantic plan');
} else {
  const semantic = await planUnit({ cwd, manifestPath, sourceSha, repository, preview: true });
  if (!semantic.tag) { console.log('No release-relevant commits'); process.exit(0); }
  plan = { ...previewCompatibilityPlan(semantic, timestamp), ci_run_id: env.GITHUB_RUN_ID, workflow_sha: env.GITHUB_WORKFLOW_SHA };
}
execFileSync('scripts/macos-version', [plan.semantic_version.split('-')[0], `${timestamp}-${sourceSha.slice(0, 7)}`], { stdio: 'pipe' });
// This already-gated CI job explicitly dispatches the product workflow. Its
// short-lived workflow token is sufficient; tag-push chaining is not required.
await createTag(plan, { token: env.GH_TOKEN || env.GITHUB_TOKEN, apiUrl: env.GITHUB_API_URL });
if (!await hasPublishedPreview({ repository, tag: plan.tag, token: env.GH_TOKEN || env.GITHUB_TOKEN, apiUrl: env.GITHUB_API_URL })) {
  execFileSync('gh', ['workflow', 'run', 'release-macos.yml', '--repo', repository, '--ref', plan.tag, '--field', 'publish-preview=true'], { stdio: 'inherit' });
}
