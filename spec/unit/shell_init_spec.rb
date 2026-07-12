# frozen_string_literal: true

RSpec.describe Ctree::ShellInit do
  describe ".shell_function" do
    subject(:fn) { described_class.send(:shell_function, "ctree", "/opt/ctree/bin/ctree") }

    it "defines a function named after the given name" do
      expect(fn).to include("ctree() {")
    end

    it "routes switch through the binary and cds into the resolved path" do
      expect(fn).to include(%q{target=$("/opt/ctree/bin/ctree" list})
      expect(fn).to include(%q{cd "$target"})
    end

    it "passes all other subcommands straight through to the binary" do
      expect(fn).to include(%q{    "/opt/ctree/bin/ctree" "$@"})
    end

    it "uses the given name in its own messages" do
      expect(fn).to include(%q{echo "ctree: worktree '$2' not found"})
    end
  end

  describe ".run" do
    it "prints the shell function when stdout is captured by a process" do
      allow($stdout).to receive(:tty?).and_return(false)
      expect { described_class.run }.to output(/ctree\(\) \{/).to_stdout
    end

    it "prints an install hint and exits non-zero when run interactively" do
      allow($stdout).to receive(:tty?).and_return(true)
      expect do
        expect { described_class.run }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end.to output(/meant to be evaluated by your shell/).to_stderr
    end
  end
end
