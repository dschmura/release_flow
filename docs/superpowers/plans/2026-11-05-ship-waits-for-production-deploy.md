# `bin/release ship` Waits for the Production Deploy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After `bin/release ship` has merged, published and queued the merge-back, it waits for the production deploy of the merge commit and fails, with the run's URL, if that deploy doesn't succeed.

**Architecture:** One new private method in `Release`, `await_production_deploy(commit, name)`, called as the last step of `ship`. It polls `gh run list` for the production workflow's run on the merge commit, the same way `require_passing_ci` reads CI. A new `production_workflow` setting names the workflow and falls back to `staging_workflow`; `--no-wait` skips the wait.

**Tech Stack:** Ruby 3.3 standard library, `git`, the GitHub CLI (`gh`), RSpec, StandardRB.

**Spec:** none. The Design section below is the spec.

## Design

**The wait comes last and decides nothing about the release.** `ship` keeps its order: merge the PR, publish `v<name>`, queue the merge-back. Only then does it watch the deploy. The release is fully shipped before the wait starts, so stopping the wait (Ctrl-C, a timeout) loses nothing, and a failed deploy leaves nothing for `ship` to finish on a re-run. The failure is a verdict: a non-zero exit and what to do.

**What it asks GitHub:** `gh run list --workflow <production_workflow> --commit <merge commit> --event push --json status,conclusion,url`, with `status: true` so a `gh` failure is an answer, not an exception.

**What each answer means**, looking every `DEPLOY_POLL` seconds:

| Answer | What `ship` does |
| --- | --- |
| `gh` fails (no such workflow) | says `  ! couldn't read <workflow>'s runs: check production yourself` and returns, at once |
| no run yet | looks again; after `DEPLOY_APPEARS` looks with none, says `  ! no <workflow> run found for <sha7>: check production yourself` and returns |
| runs, not all `completed` | looks again; after `DEPLOY_FINISHES` looks in all, says `  ! <workflow> is still deploying <sha7>: <url>` and returns |
| all `completed`, all `success` | says `  ✓ <workflow> deployed <sha7> to production` and returns |
| all `completed`, any other conclusion | raises `Error` (below) |
| Ctrl-C | says `  stopped waiting; the deploy carries on` and returns |

Only a deploy that finished without succeeding fails `ship`. Not finding out is said plainly but isn't a failure, since many repositories deploy production outside GitHub Actions.

Before the first look it says: `  waiting for <workflow> to deploy <sha7> to production; Ctrl-C stops the wait, not the deploy`

The error, where `<conclusion>` is the first conclusion that isn't `success` and `<url>` is that run's:

```text
<workflow>'s deploy of <sha7> to production ended in <conclusion>: <url>
v<name> is merged and published, so <production> is ahead of what production runs. If it was a flake, re-run its failed jobs; otherwise fix it by a PR into <production>, then run bin/release merge-back
```

**Settings.** `production_workflow` defaults to `nil`, meaning "the same file as `staging_workflow`": the README's setup is one workflow that deploys `release/**` to staging and `main` to production, so a repository that renames it sets one name, not two.

**Timing.** `DEPLOY_POLL = 10` seconds, `DEPLOY_APPEARS = 6` looks (a minute for the run to show up), `DEPLOY_FINISHES = 180` looks (half an hour). The seconds are read as `@opts.fetch(:deploy_poll) { DEPLOY_POLL }`, the way `prepare` reads `@opts.fetch(:today)`, so the specs pass `0`.

## Global Constraints

- No new dependencies: Ruby's standard library, `git` and `gh` only.
- `ship`'s existing steps and their order don't change; every existing `ship` example still passes unedited apart from the shared helpers below.
- Workflow and branch names come from `@config`, never literals.
- An unknown setting still stops `bin/release` with the list of those it knows; the new setting joins that list by being a `DEFAULTS` key.
- Match the surrounding code: terse methods, sparse comments, messages that say what to do next.
- `bundle exec rspec` and `bundle exec standardrb` both pass before each commit.
- Commit subjects are a plain sentence naming what changed for a user, as in `git log`.
- Two other plans may land around this one (`bin/release status` and `bin/release rollback`). They also edit `release.rb`, the fake `gh` in `release_spec.rb`, `README.md` and `CHANGELOG.md`. Keep edits there small so they merge cleanly.

