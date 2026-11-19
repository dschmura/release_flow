# `bin/release status` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `bin/release status` prints where each release stands (what waits on the integration branch, the release under way and what staging last deployed, the release production is on) and the command that comes next, changing nothing.

**Architecture:** `Release#status` gathers the facts from git and `gh` into one plain Hash; a new pure module, `ReleaseFlow::Status`, turns that Hash into the report. This mirrors how `Candidate` and `Changelog` hold the decisions while `Release` does the I/O, and it leaves a seam for other output later without building one now.

**Tech Stack:** Ruby 3.3 standard library, `git`, the GitHub CLI (`gh`), RSpec, StandardRB.

**Spec:** none. The Design section below is the spec.

## Design

The state is already in the repository; `status` only reads it:

| Fact | Where it comes from |
| --- | --- |
| entries waiting for a release | `Changelog.unreleased(next_changelog, fragments_at("origin/<integration>").values)` |
| a changelog PR not yet merged | a `refs/heads/changelog/*` entry in `remote_refs` |
| a release named, not shipped | `Changelog.named_release(next_changelog)` when `!shipped?(name)` |
| a release cut | a `refs/heads/release/<name>` entry in `remote_refs`; its head is `git rev-parse origin/release/<name>` |
| its PR | the same `gh pr list --base <production> --state all --limit 30 --json number,headRefName,state,headRefOid` call `waiting_release` makes; the entry with that `headRefName` and `"state" == "OPEN"` |
| what staging last deployed | the same `gh run list --workflow <staging_workflow> --branch <branch> --event push --json headSha,conclusion` call `waiting_release` makes, with `status: true`; the first run whose conclusion is `success` |
| the release production is on | the newest tag `main` contains: `git tag --merged origin/<production> --sort=-creatordate --list "v*"`, first line matching `/\Av(#{Changelog::NAME})\z/`; commits since it by `git rev-list --count v<name>..origin/<production>` |
| whether production is merged back | `ancestor?("origin/<production>", "origin/<integration>")` |

