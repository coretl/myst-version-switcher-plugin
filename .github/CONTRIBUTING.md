# Contributing

This repo ships two halves under one `vX.Y.Z` tag: the `version-switcher` plugin
(`plugins/version-switcher.mjs`) and the `assemble` site action (`assemble/`). It is
a JS-only repo — no build step, no framework.

## Developing

```bash
npm test                    # run the test suite (node, no framework)
npm run docs                # build docs (the same command CI uses)
npm run docs-dev            # live-preview docs with the plugin loaded from local plugins/
```

`docs/myst.yml` loads the plugin from the local `plugins/` path (not a release URL),
so edits are reflected on rebuild.

**Browser caveat:** `<select>` popups don't open in the VS Code Simple Browser. Open
the forwarded port in a real browser and hard-reload (MyST caches the localised esm).

## Running assemble locally

`assemble/assemble.sh` (run directly by `publish.yml`) is also runnable standalone so
the `gh` plumbing can be exercised outside CI:

```bash
REPO=DiamondLightSource/myst-version-switcher-plugin GH_TOKEN=$(gh auth token) \
  assemble/assemble.sh
```

The pure logic (ordering, prerelease detection, `switcher.json`/redirect rendering,
the required-branch guard) lives in `assemble/assemble.mjs` and is unit-tested
(`npm test`) without git, the network, or the filesystem.

## Releasing

```bash
git tag vX.Y.Z && git push origin vX.Y.Z
```

CI runs lint + tests + the docs build; `release.yml` creates the GitHub Release with
`version-switcher.mjs` + the tag's `docs.zip` attached (via `gh`); and the nested
publish (tag re-dispatch) reconstructs + deploys the site including the new tag. The plugin URL
and the `uses:` refs for the reusable workflows all resolve to the same tag, so one
tag versions both halves.
