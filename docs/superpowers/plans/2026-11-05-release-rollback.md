# `bin/release rollback` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `bin/release rollback <name>` opens the PR that returns the production branch to the commit before the latest release, and `bin/release merge-back` then records that rollback in the integration branch without undoing the release's work there.

**Architecture:** Two additions to `Release`. `rollback` finds the release tagged at the production branch's head, builds a commit with the tree of the commit before it (through `git commit-tree`, so the checkout is untouched), and proposes it by PR with auto-merge. `merge-back` learns to spot a rollback it hasn't merged back yet and, for that one commit, proposes a merge that keeps the integration branch's tree.

**Tech Stack:** Ruby 3.3 standard library, `git`, the GitHub CLI (`gh`), RSpec, StandardRB.

**Spec:** none. The Design section below is the spec. Read all of it before Task 1: the merge-back half is where a plausible shortcut does real damage.

## Design

Names used below: **M** is the commit `v<name>` is tagged at, the release PR's merge into the production branch. **B** is M's first parent, production as it was before the release. **R** is the commit that lands on production when the rollback PR merges.

### Rolling back

- **Only the latest release, only while it is production's head.** `rollback` looks for a release tag (`v` + `Changelog::NAME`) pointing at `origin/<production>`. If there is none, something landed since (a hotfix) or nothing was ever released, and it refuses: restoring B's tree would silently drop that later work.
- **The rollback is a commit whose tree is B's and whose parent is M**, on a branch `rollback/<name>`, proposed into production with auto-merge like `prepare`'s changelog PR. Production's own deploy then runs it. B is M's first parent whether the release PR was merged, squashed or rebased.
- **Naming the release is the confirmation.** `bin/release rollback` alone changes nothing: it says which release it found, where production would return to, and the command to run. `bin/release rollback <name>` does it. There is no y/N prompt, so it works the same with or without a terminal.
- **A release branch open at the time is stale.** It was cut with the rolled-back work in it; merging it into production after R would produce a tree staging never ran (its own changes minus the rolled-back ones). `rollback` warns and says to delete it and cut again after the merge-back.

### Merging the rollback back

A plain merge-back of R must never happen. R's change against M is "remove everything the release shipped"; merged into the integration branch the ordinary way, git applies that removal there too, and the work the team now needs to fix disappears from it.

So `merge-back` looks first for a rollback among production's commits the integration branch lacks, `git rev-list --first-parent --reverse origin/<integration>..origin/<production>`, oldest first. A commit is a rollback when its first parent carries a release tag and its tree equals the tree of that parent's first parent. That holds however the rollback PR was merged. For the oldest one found:

1. **If the integration branch doesn't contain M yet,** merge M back the ordinary way first (branch `merge-back/<name>`, the same one `ship` queued, at M and not at production's head) and say to run `merge-back` again once it merges. Fixes made on the release branch during review reach the integration branch only through this merge; step 2 would record them as merged without their content.
2. **Otherwise propose a commit whose tree is the integration branch's own and whose parents are the integration branch's head and R,** on `merge-back/rollback-<name>`, with auto-merge. Production becomes an ancestor of the integration branch again, which `cut` requires, and the release's work stays. The next release PR then diffs against R and ships that work again along with its fix.
3. **Mark the GitHub Release:** `gh release edit v<name> --title "Release <name> (rolled back)"`. The tag stays; its name is never reused. If the edit fails, warn and carry on.
4. **If production has moved past R** (a hotfix after the rollback), say to run `merge-back` again; that run finds no rollback waiting and merges the rest the ordinary way.

With no rollback waiting, `merge-back` behaves exactly as it does today.

Nothing is written to the changelog. The rolled-back release keeps its section; the fix adds its own entry to `changelog.d/` as any PR does.

### Messages

`rollback`, in order:

```text
== Roll back v<name> in <repo> ==
  <production> returns to <B, 7 chars>, as it was before v<name>
  ! release/<other> was cut with v<name> in it, so shipping it would merge a tree staging never ran: delete it, and cut again once the merge-back lands
To roll it back: bin/release rollback <name>
```

