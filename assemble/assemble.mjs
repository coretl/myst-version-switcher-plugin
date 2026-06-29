/**
 * assemble — the logic kernel behind the `assemble` composite action.
 *
 * The action reconstructs the *whole* versioned docs site on every deploy from
 * durable sources (main's build, `docs.zip` release assets, open-PR CI artifacts),
 * then the publish workflow deploys it directly to GitHub Pages. Bash does the IO
 * plumbing (`gh` downloads, `unzip`, `mv`); this file is the pure-ish kernel it
 * shells into, exposed as one subcommand:
 *
 *   node assemble.mjs generate --site-dir <dir> --repo <org/repo> [--required <csv>]
 *       → write switcher.json + index.html into <dir>; print the stable-alias
 *         source dir (the newest deployed release) on stdout, or nothing. Runs
 *         after all gathering, so it also exit-1s if a --required branch is
 *         absent from the site (the required-branch guard).
 *
 * The pure functions take plain data so they unit-test without git, the network,
 * or (mostly) the filesystem. Only `discoverVersions`, `getSortedTags` and the
 * `generate` file writes touch IO.
 */
import { execFileSync } from "node:child_process";
import { readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";

/** The `stable/` alias directory name (a fixed convention; see docs/ explanation). */
export const STABLE_ALIAS = "stable";

/**
 * The in-site durable store directory (`_sources/<default>.zip`) that assemble.sh
 * writes the default branch's docs.zip into each deploy. It is published with the
 * site but is NOT a version, so version discovery skips it.
 */
export const SOURCES_DIR = "_sources";

/** Run a git command and return its non-empty stdout lines. */
function gitLines(args) {
	const out = execFileSync("git", args, { encoding: "utf8" });
	return out.trim().split("\n").filter(Boolean);
}

/** Directory names directly under the assembled site root (the gathered versions). */
export function discoverVersions(siteDir) {
	let entries;
	try {
		entries = readdirSync(siteDir, { withFileTypes: true });
	} catch {
		return [];
	}
	return entries
		.filter(
			(d) =>
				d.isDirectory() && d.name !== STABLE_ALIAS && d.name !== SOURCES_DIR,
		)
		.map((d) => d.name);
}

/**
 * Tags newest-first (semver-aware), matching `git tag -l --sort=-v:refname`.
 * Tags containing `/` are dropped: the build trigger (`tags: ['*']`) never builds
 * them, so they have no matching `BASE_URL` build and would only create nested
 * site dirs. Every other tag is used verbatim as its `site/<tag>` dir name.
 */
export function getSortedTags() {
	return gitLines(["tag", "-l", "--sort=-v:refname"]).filter(
		(tag) => !tag.includes("/"),
	);
}

/**
 * Order the gathered versions: `master`, `main`, then tags newest-first, then any
 * leftover directories (e.g. feature-branch previews) alphabetically. `tags` must
 * already be newest-first. Versions are the directory names under `site/` — the
 * current build is already among them, so there is no `add` parameter.
 */
export function orderVersions(builds, tags) {
	const remaining = new Set(builds);

	const versions = [];
	for (const version of ["master", "main", ...tags]) {
		if (remaining.has(version)) {
			versions.push(version);
			remaining.delete(version);
		}
	}
	// Leftover dirs (pr-<n> previews, feature branches) sort naturally so that,
	// e.g., pr-2 precedes pr-10 rather than sorting lexically.
	versions.push(
		...[...remaining].sort((a, b) =>
			a.localeCompare(b, undefined, { numeric: true }),
		),
	);
	return versions;
}

/**
 * Is `tag` a prerelease? Mirrors `release.yml`'s test (an `a`, `b`, or `rc`
 * marker in the name, PEP 440 style) so "stable" means the same thing repo-wide.
 */
export function isPrerelease(tag) {
	return /a|b|rc/i.test(tag);
}

/**
 * The preferred (stable) version: the newest non-prerelease tag that is actually
 * deployed, else `main`, else `master`, else the first version. `tags` must be
 * newest-first; `versions` is the deployed set (output of `orderVersions`).
 */
export function preferredVersion(versions, tags) {
	for (const tag of tags) {
		if (!isPrerelease(tag) && versions.includes(tag)) return tag;
	}
	if (versions.includes("main")) return "main";
	if (versions.includes("master")) return "master";
	return versions[0] ?? null;
}

/**
 * Decide the root redirect target and the stable-alias source.
 *
 * When `preferred` is a genuine deployed non-prerelease *tag*, the site publishes
 * a `stable/` alias pointing at it and the root redirects to the constant
 * `stable/` URL. Before the first release (preferred is `main`/`master`/a
 * leftover, or a prerelease-only fallback) there is no `stable/` and the root
 * redirects straight to that fallback version, as today.
 *
 * @returns {{preferred: string|null, stableSrc: string|null, redirectTarget: string|null}}
 *   `stableSrc` is the version dir to alias as `stable/` (or null); `redirectTarget`
 *   is the dir the root `index.html` should redirect to.
 */
export function stablePlan(versions, tags) {
	const preferred = preferredVersion(versions, tags);
	if (preferred && tags.includes(preferred) && !isPrerelease(preferred)) {
		return { preferred, stableSrc: preferred, redirectTarget: STABLE_ALIAS };
	}
	return { preferred, stableSrc: null, redirectTarget: preferred };
}

/**
 * Required branches that did not end up in the assembled site. Pure. `versions`
 * are the discovered site dirs; a required branch is present iff its name is
 * among them. By the time `generate` runs, the current
 * ref and every gathered branch are already dirs, so this needs no separate
 * "present" bookkeeping. The action gathers a preview for every branch with a
 * recent CI build (dumb bash); this only guards that the required branches
 * (default: the repo's default branch) didn't silently vanish. `generate`
 * hard-fails on a non-empty result.
 *
 * @param {string[]} [required] branches that must be present (raw names)
 * @param {string[]} [versions] discovered site dir names
 * @returns {string[]} the absent required branches
 */
export function missingRequired(required = [], versions = []) {
	const have = new Set(versions);
	return required.filter((branch) => !have.has(branch));
}

/** Build the pydata switcher array for `org/repo`, flagging the stable entry. */
export function switcherStruct(repository, versions, preferred) {
	const [org, repoName] = repository.split("/");
	return versions.map((version) => {
		const entry = {
			version,
			url: `https://${org}.github.io/${repoName}/${version}/`,
		};
		if (version === preferred) entry.preferred = true;
		return entry;
	});
}

/** Serialise the switcher exactly as the Python tool did (2-space JSON). */
export function renderSwitcher(repository, versions, preferred) {
	return JSON.stringify(
		switcherStruct(repository, versions, preferred),
		null,
		2,
	);
}

/** Root redirect to `target` (relative, so it is host- and repo-agnostic). */
export function renderRedirect(target) {
	return `<!DOCTYPE html>
<html>

<head>
    <title>Redirecting to ${target}</title>
    <meta charset="utf-8">
    <meta http-equiv="refresh" content="0; url=./${target}/index.html">
    <link rel="canonical" href="${target}/index.html">
</head>

</html>
`;
}

/* ------------------------------- subcommands ------------------------------ */

/** Split a comma-separated CLI list into trimmed, non-empty entries. */
function csv(value) {
	return (value ?? "")
		.split(",")
		.map((s) => s.trim())
		.filter(Boolean);
}

/**
 * `generate --site-dir --repo [--required <csv>]` — write switcher.json +
 * index.html and emit the stable-alias source. Runs after all gathering, so it
 * also hard-fails (exit 1) if a `--required` branch is absent from the site.
 */
function cmdGenerate(rest) {
	const { values } = parseArgs({
		args: rest,
		options: {
			"site-dir": { type: "string" },
			repo: { type: "string" },
			required: { type: "string" },
		},
	});
	const siteDir = values["site-dir"];
	const repo = values.repo;
	if (!siteDir || !repo) {
		throw new Error(
			"usage: assemble.mjs generate --site-dir <dir> --repo <org/repo> [--required <csv>]",
		);
	}

	const builds = discoverVersions(siteDir);

	// Guard the required branches before writing anything: a required branch
	// with no gathered dir means the deploy would publish a hole.
	const missing = missingRequired(csv(values.required), builds);
	if (missing.length > 0) {
		console.error(
			`Required branch(es) not present in the assembled site (no current build or recent CI artifact): ${missing.join(", ")}`,
		);
		process.exitCode = 1;
		return;
	}

	// Tags are used verbatim as site dirs (getSortedTags drops `/`-tags), so
	// ordering + preferred + stable compare directly against the discovered dirs.
	const tags = getSortedTags();
	const versions = orderVersions(builds, tags);
	const preferred = preferredVersion(versions, tags);
	const { stableSrc, redirectTarget } = stablePlan(versions, tags);

	// Diagnostics go to stderr so stdout carries only the stable-alias source.
	console.error(`Sorted versions: ${JSON.stringify(versions)}`);
	console.error(`Preferred version: ${preferred}`);
	console.error(`Redirect target: ${redirectTarget}`);
	console.error(`Stable alias source: ${stableSrc ?? "(none)"}`);

	writeFileSync(
		join(siteDir, "switcher.json"),
		renderSwitcher(repo, versions, preferred),
		"utf8",
	);
	if (redirectTarget) {
		writeFileSync(
			join(siteDir, "index.html"),
			renderRedirect(redirectTarget),
			"utf8",
		);
	}

	// The only stdout: the dir to symlink as stable/ (empty when no release yet).
	if (stableSrc) console.log(stableSrc);
}

export function main(argv = process.argv.slice(2)) {
	const [cmd, ...rest] = argv;
	switch (cmd) {
		case "generate":
			return cmdGenerate(rest);
		default:
			throw new Error("usage: assemble.mjs generate ...");
	}
}

if (import.meta.url === `file://${process.argv[1]}`) {
	main();
}
