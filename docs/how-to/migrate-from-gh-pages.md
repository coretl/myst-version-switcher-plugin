# How-to: migrate from an existing `gh-pages` site

If your docs already publish to a `gh-pages` branch (the `keep_files` model), this
moves you onto the reconstruct-from-durable-sources model **in a single pipeline PR**,
**without losing any served version**, and with an instant rollback until the very last
step. It is **two local `migrate.sh` runs, with your pipeline PR doing the deploy in
between**:

1. **`migrate.sh ORG/REPO`** — backfill releases, seed the default branch, flip the
   Pages source to Actions + open the environment policy. *Uploads and flips only — no
   deploy.*
2. **Open + merge your pipeline PR** — its CI runs the first publish, which reads the
   seed and persists the default branch durably into the site.
3. **`migrate.sh ORG/REPO --delete-gh-pages`** — verify the live site, then delete
   `gh-pages` + the seed release.

## What you are migrating onto (read this first)

Every deploy reconstructs the whole site from sources with **very different
durability** — and the safety of the migration hinges on that difference (see the
[architecture explanation](../explanations/architecture.md)):

| version | source under the new model | durable? |
|---|---|---|
| released tags | a `docs.zip` asset on each **GitHub Release** | **yes, permanent** — but only once attached |
| default branch (`main`) | persisted each deploy into the site at `_sources/<branch>.zip` | **yes** — once one deploy has captured it (seeded in run 1) |
| open PRs (`pr-<n>`) | each PR's build artifact | no — drops on merge/close |

Two consequences drive the procedure:

1. **Your old releases are not durable yet.** Their docs exist only as directories on
   `gh-pages`; the matching Releases have no `docs.zip`. So run 1 includes a one-time
   **backfill** of `docs.zip` onto those Releases — not just a config flip.
2. **The default branch has no permanent source until a publish captures it.** Each
   deploy persists the branch's `docs.zip` into the site (`_sources/<branch>.zip`) and
   restores from there when the CI artifact expires — but before the *first* publish
   there is nothing in the site. So run 1 **seeds** it: it captures the gh-pages
   `<default>/` tree as a published seed release, which the first publish reads and
   persists to `_sources/<branch>.zip`. After that the in-site copy carries `/<default>/`
   — *before* the default branch ever builds docs itself.

