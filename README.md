# release_flow

Release a GitHub repository through review on staging, so production always
runs a commit someone checked, tagged and ready to roll back to.

```text
your branch ──merge──▶ next ──cut──▶ release/<name> ──ship──▶ main
  you test it         CI checks it    staging; people review it   production; tagged
                         ▲                                           │
                         └──────────────── merge-back ───────────────┘
```

The [release map](docs/release_map.html) draws the same flow as a book being
written, bound and published. Download it and open it in a browser.

- **Changelog entries never conflict.** Each PR adds its entry as a file of
  its own in `changelog.d/`. A release gathers them into `CHANGELOG.md`.
- **A release is exactly what its notes say.** `cut` takes the integration
  branch as it stood the last time no entry was waiting, so work merged
  after the release was named waits for the next one.
- **Production runs the reviewed commit.** `ship` finds the release PR and
  the commit staging last deployed, asks before shipping, and merges with
  GitHub's head-commit check. If the branch moved since, nothing ships.
- **One release at a time**, with a GitHub Release and tag for each.

It runs on `git` and the [GitHub CLI](https://cli.github.com) (`gh`), and
has no dependencies beyond Ruby 3.3. Rails isn't required.

## Install

```bash
bundle add release_flow --group development
bundle exec release_flow init
```

`init` writes these files, and keeps any that already exist:

| File | What it's for |
| --- | --- |
| `bin/release` | the command you run |
| `.github/workflows/next_release.yml` | starts releases on its own, once switched on |
| `.github/PULL_REQUEST_TEMPLATE/release.md` | the release PR's body |
| `changelog.d/README.md` | how a PR adds its changelog entry |
| `CHANGELOG.md` | started with an `## [Unreleased]` section if you have none |

Then:

1. Add `bin/release check` to your CI workflow. It fails a PR that edits the
   notes of a release already shipped.
2. Ask for a changelog file in your PR template, for example
   "a file of its own in `changelog.d/`".
3. Create the `next` branch from `main`, and make it the branch PRs target.
4. Deploy `release/**` pushes to staging and `main` pushes to production.
   `ship` reads your staging workflow's runs to find the commit staging ran.
5. Protect `next`, `release/*` and `main` so changes arrive by PR with
   passing checks, and turn on "Automatically delete head branches":
   `bin/release` tells that a release is under way by its branch existing.

## Settings

Everything defaults to the names above. To use others, add a
`.release_flow.yml` at the repository's root, then run `init` (or edit the
files it wrote):

```yaml
integration_branch: develop   # default: next
production_branch: trunk      # default: main
ci_workflow: test.yml         # default: ci.yml, the workflow cut waits on
staging_workflow: staging.yml # default: deploy.yml, whose deploys ship reads
guide: https://example.com/releasing   # where --help and the templates point
template: me/template         # the GitHub repository this one forks, if any
```

A setting it doesn't know stops `bin/release` with the list of those it does.

## Release

```bash
bin/release prepare   # name the release: gather changelog.d/ into CHANGELOG.md, by PR into next
bin/release cut       # push release/<name>, which deploys staging, and open its PR into main
bin/release ship      # merge the reviewed commit, publish v<name>, merge main back into next
bin/release status    # where the release stands, and the command that comes next
```

**Where it stands.** `bin/release status` changes nothing. It prints the
last release shipped, the heads of `main` and `next`, CI on `next`'s head
with its job counts, and each open merge-back, changelog and release PR with
its check progress and whether it can merge. It ends on what is waiting on
what, and the command to run next:

```text
== Release status in me/app ==
  shipped: v2026.10.20
  heads: main at def5678, next at abc1234; main is in next
  next: v2026.10.27 is named, waiting to be cut
  CI on next at abc1234: passed, jobs 20/20 passed, 0 running, 0 failed
  release PR #42 (release/2026.10.27 at abc1234): https://github.com/me/app/pull/42
    checks 14/20 passed, 6 running, 0 failed; mergeable
Waiting: release PR #42's checks are still running.
Next: bin/release ship 42 abc1234 once checks pass and it's reviewed on staging.
```

Every command takes `--dry-run`. A release is named for the day,
`2026.11.02`, and a second that day is `2026.11.02-2`.

**Review on staging.** The release PR's "What ships" is its changelog
section; work through each PR in it on staging. A fix found in review goes
into the release branch by PR, with its changelog line under that release's
`## v<name>` section, not in `changelog.d/`, which would wait for the next
release.

**Hold back a PR** by reverting it on the release branch, by PR, and
deleting its changelog line. To bring it back later, revert the revert on
`next` and add its entry to `changelog.d/` again.

**Ship.** `bin/release ship` shows the PR and the commit it found and asks
`Ship abc1234? [y/N]`. With no terminal, as in CI, name both:
`bin/release ship <PR> <commit>`. If any step stops partway, run it again; it
skips what's done.

**Hotfix.** A fix production can't wait for goes to `main` by PR, with its
entry in `changelog.d/`. Then run `bin/release merge-back`.

## Starting releases on their own

With the workflow switched on, a release is named whenever a PR merges into
`next` and none is under way, and cut once CI passes there. If CI fails
where it would cut, the run fails and says so. Shipping stays a person's
call: run `bin/release ship`, or merge the release PR on GitHub, and the
workflow publishes `v<name>` and merges `main` back into `next`.

### Set up the release token

GitHub runs no checks on a PR opened with a workflow's built-in token, so
the changelog PR would never merge. The workflow needs a token of its own:

1. On GitHub, open **Settings → Developer settings → Personal access tokens →
   Fine-grained tokens → Generate new token**.
2. Under **Repository access**, choose **Only select repositories** and pick
   this repository.
3. Under **Permissions**, set **Contents** and **Pull requests** to **Read and
   write**.
4. Choose an expiry, and note it: once it expires, releases stop starting on
   their own until you replace it.
5. Store it as a secret. The command prompts for it, so it stays out of your
   shell history:

   ```bash
   gh secret set RELEASE_TOKEN --repo <owner>/<repo>
   ```

6. Switch the workflow on:

   ```bash
   gh variable set AUTO_RELEASE --body true --repo <owner>/<repo>
   ```

## A changelog of your own

`ReleaseFlow::Changelog` holds the changelog format and the release-name
convention, and `bin/release` reads them only through its public methods. A
project that keeps its changelog another way can reopen that module in
`bin/release`, after `require "release_flow"`, keeping the method
signatures.

## License

MIT. See [LICENSE.txt](LICENSE.txt).
