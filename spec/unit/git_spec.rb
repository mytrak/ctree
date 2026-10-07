# frozen_string_literal: true

RSpec.describe Ctree::Git do
  describe ".detect_default_branch" do
    let(:root) { Pathname("/fake/source") }

    def git_status(ok)
      instance_double(Process::Status, success?: ok)
    end

    it "returns the branch origin/HEAD points at" do
      allow(Ctree::Sh).to receive(:capture3)
        .and_return(["refs/remotes/origin/main", "", git_status(true)])
      expect(described_class.detect_default_branch(root)).to eq("main")
    end

    it "returns master when origin/HEAD is absent and refs/heads/master exists" do
      allow(Ctree::Sh).to receive(:capture3) do |*args|
        args.include?("symbolic-ref") ? ["", "", git_status(false)] : ["", "", git_status(true)]
      end
      expect(described_class.detect_default_branch(root)).to eq("master")
    end

    it "returns main when origin/HEAD and refs/heads/master are both absent" do
      allow(Ctree::Sh).to receive(:capture3).and_return(["", "", git_status(false)])
      expect(described_class.detect_default_branch(root)).to eq("main")
    end
  end
end
