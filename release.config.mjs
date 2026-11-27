import { appleReleaseConfig } from '@popomore/github-actions/release/apple';

export default appleReleaseConfig({ publisher: './scripts/semantic-release/macos.mjs' });
