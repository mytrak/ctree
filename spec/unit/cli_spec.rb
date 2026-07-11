# frozen_string_literal: true

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
  end
end
