# Explanation: architecture

This explains *why* the versioned site is built the way it is — the design
reasoning behind the `assemble` scripts and the build/publish workflow split. For
the *what* (inputs, options, copy-paste snippets), see the
[reference](../reference/workflows.md) and [tutorial](../tutorials/adding-to-a-fresh-repo.md).

## The core idea: reconstruct the whole site every deploy

Every deploy rebuilds the **complete** site tree from authoritative sources and
publishes it **directly to GitHub Pages** via `actions/upload-pages-artifact` +
`actions/deploy-pages`. There is **no `gh-pages` branch** — `deploy-pages` publishes
one artifact as the *entire* site, which is a whole-site-replace.

| version kind | source | durability |
|---|---|---|
| current build | the build staged into the publish run via `version-name` | n/a (just built) |
| released tags | the `docs.zip` asset attached to each **GitHub Release** | permanent |
| default branch (e.g. `main`) | the latest CI **push** artifact, else the durable `_sources/<branch>.zip` persisted in the live site | durable (re-persisted each deploy) |
| open PRs (`pr-<n>`) | each PR's build artifact, keyed by head SHA | ephemeral (drops on merge/close) |

Releases are permanent, so old versions never vanish. PR previews come from CI
artifacts and silently drop if the artifact expires and nothing rebuilds — fine for
*optional* preview docs. The **default branch** used to be the one fragile required
version (artifact-only, yet guarded — `assemble` hard-fails rather than publish a
site missing it). It is now self-durable: once it has built docs at least once, each
deploy persists its `docs.zip` into the published site at `_sources/<branch>.zip`, and
a deploy whose fresh artifact has expired restores the branch from that in-site copy —
removing the artifact-expiry hole. (A gh-pages migration still keeps its old `/main/`
content only until the default branch itself builds docs under the new pipeline; from
that point the in-site copy is its durable source — see
[migrate-from-gh-pages](../how-to/migrate-from-gh-pages.md).)

### Why this replaced the `gh-pages` + `keep_files` model

The previous model (mirrored from `python-copier-template-example`) had three
problems for a MyST/book-theme site:

1. **The CI `docs.zip` artifact is not locally previewable.** book-theme emits
   *root-absolute* asset URLs (`/build/_assets/app.css`) regardless of `BASE_URL`,
   so opening `index.html` over `file://` resolves assets against the filesystem root
   → 404 → unstyled, broken. There is no relative-path mode. Local preview means
   `myst start`, or serving a `BASE_URL`-free build over HTTP.
2. **`BASE_URL` is mandatory and per-version.** Each version lives at
   `/<repo>/<version>/` and must be built with `BASE_URL=/<repo>/<version>`. One
   build cannot serve two paths.
3. **`keep_files: true` accumulation drifts.** The published site becomes whatever
   has piled up on `gh-pages` over time; there is no single source of truth, and the
   branch history grows without bound.

Reconstructing the live set every deploy and letting `deploy-pages` replace the
whole site makes deletion self-healing: a merged PR or a deleted release simply
isn't gathered next time, so it disappears — no `keep_files` drift, no branch to
prune.

### Migrating from gh-pages

Two facts make the [cutover](../how-to/migrate-from-gh-pages.md) safe and fix its
ordering:

