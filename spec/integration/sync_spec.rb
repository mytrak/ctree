# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "stringio"

RSpec.describe "Ctree::CLI sync" do
  around do |ex|
    Dir.mktmpdir do |parent_dir|
      @parent = Pathname.new(parent_dir).realpath
      @work = @parent / "src"
      FileUtils.mkdir_p(@work.to_s)
      Dir.chdir(@work) { ex.run }
    end
  end

  before do
    system("git", "init", "-q", "-b", "main", out: File::NULL, err: File::NULL)
    system("git", "config", "user.email", "test@example.com")
    system("git", "config", "user.name", "Test")
    File.write(".env", "COMPOSE_PROJECT_NAME=src\n")
    system("git", "add", ".env", out: File::NULL, err: File::NULL)
    system("git", "commit", "-q", "-m", "init", out: File::NULL, err: File::NULL)
  end

  it "runs rebase then update" do
    # Stub Rebase and Update to verify they are called
    allow(Ctree::Rebase).to receive(:run).and_return(0)
    allow(Ctree::Update).to receive(:run).and_return(0)

    Dir.chdir(@work.to_s) do
      Ctree::CLI.run(["sync"])
    end
    expect(Ctree::Rebase).to have_received(:run)
    expect(Ctree::Update).to have_received(:run)
  end

  it "stops if rebase fails" do
    allow(Ctree::Rebase).to receive(:run).and_raise(SystemExit.new(2))
    allow(Ctree::Update).to receive(:run)

    Dir.chdir(@work.to_s) do
      expect { Ctree::CLI.run(["sync"]) }.to raise_error(SystemExit)
    end
    expect(Ctree::Update).not_to have_received(:run)
  end

  it "executes post_rebase_hooks if they exist" do
    # Ctree::Rebase.run rebases onto the source's local "master" branch by
    # name, so the source needs one in addition to its default "main".
    system("git", "branch", "master")

    wt = @parent / "wt1"
    system("git", "worktree", "add", "-q", "-b", "feature-x", wt.to_s, out: File::NULL, err: File::NULL)

    FileUtils.mkdir_p((wt / ".ctree").to_s)
    File.write((wt / ".ctree" / "config.yml").to_s, "post_rebase_hooks:\n  - touch hook_ran\n")
    system("git", "-C", wt.to_s, "add", ".ctree/config.yml", out: File::NULL, err: File::NULL)
    system("git", "-C", wt.to_s, "commit", "-q", "-m", "add config", out: File::NULL, err: File::NULL)

    # Let the real Rebase.run execute (it's what runs the hooks); only
    # swallow its mandatory exit and stub away Update, which needs docker.
    allow(Ctree::Rebase).to receive(:exit)
    allow(Ctree::Update).to receive(:run).and_return(0)

    Dir.chdir(wt.to_s) do
      Ctree::CLI.run(["sync"])
    end

    expect((wt / "hook_ran").exist?).to be true
  end

  it "redirects output to --log-file" do
    Dir.mktmpdir do |log_dir|
      log_path = File.join(log_dir, "sync.log")

      allow(Ctree::Rebase).to receive(:run).and_return(0)
      allow(Ctree::Update).to receive(:run).and_return(0)

      out = StringIO.new
      original_stdout = $stdout
      $stdout = out
      begin
        Dir.chdir(@work.to_s) do
          Ctree::CLI.run(["sync", "--log-file=#{log_path}"])
        end
      ensure
        $stdout = original_stdout
      end

      console_output = out.string
      expect(console_output).to include("syncing worktree")
      expect(console_output).to match(/synced worktree \(\d+s\)/)
    end
  end
end
