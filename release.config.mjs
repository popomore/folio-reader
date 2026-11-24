export default {
  branches: [{ name: 'release', channel: false }],
  tagFormat: 'v${version}',
  plugins: [
    ['@semantic-release/commit-analyzer', { preset: 'conventionalcommits' }],
    './scripts/semantic-release/macos.mjs',
  ],
};
