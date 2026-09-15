# frozen_string_literal: true

require "spec_helper"
require "fileutils"

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
      expect { Ctree::CLI.run(["sync"]) }.to raise_error(SystemExit)
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
    # Setup config with hooks
    FileUtils.mkdir_p((@work / ".ctree").to_s)
    File.write((@work / ".ctree" / "config.yml").to_s, "post_rebase_hooks:\n  - touch hook_ran\n")

    # Create a commit in the worktree to make it have something to rebase onto
    (Pathname.pwd / "test2.txt").write("content2")
    Sh.system("git", "-C", Pathname.pwd.to_s, "add", "test2.txt")
    Sh.system("git", "-C", Pathname.pwd.to_s, "commit", "-m", "Add test file 2")

    Dir.chdir(@work.to_s) do
      allow(Ctree::Rebase).to receive(:run).and_return(0)
      allow(Ctree::Update).to receive(:run).and_return(0)
      Ctree::CLI.run(["sync"])
    end

    expect((@work / "hook_ran").exist?).to be true
  end

  it "redirects output to --log-file" do
    Dir.mktmpdir do |log_dir|
      log_path = File.join(log_dir, "sync.log")

      # Setup worktree with some basic commits
      (Pathname.pwd / "test2.txt").write("content2")
      Sh.system("git", "-C", Pathname.pwd.to_s, "add", "test2.txt")
      Sh.system("git", "-C", Pathname.pwd.to_s, "commit", "-m", "Add test file 2")

      Dir.chdir(@work.to_s) do
        Ctree::CLI.run(["sync", "--log-file=#{log_path}"])
      end

      expect(File.read(log_path)).to include("syncing worktree")
    end
  end
end