The `!` line only when a `release/*` branch is open; the last line only when no name was given, and then it stops. With the name given it goes on:

```text
  [dry-run] would push rollback/<name> (<production> as it was at <B, 7 chars>) and queue its PR into <production>
  → <url>, merging into <production> once its checks pass and any required approval is given
Then: bin/release merge-back, once it has merged.
```

The rollback PR: title `Roll back release <name>`; body ``Returns `<production>` to <B, 40 chars>, as it was before release <name>.``; commit message `Roll back release <name>`.

`rollback`'s refusals and early returns:

| When | It says or raises |
| --- | --- |
| production's head is already a rollback, not merged back | says `v<name> is already rolled back on <production>: bin/release merge-back records it in <integration>` |
| the same, merged back | says `v<name> is already rolled back on <production>, and <integration> has it.` |
| no release tag at production's head | raises `<production> is at <7 chars>, where no release is tagged: only the latest release rolls back, and only while nothing has landed on <production> since. Revert by a PR into <production> instead, then run bin/release merge-back` |
| a name given that isn't the release found | raises `v<given> isn't the release <production> is on: v<found> is` |
| M has no parent | raises `v<name> is <production>'s first commit, so there is nothing to return to` |

`merge-back` with a rollback waiting, step 2:

```text
== Merge <production>'s rollback of v<name> back into <integration> in <repo> ==
  [dry-run] would push merge-back/rollback-<name>, which records the rollback and keeps <integration> as it is, and queue its PR into <integration>
  ! couldn't mark v<name> as rolled back on GitHub: <gh's error>
  → <url>, merging into <integration> once its checks pass and any required approval is given
  <integration> keeps v<name>'s work, which ships again with the next release: land its fix there first
Then: bin/release merge-back again, for what landed on <production> after the rollback.
```

The `!` line only if the edit fails; the last line only in case 4. The PR: title `Merge <production> back into <integration> after rolling back <name>`; body ``Records the rollback of release <name> in `<integration>` and keeps its work there, to ship again with the next release. Merge with a merge commit.``; commit message `Merge <production>'s rollback of release <name>, keeping <integration>'s work`.

Step 1 ends with: `Then: bin/release merge-back again, once it has merged, to record the rollback of v<name>.`

## Global Constraints

- No new dependencies: Ruby's standard library, `git` and `gh` only.
- The checkout and working tree are never touched: commits are built with `git commit-tree`, as `commit_on` does.
- `--dry-run` changes nothing for both commands.
- A re-run after a stop picks up where it stopped: `propose` already skips a branch that exists and finds a PR that's open.
- Branch names come from `integration` and `production`, never literals.
- `merge-back` with no rollback waiting is unchanged; the four existing examples under `describe "merge-back, after a hotfix"` pass unedited.
- Match the surrounding code: terse methods, sparse comments, messages that say what to do next.
- `bundle exec rspec` and `bundle exec standardrb` both pass before each commit.
- Commit subjects are a plain sentence naming what changed for a user, as in `git log`.
- Two other plans may land around this one (`bin/release status`, and `ship` waiting on the production deploy). They also edit `Release::USAGE`, the `case` in `Release#run`, the fake `gh` in `release_spec.rb`, `README.md` and `CHANGELOG.md`. Keep edits there small so they merge cleanly.

## Review Focus

- **A release PR that was squashed, so M has one parent:** `rollback` still returns production to M's first parent. Test in Task 1.
- **The release is production's very first commit:** it refuses with the "nothing to return to" message, not `git rev-parse failed`. Test in Task 1.
- **A rollback PR that was squashed or rebased, so R has one parent:** `merge-back` still recognises it. Test in Task 2.
- **A hotfix landed on production after the rollback:** `merge-back` records the rollback alone and says to run again, instead of merging the lot the ordinary way. Test in Task 2.
- **The integration branch moved on after the release:** the merge-back's tree is the integration branch's current tree, later work included. Test in Task 2.

---

### Task 1: `bin/release rollback` proposes production as it was before the release

**Files:**

