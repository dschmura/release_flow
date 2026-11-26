# frozen_string_literal: true

RSpec.describe ReleaseFlow::CLI do
  let(:root) { Pathname.new(Dir.mktmpdir) }

  after { FileUtils.rm_rf(root) }

  it "fails with the reason, not a backtrace, when the flow refuses" do
    root.join(".release_flow.yml").write("intergration_branch: develop\n")

    expect { expect(described_class.start(["check"], root: root.to_s)).to eq(1) }
      .to output(/\Abin\/release: \.release_flow\.yml has no setting intergration_branch/).to_stderr
  end

  it "takes a config from its caller, so a binstub can add what .release_flow.yml doesn't say" do
    config = ReleaseFlow::Config.load(root.to_s).with(guide: "https://example.com/releasing")

    expect { expect(described_class.start(["--help"], root: root.to_s, config: config)).to eq(0) }
      .to output(%r{see https://example\.com/releasing}).to_stdout
  end

  it "passes --wait and a --timeout in minutes to the flow" do
    flow = instance_double(ReleaseFlow::Release, run: nil)
    allow(ReleaseFlow::Release).to receive(:new).and_return(flow)

    expect(described_class.start(["cut", "--wait", "--timeout", "10"], root: root.to_s)).to eq(0)
    expect(ReleaseFlow::Release).to have_received(:new).with({wait: true, timeout: 600}, root: root.to_s, config: anything)
  end

  it "exits 130 with how to resume when a wait is interrupted" do
    flow = instance_double(ReleaseFlow::Release)
    allow(flow).to receive(:run).and_raise(ReleaseFlow::Release::Stopped, "stopped watching release PR #42")
    allow(ReleaseFlow::Release).to receive(:new).and_return(flow)

    expect { expect(described_class.start(["cut", "--wait"], root: root.to_s)).to eq(130) }
      .to output("bin/release: stopped watching release PR #42\n").to_stderr
  end

  it "fails with the reason on an option it doesn't know" do
    expect { expect(described_class.start(["--frobnicate"], root: root.to_s)).to eq(1) }
      .to output(/bin\/release: invalid option: --frobnicate/).to_stderr
  end

  it "fails with the usage on a command it doesn't know" do
    system(ReleaseFlow::GitEnv::HASH, "git", "-C", root.to_s, "init", "-q", exception: true)
    system(ReleaseFlow::GitEnv::HASH, "git", "-C", root.to_s, "remote", "add", "origin", "git@github.com:me/app.git", exception: true)

    expect { expect(described_class.start(["deploy"], root: root.to_s)).to eq(1) }
      .to output(/usage: bin\/release prepare/).to_stderr
  end
end
