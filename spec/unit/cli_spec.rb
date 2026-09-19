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

    it "prints the colima-style Available Commands table, computed from Ctree::CLI::COMMANDS" do
      expect { Ctree::CLI.run(["help"]) }.to output(a_string_including(
        "Replicate a Docker Compose dev tree as a sibling git worktree with its own branch, volumes, and .env.",
        "Usage:\n  ctree [command]",
        "Available Commands:",
        *Ctree::CLI::COMMAND_SIGNATURES.zip(Ctree::CLI::COMMANDS).map { |sig, (_, _, desc)|
          "  #{sig.ljust(Ctree::CLI::COMMAND_SIGNATURE_WIDTH)}#{desc}"
        },
        "Use \"ctree help\n<command>\" for more information about a command and its options."
      )).to_stdout
    end

    it "shows a command's required arguments next to its name" do
      _, args, desc = Ctree::CLI::COMMANDS.find { |name, _, _| name == "create" }
      expect(args).to eq("<worktree_name> <branch_name>")
      expect { Ctree::CLI.run(["help"]) }.to output(a_string_including(
        "  #{"create #{args}".ljust(Ctree::CLI::COMMAND_SIGNATURE_WIDTH)}#{desc}"
      )).to_stdout
    end

    it "shows a command's optional sub-command syntax next to its name" do
      _, args, desc = Ctree::CLI::COMMANDS.find { |name, _, _| name == "list" }
      expect(args).to eq("[all | free | used]")
      expect { Ctree::CLI.run(["help"]) }.to output(a_string_including(
        "  #{"list #{args}".ljust(Ctree::CLI::COMMAND_SIGNATURE_WIDTH)}#{desc}"
      )).to_stdout
    end

    it "shows no trailing space for a command that takes no arguments" do
      _, args, desc = Ctree::CLI::COMMANDS.find { |name, _, _| name == "rebase" }
      expect(args).to eq("")
      expect { Ctree::CLI.run(["help"]) }.to output(a_string_including(
        "  #{"rebase".ljust(Ctree::CLI::COMMAND_SIGNATURE_WIDTH)}#{desc}"
      )).to_stdout
    end

    it "shows help's command argument as optional, matching its actual optional usage" do
      # `ctree help` with no further argument is valid (prints general usage),
      # so this is bracketed as optional rather than required — a deliberate
      # correction from the pre-Task-1 USAGE text, which showed `<command>`.
      _, args, _ = Ctree::CLI::COMMANDS.find { |name, _, _| name == "help" }
      expect(args).to eq("[command]")
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
      footnote_index = text.index("Most commands run from the source repository.")
      footer_index = text.index("Use \"ctree help\n<command>\" for more information about a command and its options.")
      expect(footnote_index).not_to be_nil
      expect(footer_index).not_to be_nil
      expect(footnote_index).to be < footer_index
    end
  end

  describe "ctree create --config" do
    before do
      # Stub out Create.run so we don't actually create worktrees
      allow(Ctree::Create).to receive(:run)
    end

    it "accepts --config <path> and passes config_path to Create.run" do
      Ctree::CLI.run(["create", "wt1", "branch1", "--config", "/tmp/my_config.yml"])
      expect(Ctree::Create).to have_received(:run).with(
        name: "wt1", branch: "branch1", config_path: "/tmp/my_config.yml", force: false
      )
    end

    it "accepts --config=<path> and passes config_path to Create.run" do
      Ctree::CLI.run(["create", "wt1", "branch1", "--config=/tmp/my_config.yml"])
      expect(Ctree::Create).to have_received(:run).with(
        name: "wt1", branch: "branch1", config_path: "/tmp/my_config.yml", force: false
      )
    end

    it "accepts --config <path> as a relative path and passes it to Create.run" do
      Ctree::CLI.run(["create", "wt1", "branch1", "--config", "relative_config.yml"])
      expect(Ctree::Create).to have_received(:run).with(
        name: "wt1", branch: "branch1", config_path: "relative_config.yml", force: false
      )
    end

    it "passes config_path: nil when --config is not given" do
      Ctree::CLI.run(["create", "wt1", "branch1"])
      expect(Ctree::Create).to have_received(:run).with(
        name: "wt1", branch: "branch1", config_path: nil, force: false
      )
    end

    it "strips --force from argv regardless of position and passes force: true" do
      Ctree::CLI.run(["create", "wt1", "branch1", "--force"])
      expect(Ctree::Create).to have_received(:run).with(
        name: "wt1", branch: "branch1", config_path: nil, force: true
      )
      Ctree::CLI.run(["--force", "create", "wt2", "branch2"])
      expect(Ctree::Create).to have_received(:run).with(
        name: "wt2", branch: "branch2", config_path: nil, force: true
      )
    end

    it "strips --log-file=PATH from argv and implies force: true even without --force" do
      Dir.mktmpdir do |dir|
        log_path = File.join(dir, "ctree.log")
        Ctree::CLI.run(["create", "wt1", "branch1", "--log-file=#{log_path}"])
        expect(Ctree::Create).to have_received(:run).with(
          name: "wt1", branch: "branch1", config_path: nil, force: true
        )
      end
    ensure
      Ctree::LogFile.reset!
    end

    it "strips --log-file PATH from argv and implies force: true even without --force" do
      Dir.mktmpdir do |dir|
        log_path = File.join(dir, "ctree.log")
        Ctree::CLI.run(["create", "wt1", "branch1", "--log-file", log_path])
        expect(Ctree::Create).to have_received(:run).with(
          name: "wt1", branch: "branch1", config_path: nil, force: true
        )
      end
    ensure
      Ctree::LogFile.reset!
    end

    it "exits when --config flag is given but no path follows" do
      expect {
        Ctree::CLI.run(["create", "wt1", "branch1", "--config"])
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end

    it "exits when the flag in position 3 is not --config" do
      expect {
        Ctree::CLI.run(["create", "wt1", "branch1", "--cfg", "/tmp/x.yml"])
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end

    it "exits when there are 4 arguments (wrong arg count)" do
      expect {
        Ctree::CLI.run(["create", "wt1", "branch1", "extra"])
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end

    it "still validates the worktree name with --config" do
      expect {
        Ctree::CLI.run(["create", "BAD NAME", "branch1", "--config", "/tmp/x.yml"])
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        .and output(/invalid name 'BAD NAME'/).to_stderr
    end
  end

  describe "--log-file validation" do
    it "errors when --log-file is passed to a command that doesn't support it" do
      expect {
        Ctree::CLI.run(["list", "--log-file=/tmp/ctree.log"])
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        .and output(/--log-file is only supported for create, delete, rebase, update/).to_stderr
    end

    it "errors when --log-file is given without a path" do
      expect {
        Ctree::CLI.run(["create", "wt1", "branch1", "--log-file="])
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        .and output(/--log-file requires a path/).to_stderr
    end

    it "errors when the log file's parent directory doesn't exist" do
      expect {
        Ctree::CLI.run(["create", "wt1", "branch1", "--log-file=/no/such/dir/ctree.log"])
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        .and output(/parent directory does not exist or is not writable/).to_stderr
    end
  end

  describe ".with_logging" do
    after { Ctree::LogFile.reset! }

    def capture_stdout
      original = $stdout
      $stdout = StringIO.new
      yield
      $stdout.string
    ensure
      $stdout = original
    end

    it "replaces the progress line with the past-tense done message and elapsed time on success" do
      Dir.mktmpdir do |dir|
        log_path = File.join(dir, "ctree.log")
        output = capture_stdout do
          expect { Ctree::CLI.with_logging(log_path, "doing thing", "did thing") { exit 0 } }
            .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
        end
        expect(output).to match(/did thing \(\d+s\)/)
      end
    end

    it "prints no extra console line when the block exits non-zero — same as without --log-file" do
      Dir.mktmpdir do |dir|
        log_path = File.join(dir, "ctree.log")
        output = capture_stdout do
          expect { Ctree::CLI.with_logging(log_path, "doing thing", "did thing") { exit 2 } }
            .to raise_error(SystemExit) { |e| expect(e.status).to eq(2) }
        end
        expect(output).not_to include("did thing")
      end
    end

    it "still surfaces the SystemExit status from the block" do
      Dir.mktmpdir do |dir|
        log_path = File.join(dir, "ctree.log")
        capture_stdout do
          expect { Ctree::CLI.with_logging(log_path, "doing thing", "did thing") { Ctree::Log.die("boom") } }
            .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        end
      end
    end
  end
end