- Modify: `lib/release_flow/release.rb` (`USAGE` at line 18, the `case` in `run`, a public `rollback(name = nil)` after `ship`, private helpers)
- Test: `spec/release_flow/release_spec.rb` (a new `describe "rollback"` after `describe "ship"`)

**Interfaces:**

- Produces, for Task 2, these private methods of `Release`:
  - `release_at(commit) -> String or nil`: the name of the release tagged at `commit` (`git tag --points-at`, first tag matching `/\Av(#{Changelog::NAME})\z/`).
  - `first_parent(commit) -> String or nil`: from `git rev-list --parents -n 1 <commit>`, which doesn't fail on a parentless commit.
  - `undone_release(commit) -> String or nil`: the name of the release `commit` undoes, by the rule in the Design section; `nil` for any commit that isn't a rollback, including ones with no parent or grandparent.
- Produces: the `rollback` command. `Release::USAGE` gains `rollback [<release>]` before `merge-back`.

- [ ] **Step 1: Write the failing tests**

`setup_repo(next_changelog: named)` leaves `origin/main` at the first commit and `origin/next` one commit ahead, naming release 2026.10.27. This helper ships it:

```ruby
describe "rollback" do
  # main gets the release's merge, tagged; next gets it too once merged back.
  def release_on_main(merged_back: true)
    setup_repo(next_changelog: named)
    merge = git("commit-tree", "origin/next^{tree}", "-p", "origin/main", "-p", "origin/next", "-m", "Merge release 2026.10.27")
    git("push", "-q", "origin", "#{merge}:refs/heads/main", "#{merge}:refs/tags/v2026.10.27")
    git("push", "-q", "origin", "#{merge}:refs/heads/next") if merged_back
    merge
  end

  def before(merge) = git("rev-parse", "#{merge}^1")

  it "without a name, says which release it would roll back and how, and changes nothing" do
    merge = release_on_main
    run_release("rollback")

    expect(@output).to include("== Roll back v2026.10.27 in me/app ==")
    expect(@output).to include("  main returns to #{before(merge)[0, 7]}, as it was before v2026.10.27")
    expect(@output).to end_with("To roll it back: bin/release rollback 2026.10.27\n")
    expect(remote_heads).not_to include("rollback/2026.10.27")
    expect(calls).not_to include("pr create")
  end

  it "named, pushes main as it was before the release and queues its PR into main" do
    merge = release_on_main
    run_release("rollback", "2026.10.27")

    expect(git("rev-parse", "origin/rollback/2026.10.27^{tree}")).to eq(git("rev-parse", "#{before(merge)}^{tree}"))
    expect(git("rev-parse", "origin/rollback/2026.10.27^")).to eq(merge)
    expect(calls).to include("CALL pr create --base main --head rollback/2026.10.27 --title Roll back release 2026.10.27")
    expect(calls).to include("CALL pr merge https://github.com/me/app/pull/42 --auto --merge")
    expect(@output).to end_with("Then: bin/release merge-back, once it has merged.\n")
  end

  it "changes nothing under --dry-run" do
    merge = release_on_main
    run_release("rollback", "2026.10.27", dry_run: true)

    expect(@output).to include("[dry-run] would push rollback/2026.10.27 (main as it was at #{before(merge)[0, 7]}) and queue its PR into main")
    expect(remote_heads).not_to include("rollback/2026.10.27")
    expect(calls).not_to include("pr create")
  end

  it "leaves the local checkout untouched" do
    release_on_main
    status = git("status", "--porcelain")
    run_release("rollback", "2026.10.27")

    expect(git("status", "--porcelain")).to eq(status)
  end

  it "picks up its own branch when a stopped run already pushed it" do
    merge = release_on_main
    git("push", "-q", "origin", "#{merge}:refs/heads/rollback/2026.10.27")
    run_release("rollback", "2026.10.27")

    expect(git("rev-parse", "origin/rollback/2026.10.27")).to eq(merge)
    expect(calls).to include("CALL pr create --base main --head rollback/2026.10.27")
  end

  it "refuses a name that isn't the release main is on" do
    release_on_main

    expect { run_release("rollback", "2026.10.20") }
      .to raise_error(ReleaseFlow::Release::Error, /v2026\.10\.20 isn't the release main is on: v2026\.10\.27 is/)
  end

  it "refuses once something has landed on main since the release" do
    merge = release_on_main
    hotfix = git("commit-tree", "#{merge}^{tree}", "-p", merge, "-m", "hotfix")
    git("push", "-q", "origin", "#{hotfix}:refs/heads/main")

    expect { run_release("rollback", "2026.10.27") }.to raise_error(ReleaseFlow::Release::Error,
      /main is at #{hotfix[0, 7]}, where no release is tagged: only the latest release rolls back.*bin\/release merge-back/m)
    expect(remote_heads).not_to include("rollback/2026.10.27")
  end

  it "warns that an open release branch was cut with the release in it" do
    release_on_main
    git("push", "-q", "origin", "origin/next:refs/heads/release/2026.10.27-2")
    run_release("rollback")

    expect(@output).to include("  ! release/2026.10.27-2 was cut with v2026.10.27 in it, so shipping it would merge a tree staging never ran")
  end

  it "returns main to the release's first parent when its PR was squashed" do
    setup_repo(next_changelog: named)
    squash = git("commit-tree", "origin/next^{tree}", "-p", "origin/main", "-m", "Release 2026.10.27")
    git("push", "-q", "origin", "#{squash}:refs/heads/main", "#{squash}:refs/tags/v2026.10.27")
    run_release("rollback", "2026.10.27")

    expect(git("rev-parse", "origin/rollback/2026.10.27^{tree}")).to eq(git("rev-parse", "#{squash}^^{tree}"))
  end

  it "refuses a release that is main's first commit, since there is nothing to return to" do
    setup_repo
    git("push", "-q", "origin", "origin/main:refs/tags/v2026.10.27")

    expect { run_release("rollback", "2026.10.27") }
      .to raise_error(ReleaseFlow::Release::Error, /v2026\.10\.27 is main's first commit, so there is nothing to return to/)
  end

  context "when main's head already rolls the release back" do
    def rolled_back(merged_back:)
      merge = release_on_main
      undo = git("commit-tree", "#{before(merge)}^{tree}", "-p", merge, "-m", "Roll back release 2026.10.27")
      git("push", "-q", "origin", "#{undo}:refs/heads/main")
      git("push", "-q", "origin", "#{git("commit-tree", "origin/next^{tree}", "-p", "origin/next", "-p", undo, "-m", "merge-back")}:refs/heads/next") if merged_back
    end

    it "says so, and that merge-back records it in next" do
      rolled_back(merged_back: false)
      run_release("rollback", "2026.10.27")

      expect(@output).to include("v2026.10.27 is already rolled back on main: bin/release merge-back records it in next")
      expect(calls).not_to include("pr create")
    end

    it "says so, and that next has it, once merged back" do
      rolled_back(merged_back: true)
      run_release("rollback")

      expect(@output).to include("v2026.10.27 is already rolled back on main, and next has it.")
    end
  end
end
```