For *why* this ordering is safe — the non-destructive source flip and the
seed-before-publish rule — see the [architecture explanation](../explanations/architecture.md#migrating-from-gh-pages).

:::{important} The one rule that matters
*Keep `gh-pages` until `_sources/<default>.zip` is live in the deployed site.* Run 1's
seed gets you there on the first publish; the `--delete-gh-pages` guard probes exactly
this. Deleting `gh-pages` is the **separate, gated final run** — never part of run 1 —
and it removes the seed release too.
:::

## Optional: rehearse on a fork first

To de-risk the real migration, run the whole thing on a fork before touching the
upstream site. A fork copies the repo's `gh-pages` branch and release tags, so the
migration has the same inputs — and it deploys to *your* `github.io`, never upstream's.

1. **Fork the repo and enable Actions on the fork** (the **Actions** tab → enable
   workflows; forks start with Actions disabled). You have admin on your own fork,
   which is what the Pages-source flip in step 2 needs.
2. **Run `migrate.sh` against the fork**, from a clone of it — dry-run first, then for
   real:

   ```bash
   scripts/migrate.sh FORKORG/REPO --dry-run
   scripts/migrate.sh FORKORG/REPO
   ```

3. **Point the publish guard at your fork.** The pipeline's `publish` job is gated
   `if: github.repository == 'ORG/REPO'` so only the canonical repo deploys — on a fork
   that is false, so nothing publishes. On your pipeline branch, comment that line out
   (or set it to `FORKORG/REPO`) so the fork deploys.
4. **Open and merge the pipeline PR on the fork**, working on the fork's `main`. Its CI
   runs the first publish and deploys to `https://FORKORG.github.io/REPO/` — open that
   and check the site and switcher.
5. **When it works, undo the trial change and go upstream.** Restore the guard to
   `github.repository == 'ORG/REPO'` (uncomment / set it back) and open the real PR
   against upstream, then follow the steps below on the upstream repo.

:::{note} What the fork trial does and doesn't cover
It exercises the full prepare → publish path (backfill, seed, the first deploy that
persists `_sources/<default>.zip`), and you can even rehearse the destructive finalize
(`migrate.sh FORKORG/REPO --delete-gh-pages`) without risk — it only touches the fork.
The `<tag>` pins still resolve to this project's upstream releases, so the reusable
workflows behave identically. The only path it doesn't auto-cover is a release: push a
tag to the fork if you also want to rehearse the tag re-dispatch.
:::

## Before you start

- `gh` authenticated with **repo-admin** on the target repo (flipping the Pages source
  and setting the environment policy need admin; a CI token can't — which is why this is
  a local script).
- Run the script from **inside a clone of the target repo**: it reads the repo's tags
  and `gh-pages` tree from the working directory (it fetches `origin/gh-pages` for you).
  Running it from anywhere else will find no tags/branches.

## Step 1 — dry-run (recommended)

```bash
scripts/migrate.sh ORG/REPO --dry-run
```

It prints the backfill + seed plan and probes the current site, uploading nothing and
flipping nothing. Compare the **backfill plan** against the **probe list**: any version
the live site serves that is *not* in the backfill plan is a `gh-pages` directory with
**no matching GitHub Release** — it will be **dropped** from the reconstructed site (it
stays on `gh-pages`, so it is recoverable, but won't be served). Cut real Releases for
any such versions you want to keep before proceeding.

## Step 2 — prepare (uploads + flips; no deploy)

```bash
scripts/migrate.sh ORG/REPO
```

It does the following, then **stops with `gh-pages` intact and still serving**:

1. **Backfill (non-destructive, idempotent).** For each release tag that is a `gh-pages`
   directory and whose Release lacks a `docs.zip`, zip that directory (bare `html/`
   root) and attach it as `docs.zip`. Tags containing `/` are skipped.
2. **Seed the default branch.** Capture the gh-pages `<default>/` tree as the published
   `pages-default-seed` release, so the default branch is durable before any publish.
3. **Flip the Pages source → GitHub Actions** and **open the `github-pages` environment's
   `deployment_branch_policy`** to "no restriction" (so deploys from PR/tag refs — which
   run under the nested-publish model — aren't rejected by the environment). The flip is
   non-destructive; the site keeps serving the last `gh-pages` deployment until step 3
   publishes.

No deploy is triggered here — that is your pipeline PR's job.

## Step 3 — publish, via your pipeline PR

Prepare the new pipeline + `myst.yml` changes from the
[tutorial](../tutorials/adding-to-a-fresh-repo.md) on a branch, and **open the PR only
after run 1 has seeded the default branch** (so its first publish is safe). Then open
and merge it: its CI runs the first **publish** — with the source on Actions, the seed
present, and the env policy open, it reconstructs the whole site
(default branch from the seed, the backfilled releases, any open PRs) and deploys it,
**persisting `_sources/<default>.zip`** into the published site. Merging then has the
default branch build its own docs, so `_sources/<default>.zip` refreshes with real
content and the seed becomes redundant.

Confirm the site is live on the new model (visit `https://ORG.github.io/REPO/` and the
switcher) before finalizing.

## Step 4 — finalize (irreversible)

Once the publish has deployed and `_sources/<default>.zip` is live:

```bash
scripts/migrate.sh ORG/REPO --delete-gh-pages
```

This **guards** the deletion: it refuses unless
`https://ORG.github.io/REPO/_sources/<default>.zip` returns `200` — i.e. the deployed
site holds a durable copy of the default branch, so the new model can reconstruct
`/<default>/` without `gh-pages`. It then verifies the live site, asks you to type the
repo name, deletes `gh-pages`, **and deletes the seed release** (the in-site `_sources`
copy supersedes it). After this, the rollback is gone.

:::{warning} Old pages that reference `gh-pages` at runtime
Docs built under the old model sometimes embed a hardcoded version switcher that reads
`gh-pages` live — via the GitHub *contents API* (`…/contents?ref=gh-pages`) or by
loading assets from a `gh-pages` URL. Those pages are reconstructed verbatim from their
`docs.zip`, so the references remain. After deletion, a switcher that only *queries the
API* degrades harmlessly: the request `404`s, its populate script throws an uncaught
promise (console-only), and the version list simply empties — the page itself is intact.
Anything that *loads assets* (CSS/JS/images) from `gh-pages`, though, will break. `grep`
your old release pages for `gh-pages` before finalizing and accept (the switcher
emptying is usually fine) or fix what you find.
:::

## Rollback

Between run 1 (step 2) and the deletion (step 4), `gh-pages` is no longer *served* but
still *exists* — your rollback. If anything is wrong, flip the Pages source back to
**Deploy from a branch / `gh-pages`** and serving is restored instantly, with nothing
lost. That is exactly why the deletion is a separate, gated run.

## Flags

| flag | effect |
|---|---|
| `--dry-run` | Print the backfill + seed plan + probe the current site only; upload nothing; skip the flip. |
| `--delete-gh-pages` | **The only mode that deletes.** Guard that `_sources/<default>.zip` is live (`200`), verify the live site, then delete `gh-pages` **and the seed release**. |
| `--pages-ref <ref>` | `gh-pages` ref to read (default `origin/gh-pages`). |
| `--yes` | Skip the typed confirmation before deleting `gh-pages` (with `--delete-gh-pages`; use with care). |
