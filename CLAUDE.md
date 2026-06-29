# myst-version-switcher-plugin

A pydata-style version-switcher for [MyST](https://mystmd.org) docs, delivered as
a single `anywidget` plugin **plus** reusable CI workflows (`docs.yml` to build,
`publish.yml` to reconstruct the whole versioned site from durable sources and
deploy it to GitHub Pages). The site-reconstruction logic (`assemble/`) is internal
to `publish.yml`, not a separately consumed action.

## Repo layout

```
plugins/version-switcher.mjs                   # MyST directive + anywidget runtime (single file, no README — docs are in docs/)
assemble/assemble.sh                           # INTERNAL: reconstruct the whole site from durable sources (gh/unzip plumbing); run directly by publish.yml; runnable standalone for local testing
assemble/assemble.mjs                          # INTERNAL: dependency-free Node kernel behind assemble.sh (the `generate` subcommand)
scripts/migrate.sh                             # operator gh-pages → durable-source migration (bash); two-phase: reversible cutover, then guarded --delete-gh-pages
test/                                          # npm test suite (node, no framework)
docs/                                          # this repo's own docs (dogfoods the plugin)
.github/workflows/docs.yml                     # PUBLIC reusable: build at the versioned BASE_URL → pack docs.zip → upload `docs` artifact (workflow_call; build-command input)
.github/workflows/publish.yml                  # PUBLIC reusable ENGINE (PRIVILEGED): branches on the event into 3 jobs — deploy (assemble@job.workflow_sha + Pages), tag-re-dispatch (re-fire the shim), fork-warn. workflow_call ONLY; reached via the publish-dispatch.yml shim
.github/workflows/publish-dispatch.yml         # PUBLIC thin shim: workflow_call (ci.yml's publish, every event) + workflow_dispatch (tag re-dispatch + fork-PR opt-in + manual re-deploy) → forwards to publish.yml. The dispatchable file consumers copy (reusable workflows can't be dispatched cross-repo)
.github/workflows/release.yml                  # PUBLIC reusable: attach the run's build artifacts (docs.zip; + version-switcher.mjs via _test.yml) to the tag's GitHub Release via gh (create-or-upload, immutable-safe). Consumers `uses:` it directly
.github/workflows/ci.yml                       # this repo's own entry: _lint / _test / docs.yml / release, then ONE publish job nesting publish-dispatch.yml (shim) → publish.yml for every event (publish.yml branches: deploy / tag-re-dispatch / fork-warn)
```

## Two halves, different lifecycles

| half | file | how consumers use it |
|------|------|----------------------|
| Plugin (widget) | `plugins/version-switcher.mjs` | release-asset URL in `myst.yml` `plugins` |
| Reusable CI workflows | `.github/workflows/{docs,publish}.yml` | `uses: DiamondLightSource/myst-version-switcher-plugin/.github/workflows/{docs,publish}.yml@<tag>` in their `ci.yml` |

One `vX.Y.Z` tag versions both. The plugin is published as a GitHub Release asset
(alongside the tag's `docs.zip`); the workflows are consumed by `uses:` at the same
tag (and `publish.yml` self-checks-out its `assemble/` scripts at that tag via
`job.workflow_sha`). `assemble/` is internal — consumed only by `publish.yml`, not a
public action.

## Key design decisions

See [`docs/explanation/architecture.md`](docs/explanation/architecture.md) for the
full rationale. In short:

### The default branch is self-durable in the site (`_sources/`)
Releases are durable (Release `docs.zip` assets) and PRs are ephemeral by design, but
the **default branch** had no permanent source — gathered from its latest CI artifact,
which expires, after which it drops out and the guard hard-fails. So each deploy
persists the default branch's `docs.zip` (the one it arrived as — current build,
gathered run, or the fallback — copied verbatim) into the published site at
`_sources/<branch>.zip` (excluded from version discovery), and a deploy whose fresh
artifact is gone restores the branch from that durable in-site copy (fetched from
`PAGES_URL`, default `https://<owner>.github.io/<repo>`). Before the branch ever builds
docs (mid gh-pages migration) a final rung reads a **published seed release**
(`pages-default-seed`, created by `scripts/migrate.sh` from the old gh-pages `<default>/`
tree) and persists it to `_sources` on that deploy — so a repo can cut over to the
reusable workflow in one PR, before `docs→main`. Drafts can't be used: a `contents:read`
deploy token can't read them (verified), so the seed is a published release on a
sentinel tag, deleted at finalize once `_sources/<default>.zip` is live.

### Reconstruct from durable sources, publish the whole tree
Every deploy rebuilds the **complete** site from authoritative inputs — `main`'s
latest build, each release's `docs.zip` asset, every open PR's build artifact — and
deploys it as the *entire* Pages site via `upload-pages-artifact` + `deploy-pages`
(no `gh-pages` branch; Pages source = "GitHub Actions"). A version no longer
gathered (a merged/closed PR, a deleted release) is correctly dropped — no
`keep_files` drift. The **publish workflow** owns the Pages publish because
`deploy-pages` is job-scoped.

### Split build (unprivileged) from publish (privileged), but nest publish for visibility
`ci.yml` builds + uploads the `docs` artifact for every event including fork PRs.
It then nests a single privileged `publish` job (`uses: publish-dispatch.yml` shim →
`publish.yml`) for **every** event in the canonical repo. `publish.yml` branches: an
internal PR / main push deploys inline (status **visible on the PR/commit**); a fork PR
hits a read-only **warn** job (untrusted fork-PR code never reaches a write token — the
`deploy` job is `if`-excluded for forks and the token is read-only anyway); a **tag**
hits the **re-dispatch** (a tag shares the merge commit's SHA and Pages drops a second
same-SHA deploy unless it's a `workflow_dispatch` — deploy-pages#383 — so it
re-dispatches the shim). One `publish` job, no ref/fork guards in `ci.yml`.

Because the inline publish runs **inside the build's own CI run**, the current build
isn't a *completed* successful run the gather can discover (and for a main push the
gather would find the *previous* build). So `ci.yml` passes `publish.yml` the build's
version name (`needs.docs.outputs.version-name`); `publish.yml` hands it to assemble
as `ARTIFACT_VERSION_NAME`. `publish.yml` downloads the same-run `docs` artifact and
`assemble.sh` unzips + stages it directly, **skipping the re-gather of that version**.
Everything else (other releases, other open PRs, the rest) still comes from durable
sources.