Add one example to `describe "a repository with other names, set in .release_flow.yml"`: after `setup_repo(next_changelog: named)` and `rename_branches`, tag a merge on `trunk` the way `release_on_main` does on `main`, run `rollback 2026.10.27`, and expect `CALL pr create --base trunk --head rollback/2026.10.27`.

- [ ] **Step 2: Run them to see them fail**

Run: `bundle exec rspec spec/release_flow/release_spec.rb -e "rollback"`
Expected: FAIL with `usage: bin/release prepare | cut | …`

- [ ] **Step 3: Implement in `lib/release_flow/release.rb`**

- `USAGE`: add `rollback [<release>]` before `merge-back`. `run`: add `when "rollback" then rollback(*args)`.
- `rollback(name = nil)`, public, after `ship`: `fetch`, then the Design section's rules and messages in the order given there. The rollback commit is `git("commit-tree", "#{before}^{tree}", "-p", head, "-m", …)`; hand it to `propose("rollback/#{name}", at:, base: production, title:, body:, auto_merge: true)`.
- The three private helpers from the Interfaces block.

- [ ] **Step 4: Run the whole suite and the linter**

Run: `bundle exec rspec && bundle exec standardrb`
Expected: all examples pass, no offenses

- [ ] **Step 5: Commit**

