# frozen_string_literal: true

RSpec.describe ReleaseFlow::CLI do
  let(:root) { Pathname.new(Dir.mktmpdir) }

  after { FileUtils.rm_rf(root) }

  it "fails with the reason, not a backtrace, when the flow refuses" do
    root.join(".release_flow.yml").write("intergration_branch: develop\n")

    expect { expect(described_class.start(["check"], root: root.to_s)).to eq(1) }
      .to output(/\Abin\/release: \.release_flow\.yml has no setting intergration_branch/).to_stderr
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