`status` fetches first, as every other command does. It never raises over an odd state it can describe (two release PRs, a release branch with no PR, a staging workflow `gh` can't list); it describes it. It does not use `Candidate.waiting` or `Candidate.found`, which raise.

Deliberately left out: a `--json` flag, colour, and any deploy state beyond what staging last ran. The Hash is the seam if one is wanted later.

## Global Constraints

- No new dependencies: Ruby's standard library, `git` and `gh` only.
- `status` is read-only: no push, no `gh pr create`, no `gh pr merge`, and the checkout and working tree are untouched.
- Branch and workflow names come from `@config` (`integration`, `production`, `@config.staging_workflow`), never literals.
- Match the surrounding code: terse methods, sparse comments, messages that say what to do next.
- `bundle exec rspec` and `bundle exec standardrb` both pass before each commit.
- Commit subjects are a plain sentence naming what changed for a user, as in `git log` (for example "release_flow needs Ruby 3.3, the oldest still maintained").
- Two other plans may land around this one (ship waiting on the production deploy, and `bin/release rollback`). They also edit `Release::USAGE`, the `case` in `Release#run`, `README.md` and `CHANGELOG.md`. Keep edits there to single lines so they merge cleanly.

## Review Focus

- **The integration branch doesn't exist yet** (someone runs `status` right after `init`): it stops with a line saying to create it, not `git show failed`. Test in Task 2.
- **Tags that aren't release names** (`v1.2.3`): ignored when finding the release production is on. Test in Task 2.
- **`gh` can't list the staging workflow's runs** (no such workflow file): the report says no staging deploy was found. Test in Task 2.
- **A release branch with no open PR** (a `cut` that stopped after pushing): the report says so and points back to `cut`. Test in Task 1.
- **Production is ahead of the integration branch** (a hotfix not merged back): the report says so and names `merge-back` before `cut`. Tests in Tasks 1 and 2.

---

### Task 1: `ReleaseFlow::Status` turns the facts into the report

**Files:**

- Create: `lib/release_flow/status.rb`
- Modify: `lib/release_flow.rb` (add `require_relative "release_flow/status"` after the `candidate` line)
- Test: `spec/release_flow/status_spec.rb`

**Interfaces:**

- Produces: `ReleaseFlow::Status.report(facts) -> String`, with no trailing newline. `facts` is this Hash, and Task 2 builds exactly it:

```ruby
{
  repo: "me/app", integration: "next", production: "main",
  waiting: ["- First feature."],  # changelog lines no release has named yet
  changelog_branch: nil,          # "changelog/2026.10.27" while prepare's PR hasn't merged
  named: nil,                     # "2026.10.27" while next names a release that hasn't shipped
  release: nil,                   # once cut: {branch: "release/2026.10.27", head: "<40 hex>", pr: 42, staged: "<40 hex>"}; pr and staged may be nil
  shipped: nil,                   # {name: "2026.10.20", commits_since: 0}, the newest release tag production contains
  production_head: "<40 hex>",
  merged_back: true               # production's head is in the integration branch
}
```

The report is a title, three lines, an optional fourth, and a closing line. Commits show as their first 7 characters.

Title: `== Releases in <repo> ==`

Integration line, then one line per entry indented four spaces:

| `waiting` | Line |
| --- | --- |
| empty | `  next: no changelog entries waiting` |
| one | `  next: 1 changelog entry waits for the next release` |
| more | `  next: 3 changelog entries wait for the next release` |

Release line, first row that applies:

| Facts | Line |
| --- | --- |
| `release`, `staged == head` | `  release: v2026.10.27 on release/2026.10.27 at abc1234, PR #42; staging last deployed it` |
| `release`, `staged` another commit | `…at abc1234, PR #42; staging last deployed def5678, not this commit` |
| `release`, `staged` nil | `…at abc1234, PR #42; no successful staging deploy found` |
| `release`, `pr` nil | `…at abc1234, no PR open; …` |
| `named` | `  release: v2026.10.27 is named, waiting to be cut` |
| `changelog_branch` | `  release: changelog/2026.10.27 hasn't merged into next` |
| none | `  release: none under way` |

The release's name is its branch without `release/`.

Production line:

| `shipped` | Line |
| --- | --- |
| nil | `  main: at def5678, no release shipped yet` |
| `commits_since` 0 | `  main: v2026.10.20 at def5678` |
| `commits_since` 1 | `  main: at def5678, 1 commit past v2026.10.20` |
| `commits_since` 2 | `  main: at def5678, 2 commits past v2026.10.20` |

When `merged_back` is false, one more line: `  main isn't in next yet`

Closing line, first row that applies:

| Facts | Line |
| --- | --- |
| `release` with a `pr` | `Then: review it on staging, and run bin/release ship.` |
| `release`, `pr` nil | `Then: bin/release cut again, to open its PR.` |
| `merged_back` false | `Then: merge the open merge-back PR, or run bin/release merge-back.` |
| `named` | `Then: bin/release cut.` |
| `changelog_branch` | `Then: bin/release cut, once changelog/2026.10.27 has merged.` |
| `waiting` any | `Then: bin/release prepare.` |
| none | `Nothing to release.` |

`next` and `main` above are `facts[:integration]` and `facts[:production]`.

- [ ] **Step 1: Write the failing tests**

```ruby
# frozen_string_literal: true

RSpec.describe ReleaseFlow::Status do
  let(:head) { "abc1234#{"0" * 33}" }
  let(:other) { "def5678#{"0" * 33}" }
  let(:cut) { {branch: "release/2026.10.27", head: head, pr: 42, staged: head} }
  let(:facts) do
    {repo: "me/app", integration: "next", production: "main", waiting: [], changelog_branch: nil, named: nil,
     release: nil, shipped: {name: "2026.10.20", commits_since: 0}, production_head: other, merged_back: true}
  end

  def report(**changes) = described_class.report(facts.merge(changes))

  it "reads as a quiet repository when nothing is waiting" do
    expect(report).to eq(<<~TEXT.chomp)
      == Releases in me/app ==
        next: no changelog entries waiting
        release: none under way
        main: v2026.10.20 at def5678
      Nothing to release.
    TEXT
  end

  it "lists the entries waiting and says prepare comes next" do
    expect(report(waiting: ["- First feature.", "- A bug."])).to include(
      "  next: 2 changelog entries wait for the next release\n    - First feature.\n    - A bug.\n"
    ).and end_with("Then: bin/release prepare.")
  end

  it "shows a release on staging at the commit staging ran, and says ship comes next" do
    expect(report(named: "2026.10.27", release: cut)).to include(
      "  release: v2026.10.27 on release/2026.10.27 at abc1234, PR #42; staging last deployed it"
    ).and end_with("Then: review it on staging, and run bin/release ship.")
  end

  it "uses the branch names it is given" do
    expect(report(integration: "develop", production: "trunk", merged_back: false)).to include(
      "  develop: no changelog entries waiting", "  trunk: v2026.10.20 at def5678", "  trunk isn't in develop yet"
    )
  end
end
```

Add one example per remaining row of the four tables above, each asserting that row's line with `include` or `end_with`: one entry waiting; staging on another commit; no staging deploy; no PR open (with its closing line); named; changelog branch (with its closing line); no release shipped; one and two commits past; `merged_back: false` winning over `named` for the closing line.

- [ ] **Step 2: Run them to see them fail**

Run: `bundle exec rspec spec/release_flow/status_spec.rb`
Expected: FAIL with `uninitialized constant ReleaseFlow::Status`

- [ ] **Step 3: Implement `ReleaseFlow::Status.report(facts)` in `lib/release_flow/status.rb`**

A `module_function` module like `Candidate`, with a one-line comment above it saying what it is. Private helpers for each line keep `report` short.

- [ ] **Step 4: Run the tests and the linter**

Run: `bundle exec rspec spec/release_flow/status_spec.rb && bundle exec standardrb`
Expected: all examples pass, no offenses

- [ ] **Step 5: Commit**

```bash
git add lib/release_flow/status.rb lib/release_flow.rb spec/release_flow/status_spec.rb
git commit -m "Status reads where each release stands from the facts it's given"
```

---

### Task 2: `bin/release status` gathers the facts and prints the report

**Files:**

- Modify: `lib/release_flow/release.rb` (`USAGE` at line 18, the `case` in `run` at lines 30-37, a `status` method beside `check`)
- Modify: `README.md` (the Release section), `CHANGELOG.md` (under `## [Unreleased]`)
- Test: `spec/release_flow/release_spec.rb` (a new `describe "status"` after `describe "check"`)

**Interfaces:**

- Consumes: `ReleaseFlow::Status.report(facts)` and the facts Hash from Task 1.
- Produces: the `status` command. `Release::USAGE` ends `… | merge-back | check | status`.

The spec file's helpers do the setup: `setup_repo` leaves `origin/main` at the first commit and `origin/next` one commit ahead; the fake `gh` answers `pr list` with `gh_prs` and `run list --workflow deploy.yml` with `gh_deploys`; `run_release` captures output in `@output`; `calls` is the log of `gh` invocations.

- [ ] **Step 1: Write the failing tests**

```ruby
describe "status" do
  let(:main) { git("rev-parse", "--short=7", "origin/main") }

  it "shows the entries waiting on next and that prepare comes next" do
    setup_repo
    run_release("status")

    expect(@output).to include("== Releases in me/app ==")
    expect(@output).to include("  next: 3 changelog entries wait for the next release\n    - First feature.\n    - Second feature.\n    - A bug.")
    expect(@output).to include("  release: none under way")
    expect(@output).to include("  main: at #{main}, no release shipped yet")
    expect(@output).to end_with("Then: bin/release prepare.\n")
  end

  it "shows a named release waiting to be cut" do
    setup_repo(next_changelog: named)
    run_release("status")

    expect(@output).to include("  next: no changelog entries waiting")
    expect(@output).to include("  release: v2026.10.27 is named, waiting to be cut")
    expect(@output).to end_with("Then: bin/release cut.\n")
  end

  it "shows a changelog PR that hasn't merged" do
    setup_repo
    git("push", "-q", "origin", "HEAD:refs/heads/changelog/2026.10.27")
    run_release("status")

    expect(@output).to include("  release: changelog/2026.10.27 hasn't merged into next")
  end

  context "when a release is cut" do
    let(:head) { git("rev-parse", "HEAD") }
    let(:gh_prs) { %(echo '[{"number":42,"headRefName":"release/2026.10.27","state":"OPEN","headRefOid":"#{head}"}]') }
    let(:gh_deploys) { %(echo '[{"headSha":"#{head}","conclusion":"success"}]') }

    before do
      setup_repo(next_changelog: named)
      git("push", "-q", "origin", "HEAD:refs/heads/release/2026.10.27")
    end

    it "shows its PR and that staging ran its head, and says ship comes next" do
      run_release("status")

      expect(@output).to include("  release: v2026.10.27 on release/2026.10.27 at #{head[0, 7]}, PR #42; staging last deployed it")
      expect(calls).to include("CALL pr list --base main")
      expect(calls).to include("CALL run list --workflow deploy.yml --branch release/2026.10.27 --event push")
      expect(@output).to end_with("Then: review it on staging, and run bin/release ship.\n")
    end

    context "when gh can't list the staging workflow's runs" do
      let(:gh_deploys) { "echo 'could not find any workflows named deploy.yml' >&2; exit 1" }

      it "says no staging deploy was found" do
        run_release("status")

        expect(@output).to include("PR #42; no successful staging deploy found")
      end
    end
  end

  it "shows the release main is on, passing over tags that aren't release names" do
    setup_repo
    git("push", "-q", "origin", "origin/main:refs/tags/v2026.10.20", "origin/main:refs/tags/v1.2.3")
    run_release("status")

    expect(@output).to include("  main: v2026.10.20 at #{main}")
  end

  it "says when main is ahead of next, and that merge-back comes next" do
    setup_repo(next_changelog: named)
    hotfix = git("commit-tree", "origin/main^{tree}", "-p", "origin/main", "-m", "hotfix")
    git("push", "-q", "origin", "#{hotfix}:refs/heads/main")
    run_release("status")

    expect(@output).to include("  main isn't in next yet")
    expect(@output).to end_with("Then: merge the open merge-back PR, or run bin/release merge-back.\n")
  end

  it "stops, saying to create it, when origin has no integration branch yet" do
    setup_repo
    git("push", "-q", "origin", "--delete", "next")

    expect { run_release("status") }.to raise_error(ReleaseFlow::Release::Error, /origin has no next branch yet: create it from main/)
  end

  it "changes nothing" do
    setup_repo
    before = git("ls-remote", "origin")
    run_release("status")

    expect(git("ls-remote", "origin")).to eq(before)
    expect(calls).not_to match(/pr create|pr merge|release create/)
  end
end
```

Add one example to `describe "a repository with other names, set in .release_flow.yml"`: after `setup_repo` and `rename_branches`, `run_release("status")` prints `  develop: 3 changelog entries wait for the next release` and `  trunk: at <short sha of origin/trunk>, no release shipped yet`.

- [ ] **Step 2: Run them to see them fail**

Run: `bundle exec rspec spec/release_flow/release_spec.rb -e "status"`
Expected: FAIL with `usage: bin/release prepare | cut | …`

- [ ] **Step 3: Implement `status` in `lib/release_flow/release.rb`**

- `USAGE`: append ` | status`.
- `run`: add `when "status" then status`.
- `status`, placed beside `check`: `fetch`; raise `Error, "origin has no #{integration} branch yet: create it from #{production}"` unless `branch?(integration)`; then `say(Status.report(facts))`, the facts built as the Design table says. With several `release/*` branches open, report the first by name.

- [ ] **Step 4: Run the whole suite and the linter**

Run: `bundle exec rspec && bundle exec standardrb`
Expected: all examples pass, no offenses

- [ ] **Step 5: Document it**

`README.md`, in the Release section's command block, add after the `ship` line:

```bash
bin/release status    # where each release stands, and the command that comes next
```

and after the sentence about `--dry-run` and release names, a new paragraph:

```markdown
**See where things stand.** `bin/release status` shows the changelog entries
waiting on `next`, the release under way and what staging last deployed, the
release `main` is on, and the command that comes next. It changes nothing.
```

`CHANGELOG.md`, under `## [Unreleased]`:

```markdown
- `bin/release status` shows the changelog entries waiting on the integration branch, the release under way and what staging last deployed, the release production is on, and the command that comes next.
```

- [ ] **Step 6: Commit**

```bash
git add lib/release_flow/release.rb spec/release_flow/release_spec.rb README.md CHANGELOG.md
git commit -m "bin/release status shows where each release stands and what comes next"
```
