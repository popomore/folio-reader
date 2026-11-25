export async function hasPublishedPreview({ repository, tag, token, apiUrl = 'https://api.github.com' }, { fetchImpl = fetch } = {}) {
  if (!/^[\w.-]+\/[\w.-]+$/.test(repository) || !token || !tag) throw new Error('Missing preview release identity');
  const response = await fetchImpl(`${apiUrl}/repos/${repository}/releases/tags/${encodeURIComponent(tag)}`, {
    headers: { Authorization: `Bearer ${token}`, Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28' },
  });
  if (response.status === 404) return false;
  if (!response.ok) throw new Error(`Preview release lookup failed (HTTP ${response.status})`);
  const release = await response.json();
  return release.tag_name === tag && release.draft === false && release.prerelease === true && release.immutable === true;
}
