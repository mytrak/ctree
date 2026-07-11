# frozen_string_literal: true

RSpec.describe Ctree::List do
  PORCELAIN_TWO_WORKTREES = <<~PORCELAIN
    worktree /src/example-source
    HEAD abc123
    branch refs/heads/main

    worktree /src/example-three
    HEAD def456
    branch refs/heads/CTR-003

    worktree /src/example-six
    HEAD ghi789
    branch refs/heads/EGG-2231

  PORCELAIN

  around do |ex|
    Dir.mktmpdir do |tmp|
      @root = Pathname.new(tmp).realpath
      Dir.chdir(@root.to_s) { ex.run }
    end
  end

  def stub_git_and_config(prefix: "", porcelain: PORCELAIN_TWO_WORKTREES)
    allow(Ctree::Sh).to receive(:capture3) do |*cmd|
      case [cmd[0], cmd[3], cmd[4]]
      when ["git", "rev-parse", "--show-toplevel"]
        [@root.to_s, "", fake_status(true)]
      when ["git", "worktree", "list"]
        [porcelain, "", fake_status(true)]
      else
        raise "unexpected Sh.capture3: #{cmd.inspect}"
      end
    end
    allow(Ctree::Config).to receive(:load).and_return(
      Ctree::Config.defaults.merge(free_branch_prefix: prefix)
    )
  end

  describe ".run without filter" do
    context "when free_branch_prefix is blank" do
      it "prints all worktrees without (free) tags" do
        stub_git_and_config(prefix: "")
        expect { described_class.run }.to output(/CTR-003\]/).to_stdout
        expect { described_class.run }.not_to output(/\(free\)/).to_stdout
      end
    end

    context "when free_branch_prefix is set" do
      before { stub_git_and_config(prefix: "CTR-") }

      it "annotates matching branches with (free)" do
        expect { described_class.run }.to output(/CTR-003 \(free\)/).to_stdout
      end

      it "does not annotate non-matching branches" do
        expect { described_class.run }.to output(/EGG-2231\]/).to_stdout
        expect { described_class.run }.not_to output(/EGG-2231 \(free\)/).to_stdout
      end

      it "prints all worktrees regardless of match" do
        output = nil
        expect { output = capture_stdout { described_class.run } }.not_to raise_error
        expect(output).to include("CTR-003")
        expect(output).to include("EGG-2231")
      end
    end
  end

  describe ".run with filter: :free" do
    context "when free_branch_prefix is blank" do
      it "prints no worktrees" do
        stub_git_and_config(prefix: "")
        output = capture_stdout { described_class.run(filter: :free) }
        expect(output).not_to include("CTR-003")
        expect(output).not_to include("EGG-2231")
      end

      it "prints a message that free_branch_prefix is not configured" do
        stub_git_and_config(prefix: "")
        expect { described_class.run(filter: :free) }
          .to output(/free_branch_prefix not set in .ctree\/config\.yml/).to_stdout
      end
    end

    context "when free_branch_prefix is set but no worktrees match" do
      before { stub_git_and_config(prefix: "NOMATCH-") }

      it "prints a message indicating no matches for the prefix" do
        expect { described_class.run(filter: :free) }
          .to output(/no free worktrees matching "NOMATCH-"/).to_stdout
      end

      it "prints no worktree entries" do
        output = capture_stdout { described_class.run(filter: :free) }
        expect(output).not_to include("example-")
      end
    end

    context "when free_branch_prefix is set" do
      before { stub_git_and_config(prefix: "CTR-") }

      it "shows only worktrees whose branch matches the prefix" do
        output = capture_stdout { described_class.run(filter: :free) }
        expect(output).to include("CTR-003")
        expect(output).not_to include("EGG-2231")
      end

      it "annotates the filtered worktrees with (free)" do
        expect { described_class.run(filter: :free) }.to output(/CTR-003 \(free\)/).to_stdout
      end
    end
  end

  describe ".run with filter: :used" do
    context "when free_branch_prefix is blank" do
      it "shows all worktrees" do
        stub_git_and_config(prefix: "")
        output = capture_stdout { described_class.run(filter: :used) }
        expect(output).to include("CTR-003")
        expect(output).to include("EGG-2231")
      end
    end

    context "when free_branch_prefix is set" do
      before { stub_git_and_config(prefix: "CTR-") }

      it "shows only worktrees whose branch does not match the prefix" do
        output = capture_stdout { described_class.run(filter: :used) }
        expect(output).to include("EGG-2231")
        expect(output).not_to include("CTR-003")
      end

      it "does not annotate used worktrees with (free)" do
        expect { described_class.run(filter: :used) }.not_to output(/\(free\)/).to_stdout
      end
    end

    context "when all worktrees are free" do
      before do
        all_free = <<~PORCELAIN
          worktree /src/example-source
          HEAD abc123
          branch refs/heads/CTR-001

          worktree /src/example-two
          HEAD def456
          branch refs/heads/CTR-002

        PORCELAIN
        stub_git_and_config(prefix: "CTR-", porcelain: all_free)
      end

      it "prints a message that no used worktrees exist" do
        expect { described_class.run(filter: :used) }
          .to output(/no used worktrees/).to_stdout
      end
    end
  end

  describe "Ctree::CLI list all" do
    it "produces the same output as ctree list with no subcommand" do
      stub_git_and_config(prefix: "CTR-")
      output_all  = capture_stdout { Ctree::CLI.run(["list", "all"]) }
      output_none = capture_stdout { Ctree::CLI.run(["list"]) }
      expect(output_all).to eq(output_none)
    end
  end

  describe ".parse_worktree_porcelain" do
    it "parses path, branch, and marks first entry as source" do
      entries = described_class.parse_worktree_porcelain(PORCELAIN_TWO_WORKTREES)
      expect(entries.length).to eq(3)
      expect(entries[0][:path]).to eq("/src/example-source")
      expect(entries[0][:branch]).to eq("main")
      expect(entries[0][:source]).to be(true)
      expect(entries[1][:path]).to eq("/src/example-three")
      expect(entries[1][:branch]).to eq("CTR-003")
      expect(entries[1][:source]).to be_nil
    end

    it "marks detached HEAD entries with nil branch" do
      porcelain = "worktree /src/detached\nHEAD abc\ndetached\n\n"
      entries = described_class.parse_worktree_porcelain(porcelain)
      expect(entries[0][:branch]).to be_nil
    end
  end

  def capture_stdout
    output = StringIO.new
    $stdout = output
    yield
    output.string
  ensure
    $stdout = STDOUT
  end
end