## Review Focus

- **Production isn't deployed by a GitHub workflow, or the file is named otherwise:** `ship` says it couldn't read the runs and returns at once, without a minute of polling. Test in Task 2.
- **A deploy that waits hours on an environment approval:** `ship` gives up after `DEPLOY_FINISHES` looks, says where the run is, and exits 0. Test in Task 2.
- **Ctrl-C during the wait:** a line saying the deploy carries on, not a backtrace. Test in Task 2.
- **A deploy that was skipped or cancelled:** fails like a failed one, naming the conclusion. Test in Task 2.
- **The run appears only after a few looks:** `ship` keeps looking, then reports it. Test in Task 2.

---

### Task 1: The `production_workflow` setting and the `--[no-]wait` option

**Files:**

- Modify: `lib/release_flow/config.rb:7-8` (`DEFAULTS`)
- Modify: `lib/release_flow/cli.rb:15-17` (options)
- Test: `spec/release_flow/config_spec.rb`, `spec/release_flow/cli_spec.rb`

**Interfaces:**

- Produces: `Config#production_workflow` (`nil` unless set); `options[:wait]` (`true`, `false`, or absent) passed to `Release.new`.

- [ ] **Step 1: Write the failing tests**

In `config_spec.rb`, add `production_workflow: nil` to the defaults example's `have_attributes`, and add:

```ruby
it "takes a production workflow of its own" do
  root.join(".release_flow.yml").write("production_workflow: production.yml\n")

  expect(described_class.load(root.to_s)).to have_attributes(production_workflow: "production.yml", staging_workflow: "deploy.yml")
end
```

In `cli_spec.rb`:

```ruby
it "passes --no-wait on, for a ship that returns once it has shipped" do
  release = instance_double(ReleaseFlow::Release, run: nil)
  allow(ReleaseFlow::Release).to receive(:new).and_return(release)

  described_class.start(["ship", "--no-wait"], root: root.to_s)

  expect(ReleaseFlow::Release).to have_received(:new).with(hash_including(wait: false), anything)
end
```

- [ ] **Step 2: Run them to see them fail**

Run: `bundle exec rspec spec/release_flow/config_spec.rb spec/release_flow/cli_spec.rb`
Expected: FAIL, `production_workflow` unknown and `invalid option: --no-wait`

- [ ] **Step 3: Implement**

- `config.rb`: add `production_workflow: nil` to `DEFAULTS`, after `staging_workflow`.
- `cli.rb`: `o.on("--[no-]wait", "ship: wait for the production deploy and fail if it does (the default)") { |wait| options[:wait] = wait }`.

- [ ] **Step 4: Run the tests and the linter**

Run: `bundle exec rspec spec/release_flow/config_spec.rb spec/release_flow/cli_spec.rb && bundle exec standardrb`
Expected: all examples pass, no offenses

- [ ] **Step 5: Commit**

```bash
git add lib/release_flow/config.rb lib/release_flow/cli.rb spec/release_flow/config_spec.rb spec/release_flow/cli_spec.rb
git commit -m "production_workflow names the deploy ship will wait for, and --no-wait skips it"
```

---

### Task 2: `ship` waits for the deploy and fails if it does

**Files:**

- Modify: `lib/release_flow/release.rb` (constants near line 20, the end of `ship` at lines 109-110, a new private method after `require_passing_ci`)
- Modify: `spec/release_flow/release_spec.rb` (shared helpers at lines 14-16, 96 and 116; new examples in `describe "ship"` and in the `.release_flow.yml` describe)
- Modify: `README.md`, `CHANGELOG.md`, `templates/.github/PULL_REQUEST_TEMPLATE/release.md.erb:18`

**Interfaces:**

- Consumes: `@config.production_workflow` and `@opts[:wait]` from Task 1.
- Produces: `Release#await_production_deploy(commit, name)` (private); constants `Release::DEPLOY_POLL`, `DEPLOY_APPEARS`, `DEPLOY_FINISHES`.

