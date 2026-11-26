# Changelog

## [Unreleased]

## 0.3.0

- `bin/release status` shows where the release chain stands, changing nothing: the last release shipped, the `main` and `next` heads, CI on `next` with job counts, each open merge-back, changelog and release PR with its check progress and mergeability, what waits on what, and the command to run next.
- `--wait` on `prepare`, `cut`, `ship` and `merge-back` follows the PR the command opened until the next step is yours, printing a line with the elapsed time at each stage change: the changelog and merge-back PRs until they merge, and for `cut`, CI on `next` and then the release PR's checks. A failing check or a closed PR exits non-zero, naming it; `--timeout MINUTES` (default 45) bounds the wait, and Ctrl-C stops it with exit 130, changing nothing.
- `cut --if-needed` waits without failing while CI is still running on the commit it would cut, so a CI run finishing on an older commit no longer turns the release workflow red; CI that failed still fails it, and `cut` by hand still refuses.
- `cut` refuses when `ci_workflow` has never run on the integration branch, naming the setting, instead of waiting on CI that will never report.
- Under GitHub Actions, a release that waits (`prepare` behind one under way, `cut` behind CI) also shows as a notice on the run and in its step summary.

## 0.2.1

- `prepare` names a project's first release when `CHANGELOG.md` holds only an empty `## [Unreleased]`, instead of crashing with `undefined method 'each_line' for nil`, and the file it writes ends with a single newline.

## 0.2.0

- A release PR merged on GitHub is shipped by the release workflow: it publishes `v<name>` and merges `main` back into `next`. `init` keeps a workflow already installed, so copy the template's `ship` job into yours, add the production branch to its `pull_request` branches, and add the `base.ref` line to `prepare`'s condition.
- `cut` names what keeps `main` out of `next`: an open merge-back, a release merged without being shipped (with the `ship` command that finishes it), or a hotfix needing `bin/release merge-back`.
- `ship` counts `v<name>` as published when another run published it first.

## 0.1.1

- `ReleaseFlow::CLI.start` takes a `config:`, so a binstub can add a setting `.release_flow.yml` doesn't carry, such as a fork's template read from elsewhere; `--help` returns instead of exiting mid-parse.

## 0.1.0

- First release: `bin/release prepare`, `cut`, `ship`, `merge-back` and `check`, extracted from ModelRails; `release_flow init` installs the binstub, the release workflow, the release PR template and the `changelog.d/` README.