- **Flipping the Pages source from a branch to GitHub Actions is non-destructive.**
  The last `gh-pages` deployment keeps serving until the first Actions deploy
  supersedes it ([community
  discussion #158055](https://github.com/orgs/community/discussions/158055)) — so the
  source can be flipped up front, with no downtime and no blank window.
- **A publish replaces the *whole* site, so the default branch must be durable before
  any publish runs.** A publish that runs before `_sources/<default>.zip` exists would
  drop `/<default>/`. The migration therefore *seeds* the default branch (a published
  `pages-default-seed` release captured from the old gh-pages tree) before the first
  publish — which is the pipeline PR's own CI. This makes that first publish safe even
  when the repo already serves Pages from Actions (where a publish deploys live
  immediately); with `guard-default-branch` at its default `true`, an un-seeded publish
  fails loudly rather than silently dropping the branch.

## The `docs.zip` and version-token contracts

Two small contracts let the build (in CI) and the reconstruction (in `assemble`)
agree without coordinating:

- **`docs.zip` is one zip with a bare `html/` root.** The CI build packs it once and
  delivers the *same file* two ways — uploaded verbatim as the `docs` artifact
  (every run, `compression-level: 0` since it is already compressed) and attached
  verbatim as the `docs.zip` Release asset on tags. So there is a single contract and
  no repack; both release and branch/PR gather unzip the same `html/` shape.
- **The version name is both the site sub-dir and the `BASE_URL`.** A mismatch
  produces a version whose root-absolute assets 404, so the two must be identical.
  They are, by construction: the name is `pr-<n>` (an integer), `main` (the default
  branch), or a tag without `/` (the `tags: ['*']` trigger never matches `/`). The
  build sets `BASE_URL=/<repo>/<version-name>` and `assemble` files the artifact at
  `site/<version-name>` — the same literal name on both sides. There is **no
  sanitisation**: with nothing to transform, there is nothing to drift, and no parity
  test to maintain.

## Split build (unprivileged) from publish (privileged)

A `pull_request` run from a **fork** gets a read-only `GITHUB_TOKEN` and no secrets —
a deliberate security boundary, so a PR can't deface the site or exfiltrate secrets.
The architecture makes that boundary structural by splitting build from publish:

- **CI (unprivileged)** runs `myst build` and uploads the `docs` artifact for
  *every* event, forks included. It never holds a write token.
- **`publish.yml` (privileged)** runs `assemble` + the Pages deploy. It runs only in
  the trusted upstream context.

So a fork's build can never reach a write token; only trusted code deploys.

### Why publish is *nested* in CI (for internal events)

The deploy is surfaced as a **job inside the CI run** (`ci.yml`'s `publish` job →
`publish-dispatch.yml` shim → `publish.yml` via `workflow_call`) so its status and URL are
visible on the PR / commit — rather than running invisibly after the fact. A single
`publish` job runs for **every** event; `publish.yml` does the branching.

`publish.yml` is the `workflow_call` **engine** and owns all the publish branching,
reached only through a thin `publish-dispatch.yml` shim that exposes it as both
`workflow_call` (the inline `publish` job) and `workflow_dispatch` (the tag
re-dispatch, the fork-PR opt-in, manual re-deploys). It routes each event to one of three
jobs: **deploy** (internal PR / default-branch push, or a dispatch), **re-dispatch** (a tag
— below), or **warn** (a fork PR — read-only, never deploys, just posts the manual-opt-in
hint; this replaced the old warning step in the build job). A fork PR can't reach a write
token (its `GITHUB_TOKEN` is read-only and `deploy` is `if`-excluded for forks), so the
security boundary holds while the hint lives next to the rest of the publish logic. The
shim exists only because a reusable workflow can't be `workflow_dispatch`'d cross-repo, so
the re-dispatch job needs a local file to re-fire — it `gh workflow run`s the shim by name
(`dispatch-workflow`), which works because a called workflow runs with the *caller's* repo
and token. This repo dogfoods the exact shim a consumer adds (theirs just pins
`publish.yml@<tag>`).

The cost of nesting is an environment-policy change: because internal PRs now deploy
from **their own ref**, the `github-pages` environment's deployment-branch policy must
allow those refs. The alternative — triggering publish via `workflow_run` after CI
completes — keeps deploys on the default branch only, but at the price of the deploy
being invisible on the PR. This project chose visibility. (Tags are the exception —
they deploy from the default-branch ref via the re-dispatch below, not their own ref.)

### Why tags deploy via a `workflow_dispatch` re-dispatch

A release tag is cut on the merge commit, so it shares the default branch's
just-deployed SHA. `deploy-pages` stamps every deployment with
`pages_build_version = GITHUB_SHA` — it has no input to change it, and the value is
server-validated against the deploy OIDC token's commit claim, so a unique value
can't be forced (it 404s; see [`actions/deploy-pages#383`](https://github.com/actions/deploy-pages/issues/383)).
The Pages backend then silently **drops a second deploy of an already-deployed SHA**
on a non-`workflow_dispatch` event — it reports success and flips the deployment
record active, but the origin keeps serving the *first* artifact. So an inline tag
deploy would "succeed" while the site stayed on the pre-tag build.

The one documented escape hatch: a `workflow_dispatch` deploy of that same SHA
*forces* a re-serve. So tags don't deploy inline — `publish.yml`'s `re-dispatch` job
waits for `ci.yml`'s parallel `release` job to attach the new `docs.zip`, then
`gh workflow run`s the shim as a `workflow_dispatch`; that run re-gathers from durable
sources (now including the new release) and deploys, and because its event is
`workflow_dispatch` the origin updates. `main` and internal-PR deploys are the *first* of
their SHA, so they serve fine inline and keep their PR/commit visibility. This all lives
in the shared engine — the consumer's only dispatch-related file is the thin shim (a
reusable workflow can't be dispatched cross-repo, so the re-dispatch job needs a local file
to re-fire).
The post-deploy origin-verify step in `publish.yml` backstops any residual stale
origin by failing the run instead of serving stale docs silently.

### Why the current build is *injected*

Because the inline publish runs *inside* the build's own CI run, that run isn't a
*completed* successful run yet — so `assemble`'s normal gather can't discover it. For
a `main` push it would be worse than missing: the gather would find the **previous**
successful run and publish a build behind by one commit. So `ci.yml` passes the
build's version name to `publish.yml`, which hands it to `assemble` as
`ARTIFACT_VERSION_NAME`; `publish.yml` downloads this run's `docs` artifact and
`assemble` unzips + stages it directly, **skipping the re-gather of that version**.
Everything else still comes from durable sources. The dispatch paths (the tag
re-dispatch and the fork opt-in) pass no current build — they gather entirely from
durable sources, the tag from its just-attached `docs.zip` Release asset and a fork
from its approved head SHA's successful run.

## The bash / JS split inside `assemble`

`assemble` is two implementation files, run directly by `publish.yml` (which
sparse-checks-them-out at `job.workflow_sha`):

- **`assemble.sh`** does the IO plumbing — `gh` downloads, `unzip`, `mv`, the
  `stable/` symlink — where shelling out is concise. It is also runnable standalone,
  so the `gh` plumbing can be exercised locally.
- **`assemble.mjs`** is the pure-ish kernel: ordering, prerelease detection,
  `switcher.json`/redirect rendering, and the folded-in required-branch guard. Its
  functions take plain data and return strings/verdicts, so they unit-test without
  git, the network, or the filesystem.

Pure bash is ruled out — semver ordering, prerelease detection and JSON rendering
are not unit-testable in bash. Bash never parses JSON itself: every extraction uses
`gh`'s built-in `-q`/`--jq` (it embeds real jq), never a piped standalone `jq` — a
`gh … | jq` pipe would mask an API failure as empty output. Gather order is
irrelevant; all ordering and prerelease logic lives in `generate`.

## Fork-PR previews: per-commit maintainer opt-in

The risk with a fork PR is not the build (it never holds a write token) but
**serving fork-authored HTML/JS under the canonical `*.github.io` domain** —
phishing/defacement under a trusted URL, and free arbitrary-content hosting. So a
fork preview is **never automatic** and is **pinned to a specific commit**:

- A maintainer who has reviewed the PR runs `publish.yml` via `workflow_dispatch`
  with the PR number. That privileged run (only write-access users can dispatch it)
  sets a `preview-approved` **commit status** on the PR's *current head SHA*, then
  assembles.
- `assemble` includes a fork PR **only when its head SHA carries that status**.
  Approval is therefore **per-commit**: a new push changes the head SHA, the status
  no longer matches, and the preview **silently drops on the next deploy** until a
  maintainer re-approves — closing the bait-and-switch hole (approve benign docs,
  then push malicious content).
- The approval is durable GitHub state (a commit status), re-read by *every*
  assemble, so it survives unrelated deploys. Closing/merging the PR drops it (gather
  is open-PRs only); a maintainer can `POST` a `failure` status to revoke early.

Rejected alternatives: **`pull_request_target`** (privileged but checks out base code
— building PR-head content under it is the classic RCE footgun, since a MyST build
runs PR-authored plugins); **auto-publishing every fork PR** (unattended untrusted
content on the canonical domain); **the fork's own Pages** (required all-branch push
triggers and gave contributors no canonical preview).