`publish.yml` runs **`assemble/assemble.sh`** (checked out from this repo at
`job.workflow_sha`, so the scripts match the workflow's own ref) to gather + generate
+ output the site dir, then `deploy-pages`. Operator note: because internal PRs/tags now deploy from
their **own ref** (not only the default branch), the `github-pages` environment's
deployment-branch policy must allow those refs (or be unrestricted) — this is the
cost of nesting publish for visibility. Bash in `assemble` does the `gh`/`unzip`/`mv`
IO (gather); the JS kernel does the pure logic (`generate` + the folded-in
`missingRequired` guard) and is unit-tested without git/network/fs. There is **no
sanitisation**: version names are clean by construction — `main`, `pr-<number>`, or
a tag without `/` (the `tags: ['*']` trigger never builds `/`-tags).

### Self-referencing the assemble scripts (no separate action)
`publish.yml` runs `assemble/assemble.sh` directly rather than wrapping it in a
composite action. To version-match the scripts to the workflow, it sparse-checks-out
**this** repo's `assemble/` at `job.workflow_repository` + `job.workflow_sha` — the
`job` context resolves to the file that defines the running job, i.e. the *reusable*
workflow (unlike `github.workflow_*`, which resolve to the *caller's* entry
workflow). So a consumer pinning `publish.yml@vX` gets `assemble@vX` automatically,
with no hardcoded repo and no release-time bump, and this repo's own publish job
tests the working-tree scripts (no dogfood gap). The consumer's repo stays checked
out at the root so `assemble.mjs`'s `git tag` lists *their* versions; the scripts run
from `.mvs`. (`uses:` can't take an expression, so a composite action could only be
pinned to a literal tag — the `job` context is the only way to self-reference at the
running ref.) Note: actionlint's `job`-context schema is stale and false-flags
`job.workflow_sha`/`job.workflow_repository`; the GitHub docs confirm both. This repo
lints with biome, not actionlint.

### BASE_URL must be set before `myst build`
```yaml
env:
  BASE_URL: /<repo>/<version-name>   # version-name = pr-<n> | main | <tag>
run: cd docs && myst build --html
```
Without this, assets and links break under the versioned GitHub Pages sub-path. The
version name is computed in `docs.yml` and is exactly the `site/<version-name>` dir
`assemble` files this build's artifact at, so the two cannot drift.

### `assemble` degrades gracefully on first deploy
With no releases and no other branches, `assemble` produces a single-entry
`switcher.json` for the current build and an `index.html` redirecting to it,
rather than failing. The "preferred" version (the redirect target, flagged
`preferred: true` in switcher.json, rendered with a ★) is the newest deployed
non-prerelease tag, falling back to `main`/`master`. Prerelease detection mirrors
`release.yml` (an `a`/`b`/`rc` marker).

### `stable/` alias
When a non-prerelease release is deployed, the site serves a `stable/` symlink
(inflated to a real copy by `upload-pages-artifact`'s `--dereference`) to the
newest release, and the root redirect targets the constant `stable/` URL — a
stable inventory URL for cross-project `objects.inv`. `switcher.json` has no
`stable` entry; the widget maps a `…/stable/` page back to the concrete release.

## CI structure

One entry workflow (`ci.yml`) that nests the privileged publish:

- `ci.yml` — **build + verify, then publish on internal events.** Triggers on
  `pull_request` + push to `main`/tags (no other-branch pushes; `*` excludes
  `/`-tags). Orchestrates `_lint` / `_test` / `docs` / `release`, runs for forks,
  and uploads the `docs` artifact. It then nests a single `publish` job
  (`uses: publish-dispatch.yml`) for **every** event in the canonical repo (the `if`
  is just `repository == '…'`); grants `pages`/`id-token`/`statuses`/`actions:write`
  perms to the call and passes `version-name: needs.docs.outputs.version-name`. No
  ref/fork guards and no separate tag job — `publish.yml` does all the branching.
- `publish-dispatch.yml` — **the thin shim** (the dispatchable file each repo carries).
  `workflow_call` (ci.yml's `publish` job, every event) + `workflow_dispatch` (the tag
  re-dispatch + fork-PR opt-in + manual re-deploy); both just `uses:
  publish.yml`, threading `version-name`/`pr` + its own filename as `dispatch-workflow`.
  It exists only because a reusable workflow can't be dispatched cross-repo, so the
  re-dispatch job needs a local file to re-fire. This repo dogfoods the exact shim
  consumers add (theirs pins `publish.yml@<tag>`; this one uses the local path).
- `publish.yml` — **assemble + deploy ENGINE, privileged; owns the event branching.**
  `workflow_call` ONLY (reached via the shim). Three jobs by originating event:
  **deploy** (internal PR / default-branch push inline, or any dispatch → sparse-checks
  out this repo's `assemble/` at `job.workflow_sha` so the scripts match the pinned ref —
  see "Self-referencing the assemble scripts" below — runs `assemble.sh`, then
  `upload-pages-artifact` + `deploy-pages` + verify, carrying the `github-pages`
  environment + perms + `concurrency`), **re-dispatch** (a tag — waits for the release,
  then `gh workflow run <dispatch-workflow>` in the consumer's repo with their token, so
  the deploy lands as a `workflow_dispatch` that re-serves; a same-SHA tag deploy is
  otherwise dropped — deploy-pages#383), and **warn** (a fork PR — read-only, posts the
  opt-in hint). No canonical guard (it lives upstream in ci.yml). `version-name` injects
  the in-run build on the inline path. See the architecture explanation in docs/.

Sub-workflows of `ci.yml`:
- `_lint.yml` — biome
- `_test.yml` — `npm test`
- `docs.yml` — **reusable build, parameterised for cross-repo reuse.** Compute the
  version name (`pr-<n>` / default-branch / tag) → run `build-command` (required
  input) with `BASE_URL` set → pack `docs.zip` (bare `html/`, staged so
  any `html-dir` works) → upload the `docs` artifact → warn on fork PRs. No deploy;
  `contents: read` only. Installs uv unconditionally and relies on the runner's
  preinstalled Node, so `build-command` can be `make docs` / `npx … myst build` /
  `tox -e docs` regardless of project. This repo passes `npm ci && npm run docs`. It
  OWNS the build↔publish contract (version name, BASE_URL, docs.zip `html/` root,
  `docs` artifact name) so consumers only choose a command.
- `release.yml` — **PUBLIC reusable, tag-only.** Downloads every artifact in the run
  and attaches them to the tag's GitHub Release via `gh` — `gh release create` if no
  Release exists yet (draft→upload→publish atomically, so immutable-safe), else
  `gh release upload --clobber` to an existing (UI-published, mutable) Release. No
  third-party action. For this repo the artifacts are the tag's `docs.zip` (the `docs`
  artifact, verbatim) + `version-switcher.mjs` (uploaded by `_test.yml` as an artifact,
  so the generic workflow needs no plugin-specific step). Consumers `uses:` it directly.

**Publish flow.** The single `publish` job (→ `publish-dispatch.yml` shim → `publish.yml`)
runs for every event and `publish.yml` branches. Internal PRs and `main` deploy inline as part of the
same CI run once lint/test/docs pass (`publish.yml` injects this build + `assemble`
gathers `main`, releases, and every other open PR → deploy), a visible check on the
PR/commit. **Tags** hit the wrapper's `re-dispatch`: a release tag shares the merge
commit's SHA, and GitHub Pages silently drops a second deploy of an already-deployed
SHA *unless* the event is `workflow_dispatch`
([`actions/deploy-pages#383`](https://github.com/actions/deploy-pages/issues/383)) —
so it waits for the release, then `gh workflow run publish-dispatch.yml`
(`workflow_dispatch`), which re-gathers from durable sources (incl. the new release)
and deploys with the origin actually updating (the dispatched run carries the deploy
status, not the tag's CI run). An **external fork PR** hits the wrapper's `warn` job
(read-only, no deploy); a maintainer dispatches `publish-dispatch.yml` with the PR
number (`pr`), which sets a `preview-approved` commit status pinned to that **head
SHA** and assembles — so a later push to the PR (new SHA) drops the preview until
re-approved. `assemble` gathers an open PR's artifact via its head SHA; internal PRs
always, fork PRs only when the SHA carries that status.

`mystmd` is pinned at `1.10.1` (not `latest`).

## Developing

```bash
npm test                    # run the test suite
npm run docs                # build docs (same command CI uses)
npm run docs-dev            # live-preview docs with the plugin loaded from local plugins/
```

`docs/myst.yml` loads the plugin from `../plugins/version-switcher.mjs`
(not a release URL), so edits are reflected on rebuild.

**Browser caveat:** `<select>` popups don't open in VS Code Simple Browser. Open the
forwarded port in a real browser and hard-reload (MyST caches the localized esm).

## Releasing

```bash
git tag vX.Y.Z && git push origin vX.Y.Z
```

CI runs lint + tests + docs build, then `release.yml` creates the GitHub Release with
`version-switcher.mjs` + the tag's `docs.zip` attached (via `gh`), and the tag
re-dispatch reconstructs + deploys the site including the new tag.
The plugin URL and the `uses:` refs for `docs.yml`/`publish.yml` all resolve to the
same tag.

## Consuming this in another repo

Pin `<tag>` in three places (with copier, one Jinja variable fills all):

```yaml
# docs/myst.yml
project:
  plugins:
    - https://github.com/DiamondLightSource/myst-version-switcher-plugin/releases/download/<tag>/version-switcher.mjs
site:
  template: book-theme
  parts:
    navbar_end: navbar_end.md
```

```markdown
<!-- docs/navbar_end.md -->
:::{version-switcher}
:json-url: https://ORG.github.io/REPO/switcher.json
:::
```

Set the repo's **Pages source to "GitHub Actions"**, then add a `ci.yml` that calls
the two shared reusable workflows by full path at `<tag>`:

```yaml
jobs:
  docs:
    uses: DiamondLightSource/myst-version-switcher-plugin/.github/workflows/docs.yml@<tag>
    with:
      build-command: make docs        # or: tox -e docs / npx … myst build / npm ci && npm run docs
  publish:                            # every event — publish.yml branches
    needs: [docs]
    if: github.repository == 'ORG/REPO'
    uses: ./.github/workflows/publish-dispatch.yml   # your wrapper; it pins publish.yml@<tag>
    with:
      version-name: ${{ needs.docs.outputs.version-name }}
    permissions: { pages: write, id-token: write, contents: read, actions: write, statuses: write }
```

Add a `release` job that `uses:` this repo's `release.yml@<tag>` (with `permissions:
contents: write`) to attach each tag's built `docs.zip` (bare `html/` root) as a
Release asset so `assemble` can reconstruct released versions, and the
`publish-dispatch.yml` wrapper around `publish.yml` — the single caller of the engine
and the one place you pin `publish.yml@<tag>`. The wrapper owns all
the branching: **deploy** (inline non-tag, or a dispatch), **re-dispatch** (a tag
re-fires itself so the deploy is a `workflow_dispatch` — required for a release's
same-SHA deploy to go live), and **warn** (a fork PR, read-only, posts the preview
opt-in hint; a maintainer dispatches the wrapper with `pr` to actually preview). See the
full how-to + snippets in `docs/`.

## Upstreaming

`plugins/version-switcher.mjs` follows
[`jupyter-book/myst-plugins`](https://github.com/jupyter-book/myst-plugins)
conventions (single self-contained `.mjs`, distributed as a release asset) so it
can later be contributed there. The `assemble/` producer is DLS deployment
infrastructure and stays here.
