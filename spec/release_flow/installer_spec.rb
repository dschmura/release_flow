# frozen_string_literal: true

RSpec.describe ReleaseFlow::Installer do
  let(:root) { Pathname.new(Dir.mktmpdir) }
  let(:out) { StringIO.new }

  before do
    root.join(".github/workflows").mkpath
    root.join(".github/workflows/ci.yml").write("name: Checks\non: push\n")
  end

  after { FileUtils.rm_rf(root) }

  def init = described_class.start(["init"], root: root.to_s, out: out)

  it "writes the binstub, the release workflow, the release template and the changelog.d README" do
    expect(init).to eq(0)

    expect(root.join("bin/release")).to be_executable
    expect(root.join(".github/workflows/next_release.yml").read).to include("workflows: [ Checks ]").and include("branches: [ next ]")
    expect(root.join(".github/PULL_REQUEST_TEMPLATE/release.md").read).to include("## What ships")
    expect(root.join("changelog.d/README.md").read).to include("bin/release prepare")
  end

  it "writes valid YAML for the workflow" do
    init

    expect(YAML.safe_load(root.join(".github/workflows/next_release.yml").read, aliases: true)).to include("jobs")
  end

  describe "the release workflow's jobs" do
    let(:workflow) do
      root.join(".release_flow.yml").write("integration_branch: develop\nproduction_branch: trunk\n")
      init
      YAML.safe_load(root.join(".github/workflows/next_release.yml").read, aliases: true)
    end
    let(:triggers) { workflow[true] }
    let(:jobs) { workflow["jobs"] }

    it "hears merged PRs into both branches" do
      expect(triggers.dig("pull_request", "branches")).to eq(%w[develop trunk])
    end

    it "names a release only after a merge into the integration branch" do
      expect(jobs.dig("prepare", "if")).to include("github.event.pull_request.base.ref == 'develop'")
    end

    it "finishes shipping a release PR merged into production on GitHub, at the head that merged" do
      ship = jobs.fetch("ship")

      expect(ship["if"]).to include("github.event.pull_request.merged")
        .and include("github.event.pull_request.base.ref == 'trunk'")
        .and include("startsWith(github.event.pull_request.head.ref, 'release/')")
      step = ship["steps"].find { |s| s["run"].to_s.include?("bin/release ship") }
      expect(step["env"]).to include("PR" => "${{ github.event.pull_request.number }}", "HEAD_SHA" => "${{ github.event.pull_request.head.sha }}")
      expect(step["run"]).to include('bin/release ship "$PR" "$HEAD_SHA"')
    end
  end

  it "starts a CHANGELOG.md with an [Unreleased] section when there is none" do
    init

    expect(root.join("CHANGELOG.md").read).to eq("# Changelog\n\n## [Unreleased]\n")
  end

  it "keeps a file that already exists, and says so" do
    root.join("CHANGELOG.md").write("# Mine\n\n## [Unreleased]\n")
    init

    expect(root.join("CHANGELOG.md").read).to eq("# Mine\n\n## [Unreleased]\n")
    expect(out.string).to include("kept CHANGELOG.md")
  end

  it "warns when an existing CHANGELOG.md has no [Unreleased] section" do
    root.join("CHANGELOG.md").write("# Mine\n")
    init

    expect(out.string).to include("CHANGELOG.md has no ## [Unreleased] heading")
  end

  it "writes the names .release_flow.yml sets" do
    root.join(".release_flow.yml").write("integration_branch: develop\nproduction_branch: trunk\nci_workflow: test.yml\n")
    root.join(".github/workflows/test.yml").write("name: Tests\n")
    init

    workflow = root.join(".github/workflows/next_release.yml").read
    expect(workflow).to include("workflows: [ Tests ]").and include("branches: [ develop ]").and include("ref: develop")
    expect(root.join(".github/PULL_REQUEST_TEMPLATE/release.md").read).to include("into trunk")
  end

  it "stops before writing anything when the CI workflow it would wait on doesn't exist" do
    root.join(".github/workflows/ci.yml").delete

    expect { expect(init).to eq(1) }.to output(/no \.github\/workflows\/ci\.yml: set ci_workflow/).to_stderr
    expect(root.join("bin/release")).not_to exist
  end

  it "refuses anything but init" do
    expect { expect(described_class.start(["setup"], root: root.to_s, out: out)).to eq(1) }
      .to output(/usage: release_flow init/).to_stderr
  end

  it "installs a binstub that runs the flow" do
    init
    script = root.join("bin/release")
    lib = File.expand_path("../../lib", __dir__)
    output = IO.popen({"RUBYLIB" => lib}, [RbConfig.ruby, script.to_s, "--help"], err: [:child, :out], &:read)

    expect(output).to include("usage: bin/release prepare | cut")
  end
end