## Stable alias

Other projects fetch this site's `objects.inv` for cross-references, so they need a
**stable URL that always points at the latest release** — not a version number that
changes every release. The site therefore publishes a `stable/` alias.

- **`stable/` is the newest deployed non-prerelease tag — never `main`.** Before the
  first release there is no `stable/`; the root redirect falls back to `main`.
- **It is a symlink in the assembled tree** (`ln -s "$preferred" stable`).
  `upload-pages-artifact` tars with `--dereference`, so it is inflated to a real copy
  at deploy.
- **The root `index.html` redirects to `stable/`** (a constant target) whenever it
  exists, so the canonical entry URL never changes.

MyST writes **base-relative** URIs into `objects.inv`, so a consumer pointing
intersphinx at `…/repo/stable/` resolves every target under `/stable/` — the links
stay stable rather than pinning to a concrete version.

The widget keeps `switcher.json` listing **real versions only** (no `stable` entry),
with `preferred: true` on the latest release. Visiting `/stable/` selects the
concrete release it aliases (so the dropdown shows e.g. `v2.0`, not a separate
"stable" item), and switching to a pinned version preserves the page path onto it.
The `stable` segment name is a fixed convention, hardcoded in the widget.

## Edge cases

- **First deploy:** no releases, only `main` built → single-entry `switcher.json`,
  redirect → `main/`. Graceful; no release required.
