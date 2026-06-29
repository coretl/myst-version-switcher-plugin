# Tutorial: add versioned docs to a fresh repo

This walks you, start to finish, through giving a MyST docs site a pydata-style
version switcher and a versioned GitHub Pages deployment. By the end you will have:

- the switcher dropdown in your navbar,
- every push to `main`, tag, and internal PR published at its own URL, and
- a `stable/` alias pointing at your latest release.

It assumes a repo that already builds docs with `myst build --html` from a `docs/`
directory. Replace `ORG/REPO` throughout. The snippets below are pinned to the
latest release (`__LATEST_TAG__`); bump that pin to any version from this project's
[releases](https://github.com/DiamondLightSource/myst-version-switcher-plugin/releases)
when you need a different one.

## 1. Add the plugin to your MyST project

In `docs/myst.yml`, load the plugin from its release asset and route a navbar part:

```yaml
# docs/myst.yml
project:
  plugins:
    - https://github.com/DiamondLightSource/myst-version-switcher-plugin/releases/download/__LATEST_TAG__/version-switcher.mjs
site:
  template: book-theme
  parts:
    navbar_end: navbar_end.md
```

Then place the directive (see the [directive reference](../reference/directive.md)
for all options):

```markdown
<!-- docs/navbar_end.md -->
:::{version-switcher}
:json-url: https://ORG.github.io/REPO/switcher.json
:::
```

The `json-url` points at a `switcher.json` that does not exist yet — `publish.yml`
will generate it on your first deploy.

## 2. Set the Pages source to "GitHub Actions" and allow deploys from any ref

In **Settings → Pages**, set **Source** to **GitHub Actions** (not "Deploy from a
branch"). `deploy-pages` refuses to publish otherwise.

Because internal PRs deploy from their own ref, the `github-pages` environment's
deployment policy must allow those refs. In **Settings → Environments →
github-pages**, it is recommended to set **Deployment branches and tags** to
**No restriction**.

## 3. Add the workflow files

Your project will use this project's two reusable workflows to build a single
version of the docs, then publish all available versions of the docs into a
single GitHub Pages site.

It is recommended that you use the structure below.

### `ci.yml`

This is the entry point, it defines three jobs:

- **`docs`** — `docs.yml` builds your site at the versioned `BASE_URL` and uploads the
  `docs` artifact, for every event (fork PRs included).
- **`release`** — a small tag-only job that attaches the built `docs.zip` to the GitHub
  Release.
- **`publish`** — calls your `publish-dispatch.yml` wrapper which publishes the complete
  built site (with all versions) to GitHub Pages.

```yaml
# .github/workflows/ci.yml
name: CI
on:
  pull_request:
  push: 
    branches: [main]
    tags: ['*']

jobs:
  docs:   # Call the docs building workflow directly
    uses: DiamondLightSource/myst-version-switcher-plugin/.github/workflows/docs.yml@__LATEST_TAG__
    with:
      # Whatever turns your sources into docs/_build/html at $BASE_URL. uv and Node
      # are preinstalled, so: make docs · tox -e docs · npm ci && npm run docs
      build-command: myst build --html

  release: 
    needs: [docs]
    if: github.ref_type == 'tag'            # tag pushes only
    uses: DiamondLightSource/myst-version-switcher-plugin/.github/workflows/release.yml@__LATEST_TAG__
    permissions:
      contents: write                       # create the Release + attach assets

  publish:
    needs: [docs]
    # don't publish a pages site in the fork's org
    if: github.repository == 'ORG/REPO'
    uses: ./.github/workflows/publish-dispatch.yml   # your workflow (below)
    with:
      version-name: ${{ needs.docs.outputs.version-name }}
    permissions:
      contents: read
      actions: write
      pages: write
      id-token: write
      statuses: write
```

### `publish-dispatch.yml`

`publish.yml` is the engine and owns all the branching; this is a thin **shim** — the
only thing that calls it, and the one place you pin `@__LATEST_TAG__`. It has to exist as a file
in your repo (not just be `uses:`'d) because the tag re-dispatch re-fires it as a
`workflow_dispatch`, and a reusable workflow can't be dispatched cross-repo. Copy it
verbatim; the only thing to keep current is the `publish.yml` pin, already set to
`__LATEST_TAG__`:

```yaml
# .github/workflows/publish-dispatch.yml
name: Publish (dispatch)
on:
  workflow_call:                    # ci.yml's `publish` job, for every event
    inputs:
      version-name: { required: false, default: "", type: string }
  # tag re-dispatch + fork-PR preview + manual re-deploy
  workflow_dispatch:
    inputs:
      pr:
        description: "Fork PR to approve + preview (empty = re-deploy)"
        required: false
        default: ""
jobs:
  publish:
    uses: DiamondLightSource/myst-version-switcher-plugin/.github/workflows/publish.yml@__LATEST_TAG__
    with:
      # "" on dispatch → pure durable gather
      version-name: ${{ inputs.version-name }}
      # set (dispatch) → pin that fork head SHA
      pr: ${{ inputs.pr }}
      # the file the tag re-dispatch re-fires
      dispatch-workflow: publish-dispatch.yml
    permissions:
      contents: read
      actions: write
      pages: write
      id-token: write
      statuses: write
```

`publish.yml` then routes each event: **deploy** (internal PR / `main` push, or any
dispatch), **re-dispatch** (a tag → re-fires this shim so the deploy runs as a
`workflow_dispatch` — [why](../explanations/architecture.md)), or **warn** (a fork PR,
read-only, never deploys). A maintainer publishes a fork preview by running this workflow
from the Actions tab with the `pr` number.

## 4. Push your branch and open a PR

Make the changes from steps 1 and 3 in a branch and open a PR. On the PR you'll
see:

- **`docs / build`** go green — it builds your docs at the versioned `BASE_URL` and
  uploads the `docs` artifact. This runs for every PR, forks included.
- **`publish / deploy`** runs for an *internal* PR (a branch in your own repo) and
  deploys a preview of just this PR at `https://ORG.github.io/REPO/pr-<n>/`, linked from
  the PR's checks/Deployments. A **fork** PR instead gets **`publish / warn`** (a
  read-only hint — forks never auto-publish); a maintainer dispatches the wrapper with
  the `pr` number to preview one.

:::{note} First-time exception
On a brand-new repo the `publish` check is **red on this setup PR** — there's no
`main` build yet for the versioned site to anchor on, and the default-branch guard
refuses to publish a site missing it. It clears the moment you merge (step 6). Every
PR after that previews normally.
:::

## 5. Merge to main — your first deploy

Merging pushes to `main`, which builds `main` and runs `publish`: it assembles a
single-entry `switcher.json` and an `index.html` redirecting to `main/`, and deploys.
Visit `https://ORG.github.io/REPO/` — the redirect lands you on `main/` with the
switcher showing one entry. (The single-entry first deploy is graceful by design; no
release required.) From here on, every push to `main` redeploys and every internal PR
gets its own `/pr-<n>/` preview.

## 6. Cut your first release

Push a tag:

```bash
git tag v1.0.0 && git push origin v1.0.0
```

The tag build runs and the **`release`** job creates the GitHub Release with that
build's `docs.zip` attached. This works on any repo, including ones with [immutable
releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)
enabled (it attaches the asset as the release is created, before it's sealed).

:::{note} Without immutable releases
You can instead **publish a release from the GitHub UI** — that also creates the tag,
and the `release` job attaches `docs.zip` to the release you published. (This doesn't
work under immutable releases: a published immutable release can't receive assets
after the fact, so use the tag push above.)
:::

Either way, the next deploy's `publish` gathers that release, flags it `preferred` (★),
creates the `stable/` alias pointing at it, and points the root redirect at the constant
`stable/` URL. Your switcher now lists `main` and `1.0.0`, and
`https://ORG.github.io/REPO/stable/` always resolves to the latest release — a stable
URL for cross-project `objects.inv` references.

## Where next

- The [architecture explanation](../explanations/architecture.md) — why it works
  this way.
- The [workflow reference](../reference/workflows.md) — the `docs.yml`/`publish.yml`
  inputs and the `docs.zip` contract.
- Migrating an existing site? See
  [how-to: migrate from `gh-pages`](../how-to/migrate-from-gh-pages.md).
