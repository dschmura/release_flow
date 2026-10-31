# Changelog

## [Unreleased]

## 0.1.1

- `ReleaseFlow::CLI.start` takes a `config:`, so a binstub can add a setting `.release_flow.yml` doesn't carry, such as a fork's template read from elsewhere; `--help` returns instead of exiting mid-parse.

## 0.1.0

- First release: `bin/release prepare`, `cut`, `ship`, `merge-back` and `check`, extracted from ModelRails; `release_flow init` installs the binstub, the release workflow, the release PR template and the `changelog.d/` README.
