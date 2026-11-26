# frozen_string_literal: true

module ReleaseFlow
  # What bin/release status prints: where the release chain stands, from facts Release gathers, and the command that comes next.
  module Status
    PASSED = %w[SUCCESS SKIPPED NEUTRAL].freeze
    RUNNING = %w[PENDING EXPECTED QUEUED IN_PROGRESS WAITING REQUESTED].freeze
    KINDS = {release: "release PR", merge_back: "merge-back PR", changelog: "changelog PR"}.freeze
    MERGEABLE = {"MERGEABLE" => "mergeable", "CONFLICTING" => "has conflicts"}.freeze
    AUTO = " (the release workflow runs it when AUTO_RELEASE is on)"

    module_function

    # items: a PR's statusCheckRollup (check runs and status contexts) or a workflow run's jobs.
    def tally(items)
      counts = {passed: 0, running: 0, failed: 0, total: items.size, failing: []}
      items.each do |item|
        outcome = outcome(item)
        counts[outcome] += 1
        counts[:failing] << (item["name"] || item["context"]) if outcome == :failed
      end
      counts
    end

    def outcome(item)
      result = (item["conclusion"] || item["state"]).to_s.upcase
      status = item["status"].to_s.upcase
      return :running if result.empty? || RUNNING.include?(result) || !["", "COMPLETED"].include?(status)

      PASSED.include?(result) ? :passed : :failed
    end

    def verdict(counts)
      return :failed if counts[:failed].positive?
      return :running if counts[:running].positive? || counts[:total].zero?

      :passed
    end

    def checks(counts)
      return "no checks reported yet" if counts[:total].zero?

      line = "#{counts[:passed]}/#{counts[:total]} passed, #{counts[:running]} running, #{counts[:failed]} failed"
      counts[:failing].any? ? "#{line} (#{counts[:failing].join(", ")})" : line
    end

    def report(facts)
      [*lines(facts), *advice(facts)].join("\n")
    end

    def lines(facts)
      integration, production = facts.values_at(:integration, :production)
      prs = facts[:prs].sort_by { |pr| KINDS.keys.index(pr[:kind]) }
      ["== Release status in #{facts[:repo]} ==",
        "  shipped: #{facts[:shipped] ? "v#{facts[:shipped]}" : "nothing yet"}",
        "  heads: #{production} at #{short(facts[:production_head])}, #{integration} at #{short(facts[:integration_head])}; " +
          (facts[:merged_back] ? "#{production} is in #{integration}" : "#{production} isn't in #{integration} yet"),
        "  #{integration}: #{waiting_line(facts)}",
        "  CI on #{integration} at #{short(facts[:integration_head])}: #{ci_line(facts[:ci])}",
        *prs.flat_map do |pr|
          ["  #{KINDS[pr[:kind]]} ##{pr[:number]} (#{pr[:branch]} at #{short(pr[:head])}): #{pr[:url]}",
            "    #{"checks " if pr[:checks][:total].positive?}#{checks(pr[:checks])}; #{MERGEABLE.fetch(pr[:mergeable], "mergeability not known yet")}"]
        end]
    end

    def waiting_line(facts)
      return "v#{facts[:named]} is named, waiting to be cut" if facts[:named]
      return "no changelog entries waiting" if facts[:waiting].zero?

      (facts[:waiting] == 1) ? "1 changelog entry waits for a release" : "#{facts[:waiting]} changelog entries wait for a release"
    end

    def ci_line(ci)
      return "not started" unless ci[:ran]

      "#{verdict(ci)}, jobs #{checks(ci)}"
    end

    # The first open PR in KINDS order decides, since a release under way blocks the next one.
    def advice(facts)
      pr = facts[:prs].min_by { |p| KINDS.keys.index(p[:kind]) }
      waiting, next_step = pr ? pr_advice(pr, facts) : branch_advice(facts)
      [("Waiting: #{waiting}." if waiting), next_step].compact
    end

    def pr_advice(pr, facts)
      label = "#{KINDS[pr[:kind]]} ##{pr[:number]}"
      base = (pr[:kind] == :release) ? facts[:production] : facts[:integration]
      checks = pr[:checks]
      return [nil, "Next: resolve #{label}'s conflicts with #{base}; then bin/release status."] if pr[:mergeable] == "CONFLICTING"
      if verdict(checks) == :failed
        return ["#{label} has failing checks: #{checks[:failing].join(", ")}",
          "Next: re-run the failed jobs if it was a flake, or fix them by a PR into #{pr[:branch]}; then bin/release status."]
      end

      case pr[:kind]
      when :release
        ship = "bin/release ship #{pr[:number]} #{short(pr[:head])}"
        return [nil, "Next: review it on staging, then #{ship}."] if verdict(checks) == :passed

        ["#{label}'s checks are still running", "Next: #{ship} once checks pass and it's reviewed on staging."]
      when :merge_back
        ["#{label} merges itself once its checks pass", "Next: nothing until it merges; bin/release status shows when it has."]
      else
        ["#{label} merges itself once its checks pass",
          "Next: bin/release cut once it has merged and CI passes on #{facts[:integration]}, or bin/release cut --wait then."]
      end
    end

    def branch_advice(facts)
      integration = facts[:integration]
      return [nil, "Next: bin/release merge-back."] unless facts[:merged_back]
      return named_advice(facts) if facts[:named]
      return [nil, "Next: bin/release prepare#{AUTO}."] if facts[:waiting].positive?

      [nil, "Nothing to release: no changelog entries on #{integration}."]
    end

    def named_advice(facts)
      ci = facts[:ci]
      at = "#{facts[:integration]} at #{short(facts[:integration_head])}"
      case (ci[:ran] ? verdict(ci) : :running)
      when :passed then [nil, "Next: bin/release cut#{AUTO}."]
      when :failed
        ["CI failed on #{at}",
          "Next: re-run the failed jobs if it was a flake, or fix it by a PR into #{facts[:integration]}; then bin/release cut."]
      else ["CI on #{at} is still running", "Next: bin/release cut once it passes, or bin/release cut --wait now."]
      end
    end

    def short(sha) = sha.to_s[0, 7]
  end
end
