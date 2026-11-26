# frozen_string_literal: true

require "date"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

# Walks a release from the integration branch to production. Commits through a temporary index,
# so the checkout and working tree are never touched.
module ReleaseFlow
  class Release
    class Error < ReleaseFlow::Error; end
    class Stopped < Error; end

    CLEAN_GIT_ENV = GitEnv::HASH
    TEMPLATE = ".github/PULL_REQUEST_TEMPLATE/release.md"
    SHIP_USAGE = "bin/release ship [<PR> <commit reviewed on staging>]"
    USAGE = "usage: bin/release prepare | cut | #{SHIP_USAGE.delete_prefix("bin/release ")} | merge-back | check | status"
    ONCE_READY = "once its checks pass and any required approval is given"
    BODY_LIMIT = 60_000
    INTERVAL = 20
    TIMEOUT = 45 * 60

    def initialize(options, root: Dir.pwd, config: nil)
      @opts = options
      @root = File.expand_path(root)
      @config = config || Config.load(@root)
    end

    def run(command, *args)
      @repo = GithubOrigin.repo(@root) or raise Error, "origin isn't a GitHub repository, so there's no telling which one to act on"
      case command
      when "status" then status
      when "prepare" then prepare
      when "cut" then cut
      when "ship" then ship(*args)
      when "merge-back" then merge_back_after_hotfix
      when "check" then check
      else raise Error, USAGE
      end
    end

    def status
      fetch
      changelog = next_changelog
      named = Changelog.named_release(changelog)
      head = git("rev-parse", "origin/#{integration}")
      say(Status.report(
        repo: @repo, integration: integration, production: production, shipped: latest_shipped,
        integration_head: head, production_head: git("rev-parse", "origin/#{production}"),
        merged_back: ancestor?("origin/#{production}", "origin/#{integration}"),
        waiting: Changelog.unreleased(changelog, fragments_at("origin/#{integration}").values).size,
        named: (named unless shipped?(named)), ci: ci_progress(head), prs: open_flow_prs
      ))
    end

    def prepare
      fetch
      changelog = next_changelog
      fragments = fragments_at("origin/#{integration}")
      if (under_way = release_under_way(changelog))
        return notice("#{under_way}, so the next release waits for it.", title: "The next release waits") if @opts[:if_needed]

        raise Error, "#{under_way}: finish that release before starting another"
      end
      return say("No changelog entries are waiting on #{integration}, so no release to start.") if @opts[:if_needed] && Changelog.unreleased(changelog, fragments.values).empty?

      name = Changelog.names(@opts.fetch(:today) { Date.today })
        .find { |n| !tagged?(n) && !template_tags.key?(n) && !branch?("release/#{n}") }
      say("== Prepare v#{name} in #{@repo} ==")
      return dry("push changelog/#{name} (CHANGELOG.md naming v#{name}) and queue its PR into #{integration}") if dry_run?

      named = Changelog.name_release(changelog + "\n", name, fragments.values)
      commit = commit_on("origin/#{integration}", {"CHANGELOG.md" => named, **fragments.transform_values { nil }},
        message: "The changelog names release #{name}")
      url = propose("changelog/#{name}", at: commit, base: integration, title: "Changelog for release #{name}",
        body: "Gathers `changelog.d/` and `[Unreleased]` into v#{name} so `bin/release cut` can cut it.\n", auto_merge: true)
      say("  → #{url}, merging into #{integration} #{ONCE_READY}")
      return say("Then: bin/release cut, once it has merged.") unless waiting?

      follow_pr(url, "changelog PR", until_merged: true)
      say("Next: bin/release cut --wait.")
    end

    def cut
      fetch
      changelog = next_changelog
      name = Changelog.named_release(changelog)
      return say("Nothing to cut: #{integration} names no release waiting to be cut.") if @opts[:if_needed] && !waiting_to_cut?(name)
      raise Error, "#{integration}'s CHANGELOG.md names no release yet: run bin/release prepare and let its PR merge" unless name
      raise Error, "v#{name} already shipped: run bin/release prepare for the next one" if shipped?(name)

      branch = "release/#{name}"
      open = remote_refs.find { |ref| ref.start_with?("refs/heads/release/") && ref != "refs/heads/#{branch}" }
      raise Error, "#{open.delete_prefix("refs/heads/")} is still open: ship it or delete it before cutting another" if open
      commit, waiting = cut_point(name)
      raise Error, "#{production} isn't in #{integration} yet: #{production_catch_up}" unless ancestor?("origin/#{production}", commit)
      follow_ci(commit) if waiting?
      unless ci_passed?(commit, name)
        return notice("CI hasn't finished on #{commit[0, 7]} yet; the cut runs again when it does.", title: "The release cut waits for CI")
      end

      say("== Cut #{branch} in #{@repo} ==")
      say("  at #{commit[0, 7]}; #{waiting} later commit#{"s" unless waiting == 1} on next wait#{"s" if waiting == 1} for the next release") if waiting.positive?
      return dry("push #{branch} at #{commit[0, 7]} and open its PR into #{production}") if dry_run?

      url = propose(branch, at: commit, base: production, title: "Release #{name}",
        body: release_body(branch, Changelog.section(git("show", "#{commit}:CHANGELOG.md"), name)))
      say("  → #{url}")
      return say("Then: review it on staging, and run bin/release ship.") unless waiting?

      follow_pr(url, "release PR", until_merged: false)
      say("Next: review it on staging, then bin/release ship #{url.split("/").last} #{commit[0, 7]}.")
    end

    def ship(pr = nil, sha = nil)
      raise Error, "usage: #{SHIP_USAGE}" if pr.nil? != sha.nil? || (sha && !sha.match?(/\A\h{7,40}\z/))

      pr, sha, found = waiting_release unless pr
      info = pr_info(pr)
      name = release_name(info)
      head = info["headRefOid"]
      say("== Ship v#{name} in #{@repo} ==")
      say("  PR ##{pr}, #{info["headRefName"]} into #{production}, at #{head[0, 7]}: #{found}") if found
      return dry("merge PR #{pr} at #{head[0, 7]}, publish release v#{name}, and queue the merge-back into #{integration}") if dry_run?
      return say("Not shipped.") if found && !Candidate.confirmed?(pr, head)
      raise Error, "PR #{pr} #{(info["state"] == "MERGED") ? "was merged" : "is"} at #{head[0, 7]}, not #{sha}, the commit reviewed on staging" unless head.start_with?(sha)

      if info["state"] == "MERGED"
        say("  ✓ PR #{pr} already merged")
      else
        gh("pr", "merge", pr, "--merge", "--match-head-commit", head)
        info = pr_info(pr)
      end
      publish(name, info.dig("mergeCommit", "oid"))
      merge_back(name, after: "release #{name}")
    end

    def merge_back_after_hotfix
      fetch
      merge_back("#{production}-#{git("rev-parse", "--short=7", "origin/#{production}")}", after: "a hotfix")
    end

    def merge_back(label, after:)
      fetch
      branch = "merge-back/#{label}"
      say("== Merge #{production} back into #{integration} in #{@repo} ==")
      return dry("push #{branch} at #{production} and queue its PR into #{integration}") if dry_run?

      url = propose(branch, at: git("rev-parse", "origin/#{production}"), base: integration, title: "Merge #{production} back into #{integration} after #{after}",
        body: "Brings `#{production}` back into `#{integration}` after #{after}. Merge with a merge commit.\n", auto_merge: true)
      out, updated = gh("api", "-X", "PUT", "repos/{owner}/{repo}/pulls/#{url.split("/").last}/update-branch", status: true)
      already_current = out.include?("no new commits on the base branch")
      say("  ! GitHub couldn't bring #{url} up to date; press Update branch on it") unless updated || already_current
      say("  → #{url}, merging into #{integration} #{ONCE_READY}")
      return unless waiting?

      follow_pr(url, "merge-back PR", until_merged: true)
      say("Done: #{production} is back in #{integration}.")
    end

    private

    def check
      tagged = git("tag", "--list", "v*").lines(chomp: true).filter_map { |tag| tag[/\Av(#{Changelog::NAME})\z/o, 1] }
      changed = Changelog.changed_releases(git("show", "HEAD:CHANGELOG.md"), tagged.to_h { |name| [name, git("show", "v#{name}:CHANGELOG.md")] })
      raise Error, changed.join("\n\n") if changed.any?

      say("Shipped release notes are unchanged.")
    end

    def dry_run? = @opts[:dry_run]
    def waiting? = @opts[:wait] && !dry_run?
    def say(msg) = puts(msg)
    def dry(msg) = say("  [dry-run] would #{msg}")
    def next_changelog = git("show", "origin/#{integration}:CHANGELOG.md")
    def integration = @config.integration_branch
    def production = @config.production_branch

    # A wait nobody reads in a workflow log goes unseen, so Actions also shows it on the run and its summary.
    def notice(msg, title:)
      say(msg)
      return unless ENV["GITHUB_ACTIONS"] == "true"

      say("::notice title=#{title}::#{msg.gsub("%", "%25").gsub("\r", "%0D").gsub("\n", "%0A")}")
      File.write(ENV["GITHUB_STEP_SUMMARY"], "#{msg}\n", mode: "a") if ENV["GITHUB_STEP_SUMMARY"]
    end

    def fragments_at(commit)
      git("ls-tree", "--name-only", commit, "#{Changelog::FRAGMENTS}/").lines(chomp: true)
        .select { |path| Changelog.fragment?(path) }.to_h { |path| [path, git("show", "#{commit}:#{path}")] }
    end

    def tagged?(name) = remote_refs.include?("refs/tags/v#{name}")
    def branch?(name) = remote_refs.include?("refs/heads/#{name}")
    def remote_refs = @remote_refs ||= git("ls-remote", "--heads", "--tags", "origin").lines.map { |l| l.split.last }

    # A fork's changelog carries the template's releases, which only the template tagged.
    def shipped?(name) = tagged?(name) || template_tags[name]&.then { |commit| ancestor?(commit, "origin/#{integration}") }

    def template_tags
      @template_tags ||= if (template = template_repo)
        out, err, status = Open3.capture3(CLEAN_GIT_ENV, "git", "-C", @root, "ls-remote", "--tags", "https://github.com/#{template}.git")
        raise Error, "can't read the tags of #{template}, the template this repository forks: #{err.strip}" unless status.success?

        out.lines.to_h { |line| line.split.reverse }.transform_keys { |ref| ref[%r{\Arefs/tags/v(.+?)(?:\^\{\})?\z}, 1] }
      else
        {}
      end
    end

    def template_repo = @config.template
    def pr_info(pr) = JSON.parse(gh("pr", "view", pr, "--json", "state,headRefName,headRefOid,baseRefName,mergeCommit"))

    # Polls until the block says :done, printing a line only when the stage it reports changes.
    def watch(subject)
      clock = @opts.fetch(:clock) { -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) } }
      timeout = @opts.fetch(:timeout, TIMEOUT)
      started = clock.call
      last = nil
      loop do
        stage, line, verdict = yield
        elapsed = (clock.call - started).to_i
        say(format("  [%dm%02ds] %s: %s", elapsed / 60, elapsed % 60, subject, line)) unless stage == last
        $stdout.flush
        last = stage
        return if verdict == :done
        raise Error, "#{subject}: #{line}" if verdict == :failed
        raise Error, "stopped waiting on #{subject} after #{timeout / 60} min; nothing was changed. bin/release status shows where it stands" if elapsed >= timeout

        @opts.fetch(:sleeper) { method(:sleep) }.call(@opts.fetch(:interval, INTERVAL))
      end
    rescue Interrupt
      raise Stopped, "stopped watching #{subject}; nothing was changed. bin/release status shows where it stands"
    end

    def follow_pr(url, label, until_merged:)
      watch("#{label} ##{url.split("/").last}") do
        pr = JSON.parse(gh("pr", "view", url, "--json", "state,mergeable,statusCheckRollup"))
        checks = Status.tally(pr["statusCheckRollup"] || [])
        verdict = Status.verdict(checks)
        if pr["state"] == "MERGED" then [:merged, "merged", :done]
        elsif pr["state"] == "CLOSED" then [:closed, "closed without merging", :failed]
        elsif verdict == :failed then [:failed, "checks failed, #{Status.checks(checks)}", :failed]
        elsif pr["mergeable"] == "CONFLICTING" then [:conflicts, "has conflicts with its base", :failed]
        elsif verdict == :passed && until_merged then [:passed, "all #{checks[:total]} checks passed; waiting for it to merge"]
        elsif verdict == :passed then [:passed, "all #{checks[:total]} checks passed", :done]
        elsif checks[:total].zero? then [:none, "no checks reported yet"]
        else [:running, "checks running, #{Status.checks(checks)}"]
        end
      end
    end

    # Waits for every CI run on the commit to finish; ci_passed? then judges them.
    def follow_ci(commit)
      watch("CI on #{integration} at #{commit[0, 7]}") do
        ci = ci_progress(commit)
        require_ci_on_integration unless ci[:ran]
        if ci[:finished] then [:finished, "finished", :done]
        elsif ci[:ran] then [:running, "running, jobs #{Status.checks(ci)}"]
        else [:none, "not started"]
        end
      end
    end

    def latest_shipped
      git("tag", "--merged", "origin/#{production}", "--sort=-creatordate", "--list", "v*").lines(chomp: true)
        .filter_map { |tag| tag[/\Av(#{Changelog::NAME})\z/o, 1] }.first
    end

    def ci_progress(commit)
      runs = JSON.parse(gh("run", "list", "--workflow", @config.ci_workflow, "--commit", commit, "--event", "push", "--json", "databaseId,status,conclusion"))
      return {passed: 0, running: 0, failed: 0, total: 0, failing: [], ran: false} if runs.empty?

      jobs = JSON.parse(gh("run", "view", runs.first["databaseId"].to_s, "--json", "jobs"))["jobs"]
      Status.tally(jobs).merge(ran: true, finished: runs.all? { |run| run["status"] == "completed" })
    end

    # One call for every open PR, kept to the branches the flow opens.
    def open_flow_prs
      prs = JSON.parse(gh("pr", "list", "--state", "open", "--limit", "100", "--json",
        "number,url,headRefName,headRefOid,baseRefName,mergeable,statusCheckRollup"))
      prs.filter_map do |pr|
        kind = flow_kind(pr["headRefName"], pr["baseRefName"]) or next
        {kind: kind, number: pr["number"], url: pr["url"], branch: pr["headRefName"], head: pr["headRefOid"],
         mergeable: pr["mergeable"], checks: Status.tally(pr["statusCheckRollup"] || [])}
      end
    end

    def flow_kind(branch, base)
      return :release if base == production && branch.match?(Candidate::BRANCH)
      return unless base == integration

      {"merge-back/" => :merge_back, "changelog/" => :changelog}.find { |prefix, _| branch.start_with?(prefix) }&.last
    end

    def release_under_way(changelog)
      named = Changelog.named_release(changelog)
      return "v#{named} is named but hasn't shipped" if named && !shipped?(named)

      changelog_branch = remote_refs.find { |ref| ref.start_with?("refs/heads/changelog/") }
      "#{changelog_branch.delete_prefix("refs/heads/")} hasn't merged" if changelog_branch
    end

    def waiting_to_cut?(name) = name && !shipped?(name) && !branch?("release/#{name}")

    def production_catch_up
      return "merge the open merge-back PR first" if remote_refs.any? { |ref| ref.start_with?("refs/heads/merge-back/") }

      merged = JSON.parse(gh("pr", "list", "--base", production, "--state", "merged", "--limit", "30", "--json", "number,headRefName,headRefOid"))
      unshipped = merged.find { |pr| (name = pr["headRefName"][Candidate::BRANCH, 1]) && !shipped?(name) }
      return "run bin/release merge-back" unless unshipped

      "release #{unshipped["headRefName"][Candidate::BRANCH, 1]} merged without being shipped: " \
        "run bin/release ship #{unshipped["number"]} #{unshipped["headRefOid"][0, 7]} to publish it and merge #{production} back"
    end

    # Under --if-needed a CI run still going is a wait, not a failure: its completion runs cut again.
    def ci_passed?(commit, name)
      runs = JSON.parse(gh("run", "list", "--workflow", @config.ci_workflow, "--commit", commit, "--event", "push", "--json", "status,conclusion"))
      unless runs.any? && runs.all? { |run| run["status"] == "completed" }
        require_ci_on_integration if runs.empty?
        return false if @opts[:if_needed]

        raise Error, "CI hasn't passed on #{commit[0, 7]} yet: run cut again once it has"
      end
      return true if runs.all? { |run| run["conclusion"] == "success" }

      raise Error, "CI failed on #{commit[0, 7]}, where v#{name} would be cut. If it was a flake, re-run its failed jobs; otherwise " \
                   "fix it by a PR into #{integration}, its changelog line under ## v#{name}. Then cut again (AUTO_RELEASE does once CI passes)"
    end

    # A workflow that never ran on the integration branch is misnamed, not slow, so waiting on it would never end.
    def require_ci_on_integration
      ran = JSON.parse(gh("run", "list", "--workflow", @config.ci_workflow, "--branch", integration, "--event", "push", "--limit", "1", "--json", "databaseId"))
      return if ran.any?

      raise Error, "#{@config.ci_workflow} has never run on #{integration}, so there's no CI for cut to wait on: " \
                   "set ci_workflow in #{FILE} to the workflow that runs your checks on pushes to #{integration}"
    end

    def fetch
      @remote_refs = nil
      git("fetch", "-q", "--prune", "--tags", "origin")
    end

    def cut_point(name)
      since_named = []
      git("rev-list", "--first-parent", "origin/#{integration}").each_line(chomp: true) do |commit|
        changelog = git("show", "#{commit}:CHANGELOG.md")
        break unless Changelog.named_release(changelog) == name

        since_named << [commit, Changelog.unreleased(changelog, fragments_at(commit).values)]
      end
      later = since_named.index { |_, unreleased| unreleased.empty? }
      return [since_named[later].first, later] if later

      raise Error, "these changelog entries landed before v#{name} was named, so they'd ship without a line in " \
                   "What ships:\n#{since_named.first.last.join("\n")}\nMove them under ## v#{name} by a PR into #{integration}, then run cut again"
    end

    def waiting_release
      pr = Candidate.waiting(JSON.parse(gh("pr", "list", "--base", production, "--state", "all", "--limit", "30", "--json", "number,headRefName,state,headRefOid")), usage: SHIP_USAGE) { |name| tagged?(name) }
      runs, listed = gh("run", "list", "--workflow", @config.staging_workflow, "--branch", pr["headRefName"], "--event", "push",
        "--json", "headSha,conclusion", status: true)
      [pr["number"].to_s, pr["headRefOid"], Candidate.found(pr, listed ? JSON.parse(runs) : [])]
    end

    def release_name(info)
      name = info["headRefName"].to_s[Candidate::BRANCH, 1]
      raise Error, "that PR is not a release/* branch into #{production}" unless name && info["baseRefName"] == production

      name
    end

    def publish(name, commit)
      raise Error, "GitHub reports no merge commit for release #{name}; check its PR" unless commit

      fetch
      return say("  ✓ v#{name} already published") if tagged?(name)

      notes = fit(Changelog.section(git("show", "#{commit}:CHANGELOG.md"), name).to_s,
        BODY_LIMIT, "the full list is in CHANGELOG.md at v#{name}")
      err, created = gh("release", "create", "v#{name}", "--target", commit, "--title", "Release #{name}", "--notes-file", "-", stdin: notes, status: true)
      return say("  → merged and published v#{name}") if created

      fetch
      raise Error, "gh release create failed: #{err}" unless tagged?(name)

      say("  ✓ v#{name} already published")
    end

    # Pushes the branch unless a stopped run already did, then opens its PR or finds the open one.
    def propose(branch, at:, base:, title:, body:, auto_merge: false)
      push(at, branch) unless branch?(branch)
      url, created = gh("pr", "create", "--base", base, "--head", branch, "--title", title, "--body-file", "-",
        stdin: body, status: true)
      raise Error, "gh pr create failed: #{url}" unless created || url.include?("already exists")

      url = gh("pr", "view", branch, "--json", "url", "--jq", ".url") unless created
      gh("pr", "merge", url, "--auto", "--merge") if auto_merge
      url
    end

    # A commit already on origin passed CI's required checks on its way there; the hook adds nothing.
    def push(at, branch)
      ref = "#{at}:refs/heads/#{branch}"
      return git("push", "-q", "--no-verify", "origin", ref) unless git("for-each-ref", "--contains", at, "refs/remotes/origin").empty?

      say("  pushing #{branch}; the pre-push hook checks it first, which can take a few minutes") if pre_push_hook?
      out, err, status = Open3.capture3(CLEAN_GIT_ENV, "git", "-C", @root, "push", "-q", "origin", ref)
      return if status.success?

      output = "#{out}#{err}".gsub(/\e\[[\d;]*m/, "")
      log = File.join(@root, "tmp/release-push.log")
      FileUtils.mkdir_p(File.dirname(log))
      File.write(log, output)
      raise Error, "git push of #{branch} failed. The end of what it said:\n#{output.lines.last(15).join.rstrip}\n" \
                   "All of it is in #{log.delete_prefix("#{@root}/")}"
    end

    def pre_push_hook? = File.executable?(File.expand_path(git("rev-parse", "--git-path", "hooks/pre-push"), @root))

    def release_body(branch, section)
      template = File.read(File.join(@root, TEMPLATE)).sub("`release/YYYY.MM.DD`", "`#{branch}`")
      room = BODY_LIMIT - template.length
      template.sub(/(## What ships\n\n)<!--.*?-->/m) { "#{$1}#{fit(section, room, "the full list is in CHANGELOG.md on #{branch}")}" }
    end

    def fit(text, limit, rest)
      note = "\n\n…and more: #{rest}."
      return text if text.length <= limit

      text[0, limit - note.length].sub(/\n[^\n]*\z/, "") + note
    end

    def commit_on(parent, files, message:)
      Dir.mktmpdir do |dir|
        env = CLEAN_GIT_ENV.merge("GIT_INDEX_FILE" => File.join(dir, "index"))
        git("read-tree", parent, env: env)
        files.each do |path, content|
          next git("update-index", "--force-remove", path, env: env) if content.nil?

          git("update-index", "--add", "--cacheinfo", "100644,#{git("hash-object", "-w", "--stdin", stdin: content)},#{path}", env: env)
        end
        git("commit-tree", git("write-tree", env: env), "-p", parent, "-m", message)
      end
    end

    def ancestor?(older, newer)
      _, _, status = Open3.capture3(CLEAN_GIT_ENV, "git", "-C", @root, "merge-base", "--is-ancestor", older, newer)
      status.success?
    end

    def git(*args, env: CLEAN_GIT_ENV, stdin: nil)
      out, err, status = Open3.capture3(env, "git", "-C", @root, *args, stdin_data: stdin.to_s)
      raise Error, "git #{args.first} failed: #{err.strip}" unless status.success?

      out.strip
    end

    def gh(*args, stdin: nil, status: false)
      out, err, result = Open3.capture3(CLEAN_GIT_ENV.merge("GH_REPO" => @repo), "gh", *args, stdin_data: stdin.to_s, chdir: @root)
      return [result.success? ? out.strip : err.strip, result.success?] if status
      raise Error, "gh #{args.first(2).join(" ")} failed: #{err.strip}" unless result.success?

      out.strip
    rescue Errno::ENOENT
      raise Error, "bin/release needs the GitHub CLI (gh), signed in"
    end
  end
end
