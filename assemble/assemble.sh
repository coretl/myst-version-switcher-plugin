#!/usr/bin/env bash
#
# assemble — reconstruct the whole versioned docs site from durable sources into
# $SITE, write switcher.json + a root redirect + the stable/ alias, and print the
# site dir. The reusable publish.yml workflow runs this directly (it checks out
# this repo's assemble/ at the workflow's own ref); it is also runnable standalone
# so the `gh` plumbing can be exercised locally:
#
#   REPO=DiamondLightSource/myst-version-switcher-plugin GH_TOKEN=$(gh auth token) \
#     assemble/assemble.sh
#
# The default branch is the one version with no permanent source (releases have
# their docs.zip Release asset; PRs are ephemeral by design) — it is gathered from
# the latest CI run's `docs` artifact, which EXPIRES. So each deploy also persists
# the default branch's docs.zip into the published site at `_sources/<branch>.zip`,
# and falls back to that durable in-site copy when the fresh artifact is gone, so the
# default branch can't silently drop out once it has built docs at least once. Before
# that first build a migration can publish a one-time seed release ($SEED_TAG) that is
# read as a last resort and persisted to _sources on that deploy.
#
# Driven by env (publish.yml passes these; set them yourself to run locally):
#   REPO                  org/repo for gh lookups + version URLs        (required)
#   GUARD_DEFAULT_BRANCH  'true' (default) → hard-fail if the default branch is
#                         absent from the site; any other value disables the guard
#   GH_TOKEN              token for gh (release assets, runs, statuses)
#   PAGES_URL             base URL of the live Pages site, for the durable default-
#                         branch fallback (default: https://<owner>.github.io/<repo>)
#   SEED_TAG              published seed release tag for the default branch's docs.zip,
#                         read once during a migration (default: pages-default-seed)
#   SITE                  output dir (default: $RUNNER_TEMP/site, else ./_site)
#   ARTIFACT_VERSION_NAME version name (pr-<n> | main | <tag>) to stage directly from
#                         ARTIFACT_ZIP instead of gathering — used when publishing
#                         inside the build's own run (the run isn't a completed
#                         success yet). The matching gather is skipped. The action
#                         downloads the artifact; this script unzips + stages it.
#   ARTIFACT_ZIP          docs.zip (bare html/ root) to stage at ARTIFACT_VERSION_NAME
#
# Requires node + gh + unzip + curl on PATH. assemble.mjs sits next to this script.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${REPO:?REPO is required (org/repo)}"
GUARD_DEFAULT_BRANCH="${GUARD_DEFAULT_BRANCH:-true}"
ARTIFACT_VERSION_NAME="${ARTIFACT_VERSION_NAME:-}"
ARTIFACT_ZIP="${ARTIFACT_ZIP:-}"
if [ -n "${SITE:-}" ]; then :
elif [ -n "${RUNNER_TEMP:-}" ]; then SITE="$RUNNER_TEMP/site"
else SITE="$PWD/_site"
fi
TMP="${RUNNER_TEMP:-$(mktemp -d)}"

# Live Pages URL, for the durable default-branch fallback. Default to the standard
# project-pages URL derived from REPO (owner lowercased for the github.io subdomain);
# override PAGES_URL for user/org pages or a custom domain.
_owner=$(printf '%s' "${REPO%%/*}" | tr '[:upper:]' '[:lower:]'); _name=${REPO#*/}
PAGES_URL="${PAGES_URL:-https://$_owner.github.io/$_name}"
SOURCES_DIR="_sources"   # durable in-site store: $SITE/_sources/<default>.zip
# A migration may publish a one-time seed release holding the default branch's
# docs.zip (e.g. captured from gh-pages), read once to bootstrap _sources/ before the
# branch builds docs itself. Published (a contents:read deploy can't read a draft);
# on this sentinel tag so it never collides with a branch and is excluded as a
# version below. scripts/migrate.sh creates it and deletes it once _sources is live.
SEED_TAG="${SEED_TAG:-pages-default-seed}"

default=$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name)
mkdir -p "$SITE"

