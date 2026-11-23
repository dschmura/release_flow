# Changelog

## [Unreleased]

- `prepare` names a project's first release when `CHANGELOG.md` holds only an empty `## [Unreleased]`, instead of crashing with `undefined method 'each_line' for nil`, and the file it writes ends with a single newline.

## 0.2.0

- A release PR merged on GitHub is shipped by the release workflow: it publishes `v<name>` and merges `main` back into `next`. `init` keeps a workflow already installed, so copy the template's `ship` job into yours, add the production branch to its `pull_request` branches, and add the `base.ref` line to `prepare`'s condition.
- `cut` names what keeps `main` out of `next`: an open merge-back, a release merged without being shipped (with the `ship` command that finishes it), or a hotfix needing `bin/release merge-back`.
- `ship` counts `v<name>` as published when another run published it first.

## 0.1.1

- `ReleaseFlow::CLI.start` takes a `config:`, so a binstub can add a setting `.release_flow.yml` doesn't carry, such as a fork's template read from elsewhere; `--help` returns instead of exiting mid-parse.

## 0.1.0

- First release: `bin/release prepare`, `cut`, `ship`, `merge-back` and `check`, extracted from ModelRails; `release_flow init` installs the binstub, the release workflow, the release PR template and the `changelog.d/` README.
