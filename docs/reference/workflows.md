# Reference: the reusable workflows + contracts

The public interface is two reusable workflows, consumed by `uses:` at a `<tag>`:

```yaml
jobs:
  docs:
    uses: DiamondLightSource/myst-version-switcher-plugin/.github/workflows/docs.yml@<tag>
    with:
      build-command: make docs
  publish:
    needs: [docs]
    if: <internal-event + canonical-repo guard>
    uses: DiamondLightSource/myst-version-switcher-plugin/.github/workflows/publish.yml@<tag>
    with:
      version-name: ${{ needs.docs.outputs.version-name }}
    permissions:
      pages: write
      id-token: write
      contents: read
      actions: read
      statuses: write
```

The site-reconstruction logic (`assemble/`) is **internal** — `publish.yml` runs it
directly; it is not a separately consumed action.

## `docs.yml` — build (unprivileged)

Builds the docs at the versioned `BASE_URL`, packs `docs.zip` (bare `html/` root),
uploads the `docs` artifact, and warns on fork PRs. Declares `contents: read` only —
it never holds a write token. Installs `uv` unconditionally and relies on the runner's
preinstalled Node, so `build-command` can be `make` / `npx` / `tox` / `npm` driven.

| input | required | default | meaning |
|---|---|---|---|
| `build-command` | **yes** | — | Command that builds the HTML site into `html-dir` at `$BASE_URL`. Fold any project setup (`cp CONFIG`, `npm ci`, apt deps) behind it. |
| `html-dir` | no | `docs/_build/html` | Directory the build writes the site to; staged into `docs.zip`'s `html/`. |

| output | meaning |
|---|---|
| `version-name` | The version this build was served at (`pr-<n>` \| default-branch \| `<tag>`) — pass to `publish.yml`. |

## `publish.yml` — the engine, owns the branching (privileged)

Reconstructs the whole site and deploys it to Pages, routing each event to one of three
jobs. The `deploy` job carries the `github-pages` environment, `concurrency: pages`, and
`pages`/`id-token`/`statuses` write. Reached only via the `publish-dispatch.yml` shim
(below); the canonical-repo guard lives upstream (in `ci.yml`), so the engine stays
generic.

- **`deploy`** — internal PR / default-branch push (inline), or any `workflow_dispatch`.
  Self-checks-out this repo's `assemble/` at `job.workflow_sha` / `job.workflow_repository`
  (the `job` context resolves to the reusable file, not the caller), so the scripts match
  the `<tag>` the consumer pinned — no version bump; the consumer's repo stays checked out
  at the root so `assemble.mjs`'s `git tag` lists *their* versions. The inline path injects
  the in-run build via `version-name`; the dispatch paths pure-gather.
- **`re-dispatch`** — a tag push. Waits for the release, then re-fires the shim
  (`dispatch-workflow`, a file in the consumer's repo — a `workflow_call` run executes with
  the caller's token, so it can dispatch it) so the deploy lands as a `workflow_dispatch`
  and re-serves.
- **`warn`** — a fork PR. Read-only, never deploys; just posts the manual-opt-in hint.

**Tags must deploy via `workflow_dispatch`**: GitHub Pages silently drops a second deploy
of an already-deployed SHA (a release tag shares the merge commit's SHA) unless the event
is `workflow_dispatch`
([`actions/deploy-pages#383`](https://github.com/actions/deploy-pages/issues/383); see the
[architecture explanation](../explanations/architecture.md)).

## `publish-dispatch.yml` — the thin shim (one per repo)

The only thing that calls `publish.yml`, the single place you pin `publish.yml@<tag>`, and
the **dispatchable file** the re-dispatch job re-fires. It just forwards to the engine via
`workflow_call` (ci.yml's `publish`, every event) and `workflow_dispatch` (the tag
re-dispatch, a fork-PR preview, a manual re-deploy). A reusable workflow can't be
`workflow_dispatch`'d cross-repo, which is why this file lives in each repo.

### `publish.yml` inputs (threaded through by the shim)

| input | required | default | meaning |
|---|---|---|---|
| `version-name` | no | `""` | Version name of **this run's** `docs` artifact to stage directly, instead of gathering it from durable sources. Set by `ci.yml`'s inline publish (the run isn't a completed success yet, so the gather can't discover it — or would find a stale previous build). Empty → pure durable gather (the dispatch paths). |
| `guard-default-branch` | no | `true` | When `true`, hard-fail if the consumer's default branch is absent from the site (its build artifact expired). Set `false` while a repo's default branch isn't yet publishing `docs.zip` (mid-migration). |
| `pr` | no | `""` | Fork PR number to approve (pins its head SHA as `preview-approved`) and preview. Set on the shim's `workflow_dispatch` path. |
| `dispatch-workflow` | no | `publish-dispatch.yml` | Filename of the shim in the consumer's repo, re-fired by the `re-dispatch` job. Override only if you renamed the shim. |

## What `publish.yml` gathers

Every deploy rebuilds the complete tree from authoritative inputs:

| version kind | source | durability |
|---|---|---|
| current build | this run's `docs` artifact, staged via `version-name` | n/a (just built) |
| default branch (e.g. `main`) | latest CI **push** artifact → durable `_sources/<branch>.zip` in the live site → one-time migration seed release | durable — re-persisted into the site each deploy |
| released tags | the `docs.zip` asset attached to each **GitHub Release** | permanent |
| open PRs (`pr-<n>`) | each PR's build artifact, keyed by current head SHA — internal always, fork PRs only when the SHA carries a `preview-approved` status | ephemeral — drops when the PR merges/closes |

A version no longer gathered (a merged/closed PR, a deleted release) is correctly
dropped, because `deploy-pages` replaces the *entire* site. The version passed as
`version-name` is staged first and **skipped** by every gather, so a stale previous
build never clobbers the fresh one.

## The `docs.zip` / version-name contracts

Two contracts let the build (`docs.yml`) and the reconstruction (`assemble`) agree
without coordination — `docs.yml` owns both:

- **`docs.zip` is one zip with a bare `html/` root.** `docs.yml` packs it once and it
  is delivered the *same file* two ways: uploaded verbatim as the `docs` artifact
  (every run), and attached verbatim as the `docs.zip` Release asset on tags. Both the
  release gather and the branch/PR gather unzip the same `html/` shape.
- **The version name is the site sub-dir *and* the `BASE_URL`.** It is `pr-<n>` for
  PRs, else the ref name (the default branch, or a tag without `/`). `docs.yml` sets
  `BASE_URL=/REPO/<version-name>` and `assemble` files the artifact at
  `site/<version-name>` — the same literal name on both sides, so assets never 404.
  There is **no sanitisation**: version names are clean by construction (the
  `tags: ['*']` trigger never builds `/`-tags).

## Internals: running `assemble` standalone

`assemble/assemble.sh` (run directly by `publish.yml`) is also runnable outside CI so
the `gh` plumbing can be exercised locally:

```bash
REPO=DiamondLightSource/myst-version-switcher-plugin GH_TOKEN=$(gh auth token) \
  assemble/assemble.sh
```

It is driven entirely by env (`REPO`, `GUARD_DEFAULT_BRANCH`, `GH_TOKEN`, `SITE`, and —
for injection — `ARTIFACT_VERSION_NAME` + `ARTIFACT_ZIP`, the `docs.zip` `publish.yml`
downloads before calling the script). The pure logic (ordering, prerelease detection,
`switcher.json`/redirect rendering, the required-branch guard) lives in `assemble.mjs`
and is unit-tested without git, the network, or the filesystem.
