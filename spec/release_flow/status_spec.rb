# frozen_string_literal: true

RSpec.describe ReleaseFlow::Status do
  let(:head) { "abc1234#{"0" * 33}" }
  let(:main_head) { "def5678#{"0" * 33}" }
  let(:running) { {passed: 14, running: 6, failed: 0, total: 20, failing: []} }
  let(:passed) { {passed: 20, running: 0, failed: 0, total: 20, failing: []} }
  let(:failed) { {passed: 18, running: 0, failed: 2, total: 20, failing: ["test (2)", "lint"]} }
  let(:facts) do
    {repo: "me/app", integration: "next", production: "main", shipped: "2026.10.20",
     integration_head: head, production_head: main_head, merged_back: true,
     waiting: 0, named: nil, ci: passed.merge(ran: true), prs: []}
  end

  def report(**changes) = described_class.report(facts.merge(changes))

  def pr(kind, number, checks, branch:, mergeable: "MERGEABLE")
    {kind: kind, number: number, url: "https://github.com/me/app/pull/#{number}", branch: branch, head: head,
     mergeable: mergeable, checks: checks}
  end

  describe ".tally" do
    it "counts check runs and status contexts by outcome, naming the failures" do
      rollup = [
        {"name" => "test (1)", "status" => "COMPLETED", "conclusion" => "SUCCESS"},
        {"name" => "skipped", "status" => "COMPLETED", "conclusion" => "SKIPPED"},
        {"name" => "test (2)", "status" => "IN_PROGRESS", "conclusion" => ""},
        {"name" => "lint", "status" => "COMPLETED", "conclusion" => "FAILURE"},
        {"context" => "deploy", "state" => "PENDING"},
        {"context" => "audit", "state" => "ERROR"}
      ]

      expect(described_class.tally(rollup)).to eq(passed: 2, running: 2, failed: 2, total: 6, failing: ["lint", "audit"])
    end

    it "reads a workflow run's jobs, which gh reports in lower case" do
      jobs = [{"name" => "a", "status" => "completed", "conclusion" => "success"}, {"name" => "b", "status" => "queued", "conclusion" => ""}]

      expect(described_class.tally(jobs)).to eq(passed: 1, running: 1, failed: 0, total: 2, failing: [])
    end
  end

  it "reads as a quiet repository when nothing waits" do
    expect(report).to eq(<<~TEXT.chomp)
      == Release status in me/app ==
        shipped: v2026.10.20
        heads: main at def5678, next at abc1234; main is in next
        next: no changelog entries waiting
        CI on next at abc1234: passed, jobs 20/20 passed, 0 running, 0 failed
      Nothing to release: no changelog entries on next.
    TEXT
  end

  it "names prepare when entries wait, and says the workflow can run it" do
    expect(report(waiting: 3)).to include("  next: 3 changelog entries wait for a release")
      .and end_with("Next: bin/release prepare (the release workflow runs it when AUTO_RELEASE is on).")
  end

  it "points at merge-back when main isn't in next and nothing is merging it" do
    expect(report(merged_back: false, named: "2026.10.27")).to include("main isn't in next yet")
      .and end_with("Next: bin/release merge-back.")
  end

  describe "a release named on next" do
    it "is ready to cut once CI passed" do
      expect(report(named: "2026.10.27")).to include("  next: v2026.10.27 is named, waiting to be cut")
        .and end_with("Next: bin/release cut (the release workflow runs it when AUTO_RELEASE is on).")
    end

    it "waits on CI still running" do
      expect(report(named: "2026.10.27", ci: running.merge(ran: true)))
        .to include("CI on next at abc1234: running, jobs 14/20 passed, 6 running, 0 failed")
        .and include("Waiting: CI on next at abc1234 is still running.")
        .and end_with("Next: bin/release cut once it passes, or bin/release cut --wait now.")
    end

    it "waits on CI that hasn't started" do
      expect(report(named: "2026.10.27", ci: {passed: 0, running: 0, failed: 0, total: 0, failing: [], ran: false}))
        .to include("CI on next at abc1234: not started")
        .and end_with("Next: bin/release cut once it passes, or bin/release cut --wait now.")
    end

    it "names the failing jobs" do
      expect(report(named: "2026.10.27", ci: failed.merge(ran: true)))
        .to include("CI on next at abc1234: failed, jobs 18/20 passed, 0 running, 2 failed (test (2), lint)")
        .and end_with("Next: re-run the failed jobs if it was a flake, or fix it by a PR into next; then bin/release cut.")
    end
  end

  describe "an open release PR" do
    let(:release) { pr(:release, 42, running, branch: "release/2026.10.27") }

    it "lists it and says ship waits on its checks" do
      expect(report(named: "2026.10.27", prs: [release])).to include(
        "  release PR #42 (release/2026.10.27 at abc1234): https://github.com/me/app/pull/42\n" \
        "    checks 14/20 passed, 6 running, 0 failed; mergeable"
      ).and include("Waiting: release PR #42's checks are still running.")
        .and end_with("Next: bin/release ship 42 abc1234 once checks pass and it's reviewed on staging.")
    end

    it "says the named release is cut, not waiting to be" do
      expect(report(named: "2026.10.27", prs: [release])).to include("  next: v2026.10.27 is cut, on release/2026.10.27")
    end

    it "is ready to ship once its checks pass" do
      expect(report(prs: [release.merge(checks: passed)]))
        .to end_with("Next: review it on staging, then bin/release ship 42 abc1234.")
    end

    it "names failing checks" do
      expect(report(prs: [release.merge(checks: failed)]))
        .to include("Waiting: release PR #42 has failing checks: test (2), lint.")
        .and end_with("Next: re-run the failed jobs if it was a flake, or fix them by a PR into release/2026.10.27; then bin/release status.")
    end

    it "names conflicts" do
      expect(report(prs: [release.merge(mergeable: "CONFLICTING")])).to include("; has conflicts")
        .and end_with("Next: resolve release PR #42's conflicts with main; then bin/release status.")
    end

    it "says when no checks have reported yet" do
      expect(report(prs: [release.merge(checks: {passed: 0, running: 0, failed: 0, total: 0, failing: []}, mergeable: "UNKNOWN")]))
        .to include("    no checks reported yet; mergeability not known yet")
    end
  end

  it "waits on a merge-back PR, which merges itself" do
    merge_back = pr(:merge_back, 43, running, branch: "merge-back/2026.10.27")

    expect(report(merged_back: false, waiting: 2, prs: [merge_back]))
      .to include("  merge-back PR #43 (merge-back/2026.10.27 at abc1234): https://github.com/me/app/pull/43")
      .and include("Waiting: merge-back PR #43 merges itself once its checks pass.")
      .and end_with("Next: nothing until it merges; bin/release status shows when it has.")
  end

  it "waits on a changelog PR, then cut" do
    changelog = pr(:changelog, 44, running, branch: "changelog/2026.10.27")

    expect(report(waiting: 2, prs: [changelog]))
      .to include("Waiting: changelog PR #44 merges itself once its checks pass.")
      .and end_with("Next: bin/release cut once it has merged and CI passes on next, or bin/release cut --wait then.")
  end

  it "puts a release PR before the merge-back and changelog PRs it would block" do
    prs = [pr(:merge_back, 43, running, branch: "merge-back/x"), pr(:release, 42, passed, branch: "release/2026.10.27")]

    expect(report(prs: prs)).to end_with("Next: review it on staging, then bin/release ship 42 abc1234.")
  end

  it "says when nothing has shipped" do
    expect(report(shipped: nil)).to include("  shipped: nothing yet")
  end
end
