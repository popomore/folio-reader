# Semantic release

Stable releases keep the existing CI-provenance, retained-plan, Developer ID/notarization, signed-update and byte-identical recovery flow. Shared Apple configuration, installation-token handling, plan verification, artifact verification and channel-note recovery are imported from the public `popomore/github-actions` dependency pinned in the npm lockfile.

Preview version decisions now also use semantic-release and Conventional Commits. Existing installed preview clients discover timestamp tags, so an explicit compatibility adapter projects the semantic plan to that tag/asset format. The immutable annotated tag retains its canonical `semantic_tag` and `semantic_version`, source/manifest identity and notes. Future planning reconstructs these references only in an isolated Git mirror. No second version generator or manually maintained base version decides the release.

The existing successful main CI job uses its short-lived workflow token and explicitly dispatches the existing preview product workflow. Stable routing, signing identities, bundle build numbering, updater keys, immutable assets and retry checkpoints remain product-specific. Public consumers do not reference private Meta actions or workflows.

This PR does not publish, merge, alter signing credentials, replace an installed application, or prove a real installed-client upgrade.