- **Release without `docs.zip`** (cut before this scheme): not selected by the
  releases query (it filters on a `docs.zip` asset) → skipped, no hard failure.
- **Default branch missing** (`guard-default-branch: true`): if `main` has no recent
  successful build to gather and none was injected, `generate` **hard-fails** rather
  than publish a site missing it.
- **PR build not yet green / SHA moved:** an open PR whose current head SHA has no
  successful CI run is skipped; its preview appears once the build passes.
- **Merged/closed PR:** drops from the gather (open-PRs only) on the next deploy.
- **Prereleases:** excluded from `preferred`/redirect (an `a`/`b`/`rc` marker, parity
  with the release workflow), but still listed in the switcher if gathered.
- **Concurrency:** `concurrency: { group: pages, cancel-in-progress: false }` makes
  deploys last-writer-wins; reconstructing from durable sources keeps that mostly
  self-healing.

## Deferred: a release-layer cache

Re-downloading and unzipping every release's `docs.zip` on every deploy is the one
recurring cost that scales with the number of releases. A GitHub Actions cache of the
immutable released-tags layer could skip those re-downloads, but it is **deliberately
not built yet** — the dominant cost (N sequential `gh` round-trips) is already
addressed by one paginated releases call, and the benefit is zero at adoption. The
full analysis and an implementation sketch are tracked as future work in
[issue #6](https://github.com/DiamondLightSource/myst-version-switcher-plugin/issues/6).

## Key resolved decisions

- **No action wrapper — `publish.yml` runs `assemble/` directly** (self-checked-out
  at `job.workflow_sha`, so the scripts match the workflow's own ref). The build half
  (`docs.yml`) computes the clean token inline and uploads the `docs` artifact.
- **Direct Pages publish, no `gh-pages` branch** (`upload-pages-artifact` +
  `deploy-pages`), requiring the repo's Pages source set to "GitHub Actions".
- **JS core + bash glue.** Pure functions (and their node tests) live in
  `assemble.mjs`; bash does the `gh`/`unzip`/`mv` IO. Python was a contender (the
  team is Python-heavy) but loses on a second toolchain in a JS-only repo.
- **`release.yml` attaches `docs.zip`** (it downloads the run's artifacts and
  creates/uploads the Release via `gh`, verbatim), so `assemble` only ever *reads*
  release assets.