- [ ] **Step 1: Teach the spec helpers about the production deploy**

These three edits keep the existing `ship` examples fast and passing once the wait exists:

- Beside the other `gh_*` lets: `let(:gh_production) { %q(echo '[{"status":"completed","conclusion":"success","url":"https://github.com/me/app/actions/runs/7"}]') }`
- In the fake `gh`'s `case`, on the line before `"run list --workflow deploy.yml"*`: `"run list --workflow deploy.yml --commit"*) #{gh_production} ;;`
- In `run_release`: `described_class.new({today: today, deploy_poll: 0}.merge(opts), root: clone.to_s)`

- [ ] **Step 2: Write the failing tests**

In `describe "ship"`, where `main_sha` is the merge commit the fake reports:

```ruby
describe "waiting for production's deploy of the merge" do
  let(:short) { main_sha[0, 7] }
  let(:running) { %q(echo '[{"status":"in_progress","conclusion":"","url":"https://github.com/me/app/actions/runs/7"}]') }

  def looks = calls.scan("CALL run list --workflow deploy.yml --commit #{main_sha} --event push").size

  it "says when the deploy has run" do
    run_release("ship", "42", "abc1234")

    expect(@output).to include("  waiting for deploy.yml to deploy #{short} to production; Ctrl-C stops the wait, not the deploy")
    expect(@output).to include("  ✓ deploy.yml deployed #{short} to production")
    expect(looks).to eq(1)
  end

  context "when the deploy fails" do
    let(:gh_production) { %q(echo '[{"status":"completed","conclusion":"failure","url":"https://github.com/me/app/actions/runs/7"}]') }

    it "fails with the run and what to do, having shipped everything first" do
      expect { run_release("ship", "42", "abc1234") }.to raise_error(ReleaseFlow::Release::Error,
        %r{deploy\.yml's deploy of #{short} to production ended in failure: https://github\.com/me/app/actions/runs/7\n.*re-run its failed jobs.*bin/release merge-back}m)
      expect(calls).to include("CALL release create v2026.10.27")
      expect(remote_heads).to include("merge-back/2026.10.27")
    end
  end

  context "when the deploy was skipped" do
    let(:gh_production) { %q(echo '[{"status":"completed","conclusion":"skipped","url":"https://github.com/me/app/actions/runs/7"}]') }

    it "fails, since a skipped deploy put nothing in production" do
      expect { run_release("ship", "42", "abc1234") }.to raise_error(ReleaseFlow::Release::Error, /ended in skipped/)
    end
  end

  context "when the deploy starts after a look or two" do
    let(:gh_production) do
      %(if [ -f "#{bin}/looked" ]; then echo '[{"status":"completed","conclusion":"success","url":"u"}]'; else touch "#{bin}/looked"; echo '[]'; fi)
    end

    it "keeps looking until it has run" do
      run_release("ship", "42", "abc1234")

      expect(@output).to include("✓ deploy.yml deployed #{short} to production")
      expect(looks).to eq(2)
    end
  end

  context "when no deploy starts" do
    let(:gh_production) { "echo '[]'" }

    it "says so after a minute's looks, without failing" do
      run_release("ship", "42", "abc1234")

      expect(@output).to include("  ! no deploy.yml run found for #{short}: check production yourself")
      expect(looks).to eq(ReleaseFlow::Release::DEPLOY_APPEARS)
    end
  end

  context "when gh can't read the workflow's runs" do
    let(:gh_production) { "echo 'could not find any workflows named deploy.yml' >&2; exit 1" }

    it "says so at once, without failing" do
      run_release("ship", "42", "abc1234")

      expect(@output).to include("  ! couldn't read deploy.yml's runs: check production yourself")
      expect(looks).to eq(1)
    end
  end

  context "when the deploy is still running at the last look" do
    let(:gh_production) { running }

    it "says where the run is, without failing" do
      stub_const("ReleaseFlow::Release::DEPLOY_FINISHES", 3)
      run_release("ship", "42", "abc1234")

      expect(@output).to include("  ! deploy.yml is still deploying #{short}: https://github.com/me/app/actions/runs/7")
      expect(looks).to eq(3)
    end

    it "stops on Ctrl-C with a line, not a backtrace" do
      allow_any_instance_of(described_class).to receive(:sleep).and_raise(Interrupt)
      run_release("ship", "42", "abc1234")

      expect(@output).to include("  stopped waiting; the deploy carries on")
    end
  end

  it "doesn't look under --no-wait" do
    run_release("ship", "42", "abc1234", wait: false)

    expect(looks).to eq(0)
    expect(calls).to include("CALL release create v2026.10.27")
  end
end
```