```bash
git add lib/release_flow/release.rb spec/release_flow/release_spec.rb
git commit -m "bin/release rollback proposes production as it was before the latest release"
```

---

### Task 2: `bin/release merge-back` records a rollback and keeps the integration branch's work

**Files:**

- Modify: `lib/release_flow/release.rb` (`merge_back_after_hotfix` at lines 113-116, `merge_back` at lines 118-130, a new private method)
- Modify: `spec/release_flow/release_spec.rb` (the fake `gh` near line 95; new examples inside `describe "rollback"`)
- Modify: `README.md`, `CHANGELOG.md`, and `docs/release_map.html` if your checkout has it

**Interfaces:**

- Consumes: `release_at`, `first_parent`, `undone_release` from Task 1.
- Produces: `merge_back(label, after:, at: nil)`, where `at` is the commit to merge back and defaults to `origin/<production>`'s head as now.

- [ ] **Step 1: Let a spec make `gh release edit` fail**

Beside the other `gh_*` lets: `let(:gh_release_edit) { "exit 0" }`. In the fake `gh`'s `case`, before the `*)` line: `"release edit"*) #{gh_release_edit} ;;`

- [ ] **Step 2: Write the failing tests**

Inside `describe "rollback"`, using `release_on_main` and `before` from Task 1:

```ruby
describe "then merge-back" do
  # main gets the rollback PR's merge: main's tree as it was before the release.
  def roll_back(merge, squashed: false)
    undo = git("commit-tree", "#{before(merge)}^{tree}", "-p", merge, "-m", "Roll back release 2026.10.27")
    landed = squashed ? undo : git("commit-tree", "#{undo}^{tree}", "-p", merge, "-p", undo, "-m", "Merge rollback/2026.10.27")
    git("push", "-q", "origin", "#{landed}:refs/heads/main")
    landed
  end

  def parents(ref) = git("rev-list", "--parents", "-n", "1", ref).split.drop(1)

  let(:kept) { "origin/merge-back/rollback-2026.10.27" }

  it "records the rollback in next and keeps next's work, later work included" do
    rollback = roll_back(release_on_main)
    git("reset", "-q", "--hard", "origin/next")
    add_fragment("later.md", "### Added\n\n- Later work.\n")
    run_release("merge-back")

    expect(git("rev-parse", "#{kept}^{tree}")).to eq(git("rev-parse", "origin/next^{tree}"))
    expect(parents(kept)).to eq([git("rev-parse", "origin/next"), rollback])
    expect(calls).to include("CALL pr create --base next --head merge-back/rollback-2026.10.27 --title Merge main back into next after rolling back 2026.10.27")
    expect(calls).to include("CALL pr merge https://github.com/me/app/pull/42 --auto --merge")
    expect(calls).to include("CALL release edit v2026.10.27 --title Release 2026.10.27 (rolled back)")
    expect(@output).to include("  next keeps v2026.10.27's work, which ships again with the next release: land its fix there first")
    expect(@output).not_to include("merge-back again")
  end

  it "recognises a rollback PR that was squashed" do
    rollback = roll_back(release_on_main, squashed: true)
    run_release("merge-back")

    expect(parents(kept).last).to eq(rollback)
  end

  it "merges the release itself back first when next doesn't have it yet" do
    merge = release_on_main(merged_back: false)
    roll_back(merge)
    run_release("merge-back")

    expect(git("rev-parse", "origin/merge-back/2026.10.27")).to eq(merge)
    expect(remote_heads).not_to include("merge-back/rollback-2026.10.27")
    expect(calls).not_to include("release edit")
    expect(@output).to end_with("Then: bin/release merge-back again, once it has merged, to record the rollback of v2026.10.27.\n")
  end

  it "records the rollback alone when more has landed on main since, and says to run again" do
    rollback = roll_back(release_on_main)
    hotfix = git("commit-tree", "#{rollback}^{tree}", "-p", rollback, "-m", "hotfix")
    git("push", "-q", "origin", "#{hotfix}:refs/heads/main")
    run_release("merge-back")

    expect(parents(kept).last).to eq(rollback)
    expect(@output).to end_with("Then: bin/release merge-back again, for what landed on main after the rollback.\n")
  end

  it "changes nothing under --dry-run" do
    roll_back(release_on_main)
    run_release("merge-back", dry_run: true)

    expect(@output).to include("[dry-run] would push merge-back/rollback-2026.10.27, which records the rollback and keeps next as it is")
    expect(remote_heads).not_to include("merge-back/rollback-2026.10.27")
    expect(calls).not_to match(/pr create|release edit/)
  end

  context "when GitHub won't retitle the release" do
    let(:gh_release_edit) { "echo 'release not found' >&2; exit 1" }

    it "says so and still queues the merge-back" do
      roll_back(release_on_main)
      run_release("merge-back")

      expect(@output).to include("  ! couldn't mark v2026.10.27 as rolled back on GitHub: release not found")
      expect(remote_heads).to include("merge-back/rollback-2026.10.27")
    end
  end
end
```

