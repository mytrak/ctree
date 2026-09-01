# frozen_string_literal: true

RSpec.describe Ctree::EnvCmd do
  around do |ex|
    Dir.mktmpdir do |src|
      Dir.mktmpdir do |tgt|
        @source = Pathname.new(src).realpath
        @target = Pathname.new(tgt).realpath
        ex.run
      end
    end
  end

  before do
    allow(Ctree::EnvCmd).to receive(:resolve_worktree!).and_return([@target, @source])
    allow(Ctree::Config).to receive(:load).and_return(
      Ctree::Config.defaults.merge(skip_env_keys: ["SKIP_ME"])
    )
  end

  def write_env(path, vars)
    File.write(path.to_s, vars.map { |k, v| "#{k}=#{v}" }.join("\n") + "\n")
  end

  describe ".run list" do
    it "prints each key=value from worktree .env" do
      write_env(@source / ".env", "FOO" => "bar")
      write_env(@target / ".env", "FOO" => "bar", "BAZ" => "qux")
      expect { Ctree::EnvCmd.run("list") }
        .to raise_error(SystemExit)
        .and output(/BAZ=qux/).to_stdout
    end

    it "does not print [missing] annotations" do
      write_env(@source / ".env", "FOO" => "bar", "EXTRA" => "x")
      write_env(@target / ".env", "FOO" => "bar")
      expect { Ctree::EnvCmd.run("list") }
        .to raise_error(SystemExit)
        .and output(/\AFOO=bar\n\z/).to_stdout
    end

    it "dies when worktree .env is missing" do
      write_env(@source / ".env", "FOO" => "bar")
      expect { Ctree::EnvCmd.run("list") }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        .and output(/no \.env/).to_stderr
    end

    it "dies when source .env is missing" do
      write_env(@target / ".env", "FOO" => "bar")
      expect { Ctree::EnvCmd.run("list") }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        .and output(/no \.env/).to_stderr
    end
  end

  describe ".run check" do
    it "exits 0 when source and worktree have the same keys" do
      write_env(@source / ".env", "FOO" => "bar")
      write_env(@target / ".env", "FOO" => "bar")
      expect { Ctree::EnvCmd.run("check") }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
        .and output(/in sync/).to_stdout
    end

    it "prints [missing] KEY for each key in source absent from worktree and exits 1" do
      write_env(@source / ".env", "FOO" => "bar", "MISSING_KEY" => "x")
      write_env(@target / ".env", "FOO" => "bar")
      expect { Ctree::EnvCmd.run("check") }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        .and output(/\[missing\] MISSING_KEY/).to_stdout
    end

    it "reports skip_env_keys as [missing] when absent from worktree" do
      write_env(@source / ".env", "FOO" => "bar", "SKIP_ME" => "x")
      write_env(@target / ".env", "FOO" => "bar")
      expect { Ctree::EnvCmd.run("check") }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        .and output(/\[missing\] SKIP_ME/).to_stdout
    end

    it "prints [extra] KEY for keys in worktree absent from source and exits 1" do
      write_env(@source / ".env", "FOO" => "bar")
      write_env(@target / ".env", "FOO" => "bar", "EXTRA_KEY" => "x")
      expect { Ctree::EnvCmd.run("check") }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        .and output(/\[extra\] EXTRA_KEY/).to_stdout
    end

    it "does not report ctree-managed keys as [extra]" do
      write_env(@source / ".env", "FOO" => "bar")
      write_env(@target / ".env", "FOO" => "bar",
                                  "COMPOSE_PROJECT_NAME" => "example-two",
                                  "HOST_NAME" => "example-two")
      expect { Ctree::EnvCmd.run("check") }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
        .and output(/in sync/).to_stdout
    end

    it "does not report skip_env_keys as [extra] when present only in worktree" do
      write_env(@source / ".env", "FOO" => "bar")
      write_env(@target / ".env", "FOO" => "bar", "SKIP_ME" => "x")
      expect { Ctree::EnvCmd.run("check") }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
        .and output(/in sync/).to_stdout
    end
  end

  describe ".run fix" do
    it "exits 0 with nothing to fix when source and worktree have the same keys" do
      write_env(@source / ".env", "FOO" => "bar")
      write_env(@target / ".env", "FOO" => "bar")
      expect { Ctree::EnvCmd.run("fix") }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
        .and output(/nothing to fix/).to_stdout
    end

    it "applies source values to missing keys and keeps orphaned keys without prompting under force" do
      write_env(@source / ".env", "NEW_KEY" => "src_val")
      write_env(@target / ".env", "OLD_KEY" => "old_val")
      expect(Ctree::Prompt).not_to receive(:read_line)
      expect { Ctree::EnvCmd.run("fix", force: true) }.to raise_error(SystemExit)
      env = Ctree::EnvFile.parse((@target / ".env").to_s)
      expect(env["NEW_KEY"]).to eq("src_val")
      expect(env).to have_key("OLD_KEY")
    end

    it "does not prompt for keys already present in the worktree" do
      write_env(@source / ".env", "FOO" => "src_foo")
      write_env(@target / ".env", "FOO" => "wt_foo")
      expect(Ctree::Prompt).not_to receive(:for_env_var_change)
      expect { Ctree::EnvCmd.run("fix") }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
    end

    it "prompts for missing keys with source value as default" do
      write_env(@source / ".env", "NEW_KEY" => "src_val")
      write_env(@target / ".env", {})
      allow(Ctree::Prompt).to receive(:for_env_var_change)
        .with("NEW_KEY", "src_val", force: false).and_return("src_val")
      expect { Ctree::EnvCmd.run("fix") }.to raise_error(SystemExit)
      expect(Ctree::EnvFile.parse((@target / ".env").to_s)["NEW_KEY"]).to eq("src_val")
    end

    it "writes the user-modified value when the user changes the default" do
      write_env(@source / ".env", "NEW_KEY" => "src_val")
      write_env(@target / ".env", {})
      allow(Ctree::Prompt).to receive(:for_env_var_change)
        .with("NEW_KEY", "src_val", force: false).and_return("my_val")
      expect { Ctree::EnvCmd.run("fix") }.to raise_error(SystemExit)
      expect(Ctree::EnvFile.parse((@target / ".env").to_s)["NEW_KEY"]).to eq("my_val")
    end

    it "offers to delete an orphaned key and removes it when user confirms" do
      write_env(@source / ".env", {})
      write_env(@target / ".env", "OLD_KEY" => "old_val")
      allow(Ctree::Prompt).to receive(:read_line)
        .with(/OLD_KEY.*delete.*\[y\/N\]/i).and_return("y")
      expect { Ctree::EnvCmd.run("fix") }.to raise_error(SystemExit)
      expect(Ctree::EnvFile.parse((@target / ".env").to_s).key?("OLD_KEY")).to be false
    end

    it "keeps an orphaned key when user declines deletion" do
      write_env(@source / ".env", {})
      write_env(@target / ".env", "OLD_KEY" => "old_val")
      allow(Ctree::Prompt).to receive(:read_line)
        .with(/OLD_KEY.*delete.*\[y\/N\]/i).and_return("n")
      expect { Ctree::EnvCmd.run("fix") }.to raise_error(SystemExit)
      expect(Ctree::EnvFile.parse((@target / ".env").to_s)["OLD_KEY"]).to eq("old_val")
    end

    it "prompts for missing skip_env_keys with source value as default" do
      write_env(@source / ".env", "FOO" => "bar", "SKIP_ME" => "x")
      write_env(@target / ".env", {})
      allow(Ctree::Prompt).to receive(:for_env_var_change)
        .with("FOO", "bar", force: false).and_return("bar")
      allow(Ctree::Prompt).to receive(:for_env_var_change)
        .with("SKIP_ME", "x", force: false).and_return("x")
      expect { Ctree::EnvCmd.run("fix") }.to raise_error(SystemExit)
    end

    it "does not offer to delete orphaned skip_env_keys" do
      write_env(@source / ".env", {})
      write_env(@target / ".env", "SKIP_ME" => "x")
      expect(Ctree::Prompt).not_to receive(:read_line)
      expect { Ctree::EnvCmd.run("fix") }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
        .and output(/nothing to fix/).to_stdout
    end

    it "does not offer to delete ctree-managed keys (COMPOSE_PROJECT_NAME, HOST_NAME)" do
      write_env(@source / ".env", {})
      write_env(@target / ".env", "COMPOSE_PROJECT_NAME" => "example-two", "HOST_NAME" => "example-two")
      expect(Ctree::Prompt).not_to receive(:read_line)
      expect { Ctree::EnvCmd.run("fix") }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
        .and output(/nothing to fix/).to_stdout
    end

    it "excludes HOST_NAME_SUFFIX when host_name_suffix config is non-empty" do
      allow(Ctree::Config).to receive(:load).and_return(
        Ctree::Config.defaults.merge(skip_env_keys: [], host_name_suffix: "docker")
      )
      write_env(@source / ".env", {})
      write_env(@target / ".env", "HOST_NAME_SUFFIX" => "docker")
      expect(Ctree::Prompt).not_to receive(:read_line)
      expect { Ctree::EnvCmd.run("fix") }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
        .and output(/nothing to fix/).to_stdout
    end
  end

  describe ".run with a custom env_filename" do
    before do
      allow(Ctree::Config).to receive(:load).and_return(
        Ctree::Config.defaults.merge(skip_env_keys: ["SKIP_ME"], env_filename: ".env.custom")
      )
    end

    it "list reads the configured file instead of .env" do
      write_env(@source / ".env.custom", "FOO" => "bar")
      write_env(@target / ".env.custom", "FOO" => "bar", "BAZ" => "qux")
      expect { Ctree::EnvCmd.run("list") }
        .to raise_error(SystemExit)
        .and output(/BAZ=qux/).to_stdout
    end

    it "list dies naming the configured file when it's missing" do
      expect { Ctree::EnvCmd.run("list") }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        .and output(/no \.env\.custom/).to_stderr
    end

    it "check reports discrepancies from the configured file" do
      write_env(@source / ".env.custom", "FOO" => "bar", "NEW_KEY" => "1")
      write_env(@target / ".env.custom", "FOO" => "bar")
      expect { Ctree::EnvCmd.run("check") }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        .and output(/\[missing\] NEW_KEY/).to_stdout
    end

    it "fix writes missing keys into the configured file" do
      write_env(@source / ".env.custom", "FOO" => "bar", "NEW_KEY" => "1")
      write_env(@target / ".env.custom", "FOO" => "bar")
      allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
      expect { Ctree::EnvCmd.run("fix") }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
      expect((@target / ".env.custom").read).to include("NEW_KEY=1")
    end
  end
end
