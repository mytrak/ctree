# frozen_string_literal: true

require "stringio"

RSpec.describe Ctree::CLI do
  describe "ctree help" do
    it "prints help for a known command with a leading and trailing blank line" do
      expect { Ctree::CLI.run(["help", "create"]) }
        .to output(/\A\nUsage:.*\n\n\z/m).to_stdout
    end

    it "exits 0 for a known command" do
      expect { Ctree::CLI.run(["help", "create"]) }.not_to raise_error
    end

    it "prints help for every registered command without error" do
      Ctree::CLI::HELP.each_key do |cmd|
        expect { Ctree::CLI.run(["help", cmd]) }
          .to output(/.+/).to_stdout, "expected help output for '#{cmd}'"
      end
    end

    it "exits 1 and prints an error for an unknown command" do
      expect { Ctree::CLI.run(["help", "notacommand"]) }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        .and output(/notacommand/).to_stderr
    end

    it "prints general usage when no command is given" do
      expect { Ctree::CLI.run(["help"]) }
        .to output(/Usage:/).to_stdout
    end

    it "prints a standard Available Commands table, computed from Ctree::CLI::COMMANDS" do
      expect { Ctree::CLI.run(["help"]) }.to output(a_string_including(
        "Replicate a Docker Compose dev tree as a sibling git worktree with its own branch, volumes, and .env.",
        "Usage:\n  ctree [command]",
        "Available Commands:",
        *Ctree::CLI::COMMANDS.map { |name, desc| "  #{name.ljust(Ctree::CLI::COMMAND_NAME_WIDTH)}#{desc}" },
        'Use "ctree help <command>" for more information about a command.'
      )).to_stdout
    end

    it "does not list shell-init in the Available Commands table" do
      out = StringIO.new
      $stdout = out
      Ctree::CLI.run(["help"])
      $stdout = STDOUT
      expect(out.string).not_to include("shell-init")
    end

    it "keeps the worktree-context footnote before the help footer" do
      captured = StringIO.new
      original_stdout = $stdout
      $stdout = captured
      begin
        Ctree::CLI.run(["help"])
      ensure
        $stdout = original_stdout
      end
      text = captured.string
      footnote_index = text.index("Most commands run from the top of the source repository.")
      footer_index = text.index('Use "ctree help <command>" for more information about a command.')
      expect(footnote_index).not_to be_nil
      expect(footer_index).not_to be_nil
      expect(footnote_index).to be < footer_index
    end
  end
end