- [ ] **Step 3: Run them to see them fail**

Run: `bundle exec rspec spec/release_flow/release_spec.rb -e "merge-back"`
Expected: the new examples FAIL (an ordinary `merge-back/main-…` branch is pushed instead); the four under "merge-back, after a hotfix" pass

- [ ] **Step 4: Implement in `lib/release_flow/release.rb`**

- `merge_back(label, after:, at: nil)`: the proposed commit is `at || git("rev-parse", "origin/#{production}")`.
- `merge_back_after_hotfix`: after `fetch`, find the oldest commit of `git rev-list --first-parent --reverse origin/<integration>..origin/<production>` for which `undone_release` returns a name. With none, carry on as now. With one, follow the Design section's steps 1 to 4 in a private method of their own; the kept merge is `git("commit-tree", "origin/#{integration}^{tree}", "-p", "origin/#{integration}", "-p", rollback, "-m", …)`, proposed with `auto_merge: true`.
- Put a one-line comment on that method saying why it keeps the integration branch's tree: an ordinary merge would undo the release's work there.

- [ ] **Step 5: Run the whole suite and the linter**

Run: `bundle exec rspec && bundle exec standardrb`
Expected: all examples pass, no offenses

- [ ] **Step 6: Document it**

`README.md`, in the Release section, a new paragraph after **Hotfix.**:

```markdown
**Roll back.** When the release just shipped has to come out of production,
`bin/release rollback` names it and shows where `main` would return to, and
`bin/release rollback <name>` opens the PR that takes `main` back to the
commit before the release, for your production deploy to run. Once it has
merged, run `bin/release merge-back`: it records the rollback in `next` and
keeps the release's work there, so its fix lands on top and both ship with
the next release. A release branch cut in the meantime carries the
rolled-back work, so delete it and cut again after the merge-back. Rolling
back returns the code, not the data: a migration the release ran stays run.
It works on the latest release while nothing else has landed on `main`;
after that, revert by a PR into `main` and run `bin/release merge-back`.
```

`CHANGELOG.md`, under `## [Unreleased]`:

```markdown
- `bin/release rollback <name>` opens the PR that returns the production branch to the commit before the latest release; `bin/release merge-back` then records the rollback in the integration branch and keeps the release's work there, to ship again with its fix.
```

`docs/release_map.html`, if present: the label that reads "something wrong? redeploy an earlier tag. that's your deploy's job; bin/release has no rollback" becomes "something wrong? bin/release rollback returns main to the commit before the release; its work stays on next for the fix".

If `release.rb` has an `await_production_deploy` method (the plan that makes `ship` wait on the production deploy has landed), end its failure message with `, or roll the release back: bin/release rollback` and extend that message's spec to match.

- [ ] **Step 7: Commit**

```bash
git add lib/release_flow/release.rb spec/release_flow/release_spec.rb README.md CHANGELOG.md
git add docs/release_map.html 2>/dev/null || true
git commit -m "bin/release merge-back records a rollback and keeps the integration branch's work"
```