# Unzip a docs.zip (bare html/ root) into SITE/<dest>, replacing any prior. A
# missing file or a docs.zip without an html/ root (e.g. a pre-cutover artifact of
# a different shape) is a clean skip, not a hard failure.
extract() {  # $1=zip  $2=dest dir  $3=label
  local t="$TMP/x-$2"
  rm -rf "$t"; mkdir -p "$t"
  if [ -f "$1" ] && unzip -q "$1" 'html/*' -d "$t" 2>/dev/null && [ -d "$t/html" ]; then
    rm -rf "${SITE:?}/$2"
    mv "$t/html" "$SITE/$2"
  else
    echo "::warning::$3: docs.zip missing or has no html/ root — skipping"
  fi
  rm -rf "$t"
}

# Download a run's `docs` artifact (→ <out>/docs.zip); skip on miss (expired).
download_run() {  # $1=runId  $2=out dir  $3=label
  rm -rf "$2"; mkdir -p "$2"
  if ! gh run download "$1" --repo "$REPO" -n docs -D "$2"; then
    echo "::warning::$3 docs artifact unavailable (expired?) — skipping"
    return 1
  fi
}

# --- current build: unzip + stage the docs.zip publish.yml downloaded (if any) ---
# Published inside the build's own run, so it isn't a completed success the gather
# can discover (and a main/tag push would otherwise re-gather the PREVIOUS build).
# Each gather below skips ARTIFACT_VERSION_NAME so nothing clobbers this fresh build.
if [ -n "$ARTIFACT_VERSION_NAME" ]; then
  if [ -f "$ARTIFACT_ZIP" ]; then
    extract "$ARTIFACT_ZIP" "$ARTIFACT_VERSION_NAME" "current build '$ARTIFACT_VERSION_NAME'"
  else
    echo "::error::ARTIFACT_VERSION_NAME=$ARTIFACT_VERSION_NAME but ARTIFACT_ZIP=$ARTIFACT_ZIP is not a file"
    exit 1
  fi
fi

# --- default branch: this run's build, else latest push build, else durable copy ---
# Track the docs.zip the default branch arrived as in `default_zip`, so the persist
# step below can store it verbatim. For the current build it is ARTIFACT_ZIP (already
# staged above). Otherwise try, in order: the fresh CI artifact; the docs.zip a
# previous deploy persisted in the live site (so an artifact expiry can't silently
# drop the branch); and finally a one-time migration seed release. The first that
# works is staged + persisted to _sources/<default>.zip for next time.
default_zip=""
if [ "$default" = "$ARTIFACT_VERSION_NAME" ]; then
  default_zip="$ARTIFACT_ZIP"
else
  # Try each source in turn and ACCEPT it only if it actually staged $SITE/$default.
  # A source that downloads but yields no usable docs.zip — a pre-cutover artifact
  # that is a bare html dir (not a docs.zip), or a docs.zip without an html/ root —
  # must NOT stop the search: the default branch is required, so we fall through to
  # the durable in-site copy and then the migration seed instead of failing hard.
  # (Mid-migration the old pipeline can still upload a `docs` artifact of the wrong
  # shape, so download success alone can't mean the branch is staged.)
  main_run=$(gh run list --repo "$REPO" --workflow ci.yml --branch "$default" \
    --event push --status success --limit 1 --json databaseId -q '.[0].databaseId // empty')
  if [ -n "$main_run" ] && download_run "$main_run" "$TMP/dl-$default" "branch $default"; then
    extract "$TMP/dl-$default/docs.zip" "$default" "branch $default"
    if [ -d "$SITE/$default" ]; then default_zip="$TMP/dl-$default/docs.zip"; fi
  fi
  if [ -z "$default_zip" ] && \
     curl -fsSL "$PAGES_URL/$SOURCES_DIR/$default.zip" -o "$TMP/durable-$default.zip" 2>/dev/null; then
    extract "$TMP/durable-$default.zip" "$default" "branch $default (durable in-site copy)"
    if [ -d "$SITE/$default" ]; then
      default_zip="$TMP/durable-$default.zip"
      echo "::notice::default branch '$default' restored from the durable in-site copy ($PAGES_URL/$SOURCES_DIR/$default.zip)"
    fi
  fi
  if [ -z "$default_zip" ] && \
     gh release download "$SEED_TAG" --repo "$REPO" -p docs.zip -O "$TMP/seed-$default.zip" 2>/dev/null; then
    extract "$TMP/seed-$default.zip" "$default" "branch $default (migration seed)"
    if [ -d "$SITE/$default" ]; then
      default_zip="$TMP/seed-$default.zip"
      echo "::notice::default branch '$default' staged from the migration seed release '$SEED_TAG' — persisted to _sources this deploy"
    fi
  fi
  if [ -z "$default_zip" ]; then
    echo "::warning::default branch '$default': no fresh CI build (with a usable docs.zip), durable in-site copy, or seed release"
  fi
