# frozen_string_literal: true

RSpec.describe "Ctree::CLI delete" do
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
    File.write("placeholder", "x")
    system("git", "add", ".", out: File::NULL, err: File::NULL)
    system("git", "commit", "-q", "-m", "init", out: File::NULL, err: File::NULL)
  end

  it "exits 0 with 'nothing to remove' when nothing exists for that name" do
    # docker info via Sh.system: not reachable -> docker_ok=false, no docker
    # capture3 calls follow.
    stub_sh(docker_capture3: [], docker_system: [false])

    expect {
      Ctree::CLI.run(["delete", "ghost"])
    }.to output(/nothing to remove for 'ghost'/).to_stdout
      .and raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
  end

  it "aborts when user does not type 'yes'" do
    # create a fake worktree dir so remove thinks there's something to do
    target = @parent / "ghost"
    FileUtils.mkdir_p(target.to_s)

    # Decline confirmation
    allow(Ctree::Prompt).to receive(:read_line).and_return("no")

    stub_sh(docker_capture3: [], docker_system: [false])

    expect {
      Ctree::CLI.run(["delete", "ghost"])
    }.to output(/aborted: confirmation not given/).to_stderr
      .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
  ensure
    FileUtils.rm_rf(target.to_s) if defined?(target) && target
  end

  describe "speedups" do
    it "batches docker volume rm into a single call across all volumes" do
      target = @parent / "ghost"
      FileUtils.mkdir_p(target.to_s)
      File.write((target / "file.txt").to_s, "x")

      allow(Ctree::Prompt).to receive(:read_line).and_return("yes")

      stub_sh(
        docker_system: [true],
        docker_capture3: [
          ["ghost_v1\nghost_v2\nghost_v3\n", "", true],   # docker volume ls
          ["", "", true],                                  # docker ps (no containers)
          ["", "", true],                                  # docker images (no tagged images)
          ["", "", true]                                   # docker volume rm v1 v2 v3 (batch)
        ]
      )

      capture_stdout do
        expect { Ctree::CLI.run(["delete", "ghost"]) }
          .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
      end

      expect(Ctree::Sh).to have_received(:capture3)
        .with("docker", "volume", "rm", "ghost_v1", "ghost_v2", "ghost_v3").once
    end

    it "renames the worktree dir and spawns a detached rm -rf rather than synchronously removing files" do
      target = @parent / "ghost"
      FileUtils.mkdir_p(target.to_s)
      File.write((target / "file.txt").to_s, "x")

      allow(Ctree::Prompt).to receive(:read_line).and_return("yes")
      stub_sh(docker_capture3: [], docker_system: [false])

      spawn_calls = []
      allow(Ctree::Sh).to receive(:spawn) do |*args, **kw|
        spawn_calls << [args, kw]
        99_999
      end
      allow(Ctree::Sh).to receive(:detach)

      output = capture_stdout do
        expect { Ctree::CLI.run(["delete", "ghost"]) }
          .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
      end

      expect(spawn_calls.size).to eq(1)
      args, kw = spawn_calls.first
      expect(args[0]).to eq("rm")
      expect(args[1]).to eq("-rf")
      expect(args[2]).to start_with(target.to_s + ".ctree-destroying-")
      expect(kw[:pgroup]).to be true

      expect(target).not_to exist
      quarantined = @parent.children.find { |p| p.basename.to_s.start_with?("ghost.ctree-destroying-") }
      expect(quarantined).not_to be_nil
      expect(output).to include("worktree dir renamed")
      expect(output).to include("queued background worktree dir delete job (pid 99999)")
    end

    it "falls back to synchronous git worktree remove when rename raises EXDEV" do
      target = @parent / "ghost"
      FileUtils.mkdir_p(target.to_s)

      allow(Ctree::Prompt).to receive(:read_line).and_return("yes")
      stub_sh(docker_capture3: [], docker_system: [false])

      allow(File).to receive(:rename).and_raise(Errno::EXDEV, "simulated cross-fs rename")

      capture_stdout do
        expect { Ctree::CLI.run(["delete", "ghost"]) }
          .to output(/falling back to synchronous removal/).to_stderr
          .and raise_error(SystemExit)
      end

      # Since git worktree remove and rm_rf both target a path that
      # isn't actually registered as a git worktree, they'll fail too;
      # the test just verifies the EXDEV path was reached.
    end
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end
end