In `describe "a repository with other names, set in .release_flow.yml"`, inside `context "when a release waits to ship"`:

```ruby
def ship_into_trunk
  release_pr = {"headRefName" => "release/2026.10.27", "baseRefName" => "trunk", "headRefOid" => head}
  install_fake_gh(release_pr: release_pr)
  mark_merged(release_pr, git("rev-parse", "origin/trunk"))
  run_release("ship", "42", "abc1234")
end

it "waits on the staging workflow's file when no production workflow is named" do
  setup_repo(next_changelog: named)
  rename_branches
  ship_into_trunk

  expect(calls).to include("CALL run list --workflow staging.yml --commit")
end

it "waits on the production workflow it names" do
  setup_repo(next_changelog: named)
  rename_branches
  clone.join(".release_flow.yml").write(clone.join(".release_flow.yml").read + "production_workflow: production.yml\n")
  ship_into_trunk

  expect(calls).to include("CALL run list --workflow production.yml --commit")
end
```

- [ ] **Step 3: Run them to see them fail**

Run: `bundle exec rspec spec/release_flow/release_spec.rb -e "ship" -e "other names"`
Expected: the new examples FAIL (no wait line in the output, no `run list … --commit` call); the existing ones pass

- [ ] **Step 4: Implement in `lib/release_flow/release.rb`**

- Constants beside `BODY_LIMIT`: `DEPLOY_POLL = 10`, `DEPLOY_APPEARS = 6`, `DEPLOY_FINISHES = 180`.
- End of `ship`: keep `publish` and `merge_back` as they are, then `await_production_deploy(info.dig("mergeCommit", "oid"), name) if @opts.fetch(:wait, true)`.
- `await_production_deploy(commit, name)`, private, after `require_passing_ci`: the workflow is `@config.production_workflow || @config.staging_workflow`; the rest is the Design section's table and messages, exactly. Rescue `Interrupt` inside the method only.

- [ ] **Step 5: Run the whole suite and the linter**

Run: `bundle exec rspec && bundle exec standardrb`
Expected: all examples pass, no offenses

- [ ] **Step 6: Document it**

`README.md`:

- Settings block, after the `staging_workflow` line: `production_workflow: production.yml # default: staging_workflow's file; ship waits for its deploy of the merge`
- Install step 4, replace its second sentence with: "`ship` reads your staging workflow's runs to find the commit staging ran, and your production workflow's to see the release arrive."
- The **Ship.** paragraph, append: "Once it has shipped, it waits for the production deploy of the merge and fails if that deploy does, so a release that never reached production can't pass unnoticed. `--no-wait` returns as soon as it has shipped."

`templates/.github/PULL_REQUEST_TEMPLATE/release.md.erb`, line 18: change the end of the sentence from "then publishes the release and merges `…` back into `…`:" to "then publishes the release, merges `<%= config.production_branch %>` back into `<%= config.integration_branch %>`, and waits for the production deploy:".

`CHANGELOG.md`, under `## [Unreleased]`:

```markdown
- `bin/release ship` waits for the production deploy of the merge and fails if that deploy does; `--no-wait` returns once it has shipped. `production_workflow` names the workflow when it isn't `staging_workflow`'s.
```

- [ ] **Step 7: Run the suite once more and commit**

Run: `bundle exec rspec && bundle exec standardrb`
Expected: all examples pass, no offenses (the installer specs render the template)

```bash
git add lib/release_flow/release.rb spec/release_flow/release_spec.rb README.md CHANGELOG.md templates/.github/PULL_REQUEST_TEMPLATE/release.md.erb
git commit -m "bin/release ship waits for the production deploy and fails if it does"
```
