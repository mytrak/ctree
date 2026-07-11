# frozen_string_literal: true

RSpec.describe Ctree::Free do
  describe ".first_available_branch" do
    it "returns the first sorted branch not in the occupied set" do
      result = described_class.first_available_branch(
        ["FREE-001", "FREE-002", "FREE-003"],
        Set["FREE-001", "FREE-003"]
      )
      expect(result).to eq("FREE-002")
    end

    it "returns nil when all branches are occupied" do
      result = described_class.first_available_branch(
        ["FREE-001", "FREE-002"],
        Set["FREE-001", "FREE-002"]
      )
      expect(result).to be_nil
    end

    it "returns nil when all_free is empty" do
      expect(described_class.first_available_branch([], Set[])).to be_nil
    end

    it "returns the lowest sorted branch when multiple are available" do
      result = described_class.first_available_branch(
        ["FREE-003", "FREE-001", "FREE-002"],
        Set[]
      )
      expect(result).to eq("FREE-001")
    end
  end

  describe ".next_sequential_branch" do
    it "returns FREE-001 when no numeric branches exist" do
      expect(described_class.next_sequential_branch("FREE-", [])).to eq("FREE-001")
    end

    it "fills the first gap: FREE-001 and FREE-003 exist -> FREE-002" do
      expect(described_class.next_sequential_branch("FREE-", ["FREE-001", "FREE-003"])).to eq("FREE-002")
    end

    it "uses max+1 when no gaps: FREE-001 and FREE-002 exist -> FREE-003" do
      expect(described_class.next_sequential_branch("FREE-", ["FREE-001", "FREE-002"])).to eq("FREE-003")
    end

    it "handles max=999 with no gaps -> FREE-1000" do
      branches = (1..999).map { |n| "FREE-#{n.to_s.rjust(3, "0")}" }
      expect(described_class.next_sequential_branch("FREE-", branches)).to eq("FREE-1000")
    end

    it "ignores non-numeric free branches" do
      expect(described_class.next_sequential_branch("FREE-", ["FREE-main", "FREE-experiment"])).to eq("FREE-001")
    end
  end

  describe ".run" do
    around do |ex|
      Dir.mktmpdir do |src|
        Dir.mktmpdir do |tgt|
          @source = Pathname.new(src).realpath
          @target = Pathname.new(tgt).realpath
          Dir.chdir(@target.to_s) { ex.run }
        end
      end
    end

    # Stubs all git calls and the prompt. checkout calls fall through to the
    # else clause (returning success) so have_received can assert them after.
    def stub_run(prompt_answer: "", branches_output: "", porcelain: "")
      allow(Ctree::Prompt).to receive(:read_line).and_return(prompt_answer)
      allow(Ctree::Config).to receive(:load).and_return(
        Ctree::Config.defaults.merge(free_branch_prefix: "FREE-")
      )
      allow(Ctree::Sh).to receive(:capture3) do |*cmd|
        case [cmd[3], cmd[4]]
        when ["rev-parse", "--show-toplevel"]
          [@target.to_s, "", fake_status(true)]
        when ["rev-parse", "--git-common-dir"]
          [(@source / ".git").to_s, "", fake_status(true)]
        when ["branch", "--list"]
          [branches_output, "", fake_status(true)]
        when ["worktree", "list"]
          [porcelain, "", fake_status(true)]
        else
          ["", "", fake_status(true)]
        end
      end
    end

    it "exits cleanly when user answers n" do
      stub_run(prompt_answer: "n")
      expect { described_class.run }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
    end

    it "exits early without prompting when already on a free branch" do
      stub_run
      allow(Ctree::Sh).to receive(:capture3)
        .with("git", "-C", @target.to_s, "rev-parse", "--abbrev-ref", "HEAD")
        .and_return(["FREE-005", "", fake_status(true)])
      expect { described_class.run }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
        .and output(/already on a free branch \(FREE-005\)/).to_stdout
      expect(Ctree::Prompt).not_to have_received(:read_line)
      expect(Ctree::Sh).not_to have_received(:capture3)
        .with("git", "-C", @target.to_s, "checkout", anything)
    end

    it "proceeds normally when the current branch does not match the free prefix" do
      stub_run(
        branches_output: "  FREE-001\n  FREE-002\n",
        porcelain: "worktree /src/example\nHEAD abc\nbranch refs/heads/FREE-001\n\n"
      )
      allow(Ctree::Sh).to receive(:capture3)
        .with("git", "-C", @target.to_s, "rev-parse", "--abbrev-ref", "HEAD")
        .and_return(["CTR-026", "", fake_status(true)])
      described_class.run
      expect(Ctree::Sh).to have_received(:capture3)
        .with("git", "-C", @target.to_s, "checkout", "FREE-002")
    end

    it "checks out the first available free branch" do
      stub_run(
        branches_output: "  FREE-001\n  FREE-002\n",
        porcelain: "worktree /src/example\nHEAD abc\nbranch refs/heads/FREE-001\n\n"
      )
      described_class.run
      expect(Ctree::Sh).to have_received(:capture3)
        .with("git", "-C", @target.to_s, "checkout", "FREE-002")
    end

    it "logs the checked-out branch before the rebase step" do
      stub_run(
        branches_output: "  FREE-001\n  FREE-002\n",
        porcelain: "worktree /src/example\nHEAD abc\nbranch refs/heads/FREE-001\n\n"
      )
      expect { described_class.run }
        .to output(/checked out FREE-002.*already up to date with master/m).to_stdout
    end

    it "strips + prefix from branches checked out in other worktrees" do
      stub_run(
        branches_output: "+ FREE-001\n  FREE-002\n",
        porcelain: "worktree /src/example\nHEAD abc\nbranch refs/heads/FREE-001\n\n"
      )
      described_class.run
      expect(Ctree::Sh).to have_received(:capture3)
        .with("git", "-C", @target.to_s, "checkout", "FREE-002")
    end

    it "creates and checks out next sequential branch when all are occupied" do
      stub_run(
        branches_output: "  FREE-001\n",
        porcelain: "worktree /src/example\nHEAD abc\nbranch refs/heads/FREE-001\n\n"
      )
      described_class.run
      expect(Ctree::Sh).to have_received(:capture3)
        .with("git", "-C", @target.to_s, "checkout", "-b", "FREE-002")
    end

    it "creates FREE-001 when no free branches exist at all" do
      stub_run(branches_output: "", porcelain: "")
      described_class.run
      expect(Ctree::Sh).to have_received(:capture3)
        .with("git", "-C", @target.to_s, "checkout", "-b", "FREE-001")
    end

    it "reports the freed branch is already up to date when master is an ancestor" do
      stub_run(
        branches_output: "  FREE-001\n  FREE-002\n",
        porcelain: "worktree /src/example\nHEAD abc\nbranch refs/heads/FREE-001\n\n"
      )
      expect { described_class.run }.to output(/FREE-002 already up to date with master/).to_stdout
      expect(Ctree::Sh).not_to have_received(:capture3)
        .with("git", "-C", @target.to_s, "rebase", "master")
    end

    it "rebases the freed branch onto master when it is behind" do
      stub_run(
        branches_output: "  FREE-001\n  FREE-002\n",
        porcelain: "worktree /src/example\nHEAD abc\nbranch refs/heads/FREE-001\n\n"
      )
      allow(Ctree::Sh).to receive(:capture3)
        .with("git", "-C", @target.to_s, "merge-base", "--is-ancestor", "master", "HEAD")
        .and_return(["", "", fake_status(false)])
      allow(Ctree::Sh).to receive(:capture3)
        .with("git", "-C", @target.to_s, "rebase", "master")
        .and_return(["", "", fake_status(true)])
      expect { described_class.run }.to output(/rebased FREE-002 onto master/).to_stdout
      expect(Ctree::Sh).to have_received(:capture3)
        .with("git", "-C", @target.to_s, "rebase", "master")
    end

    it "aborts the rebase and dies when the freed branch conflicts with master" do
      stub_run(
        branches_output: "  FREE-001\n  FREE-002\n",
        porcelain: "worktree /src/example\nHEAD abc\nbranch refs/heads/FREE-001\n\n"
      )
      allow(Ctree::Sh).to receive(:capture3)
        .with("git", "-C", @target.to_s, "merge-base", "--is-ancestor", "master", "HEAD")
        .and_return(["", "", fake_status(false)])
      allow(Ctree::Sh).to receive(:capture3)
        .with("git", "-C", @target.to_s, "rebase", "master")
        .and_return(["", "conflict", fake_status(false)])
      allow(Ctree::Sh).to receive(:capture3)
        .with("git", "-C", @target.to_s, "rebase", "--abort")
        .and_return(["", "", fake_status(true)])
      expect { described_class.run }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        .and output(/rebase conflict/).to_stderr
      expect(Ctree::Sh).to have_received(:capture3)
        .with("git", "-C", @target.to_s, "rebase", "--abort")
    end

    it "dies when run from the source repo" do
      allow(Ctree::Sh).to receive(:capture3) do |*cmd|
        case [cmd[3], cmd[4]]
        when ["rev-parse", "--show-toplevel"] then [@source.to_s, "", fake_status(true)]
        when ["rev-parse", "--git-common-dir"] then [(@source / ".git").to_s, "", fake_status(true)]
        else raise "unexpected: #{cmd.inspect}"
        end
      end
      Dir.chdir(@source.to_s) do
        expect { described_class.run }
          .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
          .and output(/source project/).to_stderr
      end
    end
  end
end
