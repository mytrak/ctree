# frozen_string_literal: true

RSpec.describe "Ctree::CLI update" do
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

  it "errors when run from the source project rather than a worktree" do
    expect {
      Ctree::CLI.run(["update"])
    }.to output(/already in the source project/).to_stderr
      .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
  end

  it "rejects extra arguments" do
    expect {
      Ctree::CLI.run(["update", "wt1"])
    }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
  end

  it "resolves the source from inside a worktree and exits 1 when docker is unreachable" do
    wt = @parent / "wt1"
    system("git", "-C", @work.to_s, "worktree", "add", "-q", "-b", "wt1", wt.to_s,
           out: File::NULL, err: File::NULL)
    File.write((wt / ".env").to_s, "COMPOSE_PROJECT_NAME=wt1\n")

    stub_sh(docker_system: [false], docker_capture3: [])

    Dir.chdir(wt.to_s) do
      expect {
        Ctree::CLI.run(["update"])
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end
  ensure
    if defined?(wt) && wt
      system("git", "-C", @work.to_s, "worktree", "remove", "--force", wt.to_s,
             out: File::NULL, err: File::NULL)
    end
  end

  it "exits with an error before updating when the override file is missing required external refs" do
    FileUtils.mkdir_p((@work / ".ctree").to_s)
    File.write((@work / ".ctree" / "config.yml").to_s,
               "share_volumes:\n  - gems\ncompose_override_file: docker-compose.local.ctree.yml\n")
    File.write((@work / "docker-compose.local.ctree.yml").to_s,
               "services:\n  web:\n    labels: []\n")
    system("git", "-C", @work.to_s, "add", ".ctree", "docker-compose.local.ctree.yml",
           out: File::NULL, err: File::NULL)
    system("git", "-C", @work.to_s, "commit", "-q", "--amend", "--no-edit",
           out: File::NULL, err: File::NULL)

    wt = @parent / "wt1"
    system("git", "-C", @work.to_s, "worktree", "add", "-q", "-b", "wt1", wt.to_s,
           out: File::NULL, err: File::NULL)
    File.write((wt / ".env").to_s, "COMPOSE_PROJECT_NAME=wt1\n")

    stub_sh(docker_system: [], docker_capture3: [])

    Dir.chdir(wt.to_s) do
      expect {
        Ctree::CLI.run(["update"])
      }.to output(/invalid ctree override file.*ctree compose-config fix/).to_stderr
        .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end
  ensure
    if defined?(wt) && wt
      system("git", "-C", @work.to_s, "worktree", "remove", "--force", wt.to_s,
             out: File::NULL, err: File::NULL)
    end
  end

  it "warns and aborts (default no) when the source is on a feature branch" do
    wt = @parent / "wt1"
    system("git", "-C", @work.to_s, "worktree", "add", "-q", "-b", "wt1", wt.to_s,
           out: File::NULL, err: File::NULL)
    File.write((wt / ".env").to_s, "COMPOSE_PROJECT_NAME=wt1\n")
    system("git", "-C", @work.to_s, "checkout", "-q", "-b", "feature-x",
           out: File::NULL, err: File::NULL)

    allow(Ctree::Prompt).to receive(:read_line).and_return("n")
    stub_sh(
      docker_system: [true],
      docker_capture3: [
        ["src-web\tsha256:AAA\n", "", true],   # source image ids
        ["", "", true]                          # worktree image ids (none -> stale)
      ]
    )

    Dir.chdir(wt.to_s) do
      expect {
        Ctree::CLI.run(["update"])
      }.to output(/source repo is on branch 'feature-x'/).to_stderr
        .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end
  ensure
    if defined?(wt) && wt
      system("git", "-C", @work.to_s, "worktree", "remove", "--force", wt.to_s,
             out: File::NULL, err: File::NULL)
    end
  end

  it "copies update file from source to worktree" do
    FileUtils.mkdir_p((@work / ".ctree").to_s)
    File.write((@work / ".ctree" / "config.yml").to_s,
               "update:\n  - lockfile.test\n")
    File.write((@work / ".gitignore").to_s, "lockfile.test\n")
    File.write((@work / "lockfile.test").to_s, "source-version")
    system("git", "-C", @work.to_s, "add", ".ctree", ".gitignore",
           out: File::NULL, err: File::NULL)
    system("git", "-C", @work.to_s, "commit", "-q", "--amend", "--no-edit",
           out: File::NULL, err: File::NULL)

    wt = @parent / "wt1"
    system("git", "-C", @work.to_s, "worktree", "add", "-q", "-b", "wt1", wt.to_s,
           out: File::NULL, err: File::NULL)
    File.write((wt / ".env").to_s, "COMPOSE_PROJECT_NAME=wt1\n")

    allow(Ctree::Prompt).to receive(:read_line).and_return("y")
    stub_sh(
      docker_system: [true],
      docker_capture3: [
        ["src-web\tsha256:AAA\n", "", true],
        ["", "", true],
        ["", "", true],
        ["", "", true],
        ["", "", true],
      ]
    )

    Dir.chdir(wt.to_s) do
      capture_stdout do
        expect { Ctree::CLI.run(["update"]) }
          .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
      end
    end

    expect((wt / "lockfile.test").read).to eq("source-version")
  ensure
    if defined?(wt) && wt
      system("git", "-C", @work.to_s, "worktree", "remove", "--force", wt.to_s,
             out: File::NULL, err: File::NULL)
    end
  end

  it "rsyncs update directory from source to worktree" do
    FileUtils.mkdir_p((@work / ".ctree").to_s)
    File.write((@work / ".ctree" / "config.yml").to_s,
               "update:\n  - shared_cache\n")
    FileUtils.mkdir_p((@work / "shared_cache").to_s)
    File.write((@work / "shared_cache" / "data.bin").to_s, "source-data")
    system("git", "-C", @work.to_s, "add", ".ctree",
           out: File::NULL, err: File::NULL)
    system("git", "-C", @work.to_s, "commit", "-q", "--amend", "--no-edit",
           out: File::NULL, err: File::NULL)

    wt = @parent / "wt1"
    system("git", "-C", @work.to_s, "worktree", "add", "-q", "-b", "wt1", wt.to_s,
           out: File::NULL, err: File::NULL)
    File.write((wt / ".env").to_s, "COMPOSE_PROJECT_NAME=wt1\n")

    allow(Ctree::Prompt).to receive(:read_line).and_return("y")
    stub_sh(
      docker_system: [true],
      docker_capture3: [
        ["src-web\tsha256:AAA\n", "", true],
        ["", "", true],
        ["", "", true],
        ["", "", true],
        ["", "", true],
      ]
    )

    Dir.chdir(wt.to_s) do
      capture_stdout do
        expect { Ctree::CLI.run(["update"]) }
          .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
      end
    end

    expect((wt / "shared_cache" / "data.bin").read).to eq("source-data")
  ensure
    if defined?(wt) && wt
      system("git", "-C", @work.to_s, "worktree", "remove", "--force", wt.to_s,
             out: File::NULL, err: File::NULL)
    end
  end

  it "skips a volume in empty_volumes during update" do
    FileUtils.mkdir_p((@work / ".ctree").to_s)
    File.write((@work / ".ctree" / "config.yml").to_s,
               "empty_volumes:\n  - log\nlog_level: debug\n")
    system("git", "-C", @work.to_s, "add", ".ctree",
           out: File::NULL, err: File::NULL)
    system("git", "-C", @work.to_s, "commit", "-q", "--amend", "--no-edit",
           out: File::NULL, err: File::NULL)

    wt = @parent / "wt1"
    system("git", "-C", @work.to_s, "worktree", "add", "-q", "-b", "wt1", wt.to_s,
           out: File::NULL, err: File::NULL)
    File.write((wt / ".env").to_s, "COMPOSE_PROJECT_NAME=wt1\n")

    stub_sh(
      docker_system: [true],
      docker_capture3: [
        ["", "", true],            # docker ps source
        ["", "", true],            # docker ps target
        ["", "", true],            # Images.tag_to_target
        ["src_log\n", "", true],  # docker volume ls
      ]
    )

    Dir.chdir(wt.to_s) do
      expect { Ctree::CLI.run(["update"]) }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
        .and output(/\[skipped\].*src_log.*->.*wt1_log.*\(empty volume\)/).to_stdout
    end
  ensure
    if defined?(wt) && wt
      system("git", "-C", @work.to_s, "worktree", "remove", "--force", wt.to_s,
             out: File::NULL, err: File::NULL)
    end
  end

  it "empty_volumes takes precedence over update_volumes" do
    FileUtils.mkdir_p((@work / ".ctree").to_s)
    File.write((@work / ".ctree" / "config.yml").to_s,
               "empty_volumes:\n  - log\nupdate_volumes:\n  - log\nlog_level: debug\n")
    system("git", "-C", @work.to_s, "add", ".ctree",
           out: File::NULL, err: File::NULL)
    system("git", "-C", @work.to_s, "commit", "-q", "--amend", "--no-edit",
           out: File::NULL, err: File::NULL)

    wt = @parent / "wt1"
    system("git", "-C", @work.to_s, "worktree", "add", "-q", "-b", "wt1", wt.to_s,
           out: File::NULL, err: File::NULL)
    File.write((wt / ".env").to_s, "COMPOSE_PROJECT_NAME=wt1\n")

    stub_sh(
      docker_system: [true],
      docker_capture3: [
        ["", "", true],            # docker ps source
        ["", "", true],            # docker ps target
        ["", "", true],            # Images.tag_to_target
        ["src_log\n", "", true],  # docker volume ls
      ]
    )

    Dir.chdir(wt.to_s) do
      expect { Ctree::CLI.run(["update"]) }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
        .and output(/\[skipped\].*src_log.*->.*wt1_log.*\(empty volume\)/).to_stdout
    end
  ensure
    if defined?(wt) && wt
      system("git", "-C", @work.to_s, "worktree", "remove", "--force", wt.to_s,
             out: File::NULL, err: File::NULL)
    end
  end

  it "does not copy compose_override_file even when listed in update:" do
    FileUtils.mkdir_p((@work / ".ctree").to_s)
    File.write((@work / ".ctree" / "config.yml").to_s,
               "compose_override_file: docker-compose.local.ctree.yml\n" \
               "update:\n  - docker-compose.local.ctree.yml\n")
    File.write((@work / "docker-compose.local.ctree.yml").to_s, "source-content")
    system("git", "-C", @work.to_s, "add", ".ctree", "docker-compose.local.ctree.yml",
           out: File::NULL, err: File::NULL)
    system("git", "-C", @work.to_s, "commit", "-q", "--amend", "--no-edit",
           out: File::NULL, err: File::NULL)

    wt = @parent / "wt1"
    system("git", "-C", @work.to_s, "worktree", "add", "-q", "-b", "wt1", wt.to_s,
           out: File::NULL, err: File::NULL)
    File.write((wt / ".env").to_s, "COMPOSE_PROJECT_NAME=wt1\n")
    File.write((wt / "docker-compose.local.ctree.yml").to_s, "worktree-content")

    stub_sh(
      docker_system: [true],
      docker_capture3: [
        ["", "", true],   # docker ps source
        ["", "", true],   # docker ps target
        ["", "", true],   # Images.tag_to_target (docker images)
        ["", "", true],   # docker volume ls
      ]
    )

    Dir.chdir(wt.to_s) do
      capture_stdout do
        expect { Ctree::CLI.run(["update"]) }
          .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
      end
    end

    expect((wt / "docker-compose.local.ctree.yml").read).to eq("worktree-content")
  ensure
    if defined?(wt) && wt
      system("git", "-C", @work.to_s, "worktree", "remove", "--force", wt.to_s,
             out: File::NULL, err: File::NULL)
    end
  end

  describe ".ctree exclusion" do
    it "skips .ctree even when listed in update:" do
      FileUtils.mkdir_p((@work / ".ctree").to_s)
      File.write((@work / ".ctree" / "config.yml").to_s,
                 "share_volumes:\n  - gems\n")
      File.write((@work / ".gitignore").to_s, ".ctree/\n")
      system("git", "-C", @work.to_s, "add", ".gitignore",
             out: File::NULL, err: File::NULL)
      system("git", "-C", @work.to_s, "commit", "-q", "--amend", "--no-edit",
             out: File::NULL, err: File::NULL)

      wt = @parent / "wt1"
      system("git", "-C", @work.to_s, "worktree", "add", "-q", "-b", "wt1", wt.to_s,
             out: File::NULL, err: File::NULL)
      File.write((wt / ".env").to_s, "COMPOSE_PROJECT_NAME=wt1\n")

      # Worktree config lists .ctree in update: — simulates user adding it
      FileUtils.mkdir_p((wt / ".ctree").to_s)
      File.write((wt / ".ctree" / "config.yml").to_s,
                 "update:\n  - .ctree\n")

      allow(Ctree::Prompt).to receive(:read_line).and_return("y")
      stub_sh(
        docker_system: [true],
        docker_capture3: [
          ["", "", true],
          ["", "", true],
          ["", "", true],
          ["", "", true],
        ]
      )

      Dir.chdir(wt.to_s) do
        capture_stdout do
          expect { Ctree::CLI.run(["update"]) }
            .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
        end
      end

      # .ctree/config.yml in the worktree should be unchanged
      expect((wt / ".ctree" / "config.yml").read).to eq(
        "update:\n  - .ctree\n"
      )
    ensure
      if defined?(wt) && wt
        system("git", "-C", @work.to_s, "worktree", "remove", "--force", wt.to_s,
               out: File::NULL, err: File::NULL)
      end
    end

    it "leaves hand-edited .ctree/config.yml untouched during update" do
      FileUtils.mkdir_p((@work / ".ctree").to_s)
      File.write((@work / ".ctree" / "config.yml").to_s,
                 "share_volumes:\n  - gems\n")
      File.write((@work / ".gitignore").to_s, ".ctree/\n")
      system("git", "-C", @work.to_s, "add", ".gitignore",
             out: File::NULL, err: File::NULL)
      system("git", "-C", @work.to_s, "commit", "-q", "--amend", "--no-edit",
             out: File::NULL, err: File::NULL)

      wt = @parent / "wt1"
      system("git", "-C", @work.to_s, "worktree", "add", "-q", "-b", "wt1", wt.to_s,
             out: File::NULL, err: File::NULL)
      File.write((wt / ".env").to_s, "COMPOSE_PROJECT_NAME=wt1\n")

      # Worktree config — simulate a user who hand-edited it after ctree create
      FileUtils.mkdir_p((wt / ".ctree").to_s)
      File.write((wt / ".ctree" / "config.yml").to_s,
                 "log_level: debug\n")

      allow(Ctree::Prompt).to receive(:read_line).and_return("y")
      stub_sh(
        docker_system: [true],
        docker_capture3: [
          ["", "", true],
          ["", "", true],
          ["", "", true],
          ["", "", true],
        ]
      )

      Dir.chdir(wt.to_s) do
        capture_stdout do
          expect { Ctree::CLI.run(["update"]) }
            .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
        end
      end

      # .ctree/config.yml is not touched — update doesn't handle .ctree at all
      expect((wt / ".ctree" / "config.yml").read).to eq(
        "log_level: debug\n"
      )
    ensure
      if defined?(wt) && wt
        system("git", "-C", @work.to_s, "worktree", "remove", "--force", wt.to_s,
               out: File::NULL, err: File::NULL)
      end
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