fi

# --- releases: tags whose release has a docs.zip (one paginated call) ---
tags=$(gh api --paginate "repos/$REPO/releases" \
  -q '.[] | select(any(.assets[]; .name=="docs.zip")) | .tag_name')
for tag in $tags; do
  case "$tag" in */*) continue ;; esac          # never built/published; skip
  [ "$tag" = "$default" ] && continue
  [ "$tag" = "$SEED_TAG" ] && continue          # migration seed → staged as the default branch, not a version
  [ "$tag" = "$ARTIFACT_VERSION_NAME" ] && continue  # staged fresh from this run's build
  if gh release download "$tag" --repo "$REPO" -p docs.zip -O "$TMP/rel-$tag.zip"; then
    extract "$TMP/rel-$tag.zip" "$tag" "release $tag"
  else
    echo "::warning::release $tag docs.zip download failed — skipping"
  fi
done

# --- open PRs: internal always, external forks only when approved ---
prs=$(gh pr list --repo "$REPO" --state open --limit 200 \
  --json number,headRefOid,isCrossRepository \
  -q '.[] | [.number, .headRefOid, .isCrossRepository] | @tsv')
while IFS=$'\t' read -r num sha cross; do
  [ -z "$num" ] && continue
  [ "pr-$num" = "$ARTIFACT_VERSION_NAME" ] && continue  # staged fresh from this run's build
  if [ "$cross" = "true" ]; then
    approved=$(gh api "repos/$REPO/commits/$sha/statuses" \
      -q 'any(.[]; .context=="preview-approved" and .state=="success")')
    [ "$approved" = "true" ] || continue       # unapproved fork → skip
  fi
  # The successful CI run for this PR's CURRENT head commit (empty if the latest
  # build hasn't passed yet, or the SHA changed since approval).
  run=$(gh api "repos/$REPO/actions/runs?head_sha=$sha&status=success" \
    -q 'first(.workflow_runs[] | select(.name=="CI") | .id) // empty')
  [ -n "$run" ] || continue
  if download_run "$run" "$TMP/dl-pr-$num" "PR #$num"; then
    extract "$TMP/dl-pr-$num/docs.zip" "pr-$num" "PR #$num"
  fi
done <<< "$prs"

# --- persist the default branch durably in the site ($SITE/_sources/<default>.zip) ---
# Store the docs.zip it arrived as, verbatim, so the NEXT deploy can restore the
# default branch even once the CI artifact expires. The _sources/ dir is published
# with the site and excluded from version discovery (see assemble.mjs).
if [ -n "$default_zip" ] && [ -f "$default_zip" ]; then
  mkdir -p "$SITE/$SOURCES_DIR"
  cp "$default_zip" "$SITE/$SOURCES_DIR/$default.zip"
fi

# --- generate switcher.json + redirect + stable-alias source ---
# `generate` discovers the gathered dirs, orders them, writes switcher.json +
# index.html, and prints the stable-alias source dir (or nothing). It also exit-1s
# (→ set -e) if the --required (default) branch is absent — the required-branch guard.
required=""
[ "$GUARD_DEFAULT_BRANCH" = "true" ] && required="$default"
stable_src=$(node "$here/assemble.mjs" generate \
  --site-dir "$SITE" --repo "$REPO" --required "$required")

# --- stable alias: a symlink, inflated to a real copy by upload-pages-artifact ---
[ -n "$stable_src" ] && ln -s "$stable_src" "$SITE/stable"

echo "Assembled site at $SITE"
[ -n "${GITHUB_OUTPUT:-}" ] && echo "dir=$SITE" >> "$GITHUB_OUTPUT"
