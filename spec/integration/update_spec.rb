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
    # Restore the source worktree to its default branch — the feature-branch
    # checkout above would otherwise leak into specs that run after this one.
    system("git", "-C", @work.to_s, "checkout", "-q", "main",
           out: File::NULL, err: File::NULL)
  end

  it "aborts without prompting when --force is passed and the source is on a feature branch (prompt defaults to no)" do
    wt = @parent / "wt1"
    system("git", "-C", @work.to_s, "worktree", "add", "-q", "-b", "wt1", wt.to_s,
           out: File::NULL, err: File::NULL)
    File.write((wt / ".env").to_s, "COMPOSE_PROJECT_NAME=wt1\n")
    system("git", "-C", @work.to_s, "checkout", "-q", "-b", "feature-x",
           out: File::NULL, err: File::NULL)

    expect(Ctree::Prompt).not_to receive(:read_line)
    stub_sh(
      docker_system: [true],
      docker_capture3: [
        ["src-web\tsha256:AAA\n", "", true],   # source image ids
        ["", "", true]                          # worktree image ids (none -> stale)
      ]
    )

    Dir.chdir(wt.to_s) do
      expect {
        Ctree::CLI.run(["update", "--force"])
      }.to output(/source repo is on branch 'feature-x'/).to_stderr
        .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end
  ensure
    if defined?(wt) && wt
      system("git", "-C", @work.to_s, "worktree", "remove", "--force", wt.to_s,
             out: File::NULL, err: File::NULL)
    end
    # Restore the source worktree to its default branch — the feature-branch
    # checkout above would otherwise leak into specs that run after this one.
    system("git", "-C", @work.to_s, "checkout", "-q", "main",
           out: File::NULL, err: File::NULL)
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

  it "writes full output to the log file and keeps the console minimal when --log-file is given" do
    wt = @parent / "wt1"
    system("git", "-C", @work.to_s, "worktree", "add", "-q", "-b", "wt1", wt.to_s,
           out: File::NULL, err: File::NULL)
    File.write((wt / ".env").to_s, "COMPOSE_PROJECT_NAME=wt1\n")

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

    Dir.mktmpdir do |log_dir|
      log_path = File.join(log_dir, "ctree.log")

      Dir.chdir(wt.to_s) do
        console_output = capture_stdout do
          expect { Ctree::CLI.run(["update", "--log-file=#{log_path}"]) }
            .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
        end
        expect(console_output).to include("updating worktree")
        expect(console_output).to match(/updated worktree \(\d+s\)/)
      end

      log_content = File.read(log_path)
      expect(log_content).to include("updating worktree wt1 from src")
      expect(log_content).to match(/worktree:\s+#{Regexp.escape(wt.realpath.to_s)}/)
      expect(log_content).to match(/source:\s+#{Regexp.escape(@work.realpath.to_s)}/)
    end
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

  it "prints debug summary header" do
    FileUtils.mkdir_p((@work / ".ctree").to_s)
    File.write((@work / ".ctree" / "config.yml").to_s, "log_level: debug\n")
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
        ["", "", true],  # docker ps source
        ["", "", true],  # docker ps target
        ["", "", true],  # Images.tag_to_target
        ["", "", true],  # docker volume ls
      ]
    )

    Dir.chdir(wt.to_s) do
      expect { Ctree::CLI.run(["update"]) }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
        .and output(/=== update summary ===/).to_stdout
    end
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
        .and output(/\[empty  \].*src_log.*->.*wt1_log.*\(empty volume\)/).to_stdout
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
        .and output(/\[empty  \].*src_log.*->.*wt1_log.*\(empty volume\)/).to_stdout
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

  it "dies on failing post-update hook with error output" do
    wt = @parent / "wt1"
    system("git", "-C", @work.to_s, "worktree", "add", "-q", "-b", "wt1", wt.to_s,
           out: File::NULL, err: File::NULL)
    File.write((wt / ".env").to_s, "COMPOSE_PROJECT_NAME=wt1\n")
    FileUtils.mkdir_p((wt / ".ctree").to_s)
    File.write(
      (wt / ".ctree" / "config.yml").to_s,
      "post_update_hooks:\n  - /bin/sh -c 'echo DISK FULL >&2; exit 1'\n",
    )
    system("git", "-C", @work.to_s, "add", ".ctree/config.yml", out: File::NULL, err: File::NULL)
    system("git", "-C", @work.to_s, "commit", "-q", "-m", "add config", out: File::NULL, err: File::NULL)

    allow(Ctree::Rebase).to receive(:exit)

    stub_sh(
      docker_system: [true, true],
      docker_capture3: [
        ["", "", true],   # docker ps source (no containers)
        ["", "", true],   # docker ps target (no containers)
        ["", "", true],   # docker images
        ["", "", true],   # docker volume ls (no source volumes)
      ]
    )

    Dir.chdir(wt.to_s) do
      expect {
        Ctree::CLI.run(["update"])
      }.to output(/DISK FULL/).to_stderr
        .and raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end
  ensure
    if defined?(wt) && wt
      system("git", "-C", @work.to_s, "worktree", "remove", "--force", wt.to_s,
             out: File::NULL, err: File::NULL)
    end
  end

  it "writes full failing hook output to --log-file" do
    Dir.mktmpdir do |log_dir|
      log_path = File.join(log_dir, "update.log")

      wt = @parent / "wt_ulog"
      system("git", "-C", @work.to_s, "worktree", "add", "-q", "-b", "wt-ulog", wt.to_s,
             out: File::NULL, err: File::NULL)
      File.write((wt / ".env").to_s, "COMPOSE_PROJECT_NAME=wt-ulog\n")
      FileUtils.mkdir_p((wt / ".ctree").to_s)
      File.write(
        (wt / ".ctree" / "config.yml").to_s,
        "post_update_hooks:\n" \
        "  - /bin/sh -c 'echo POST UPDATE CRASHED >&2; echo stack trace here; exit 1'\n",
      )
      # Track the config on the worktree's own branch — otherwise the worktree
      # checkout (branched from main before this commit) lacks .ctree/config.yml
      # and the default config (log_level: info, no hooks) governs the update.
      system("git", "-C", wt.to_s, "add", ".ctree/config.yml", out: File::NULL, err: File::NULL)
      system("git", "-C", wt.to_s, "commit", "-q", "-m", "add config", out: File::NULL, err: File::NULL)

      allow(Ctree::Rebase).to receive(:exit)

      stub_sh(
        docker_system: [true, true],
        docker_capture3: [
          ["", "", true],   # docker ps source (no containers)
          ["", "", true],   # docker ps target (no containers)
          ["", "", true],   # docker images
          ["", "", true],   # docker volume ls (no source volumes)
        ]
      )

      Dir.chdir(wt.to_s) do
        expect {
          Ctree::CLI.run(["update", "--log-file=#{log_path}"])
        }.to raise_error(SystemExit)
      end

      log_content = File.read(log_path)
      expect(log_content).to include("POST UPDATE CRASHED")
      expect(log_content).to include("stack trace here")
      expect(log_content).to include("post-update hook failed")
    ensure
      if defined?(wt) && wt
        system("git", "-C", @work.to_s, "worktree", "remove", "--force", wt.to_s,
               out: File::NULL, err: File::NULL)
      end
    end
  end

    it "runs post-update hooks without spinner redraws interleaving hook output" do
      wt = @parent / "wt_hooks"
      system("git", "-C", @work.to_s, "worktree", "add", "-q", "-b", "wt-hooks", wt.to_s,
             out: File::NULL, err: File::NULL)
      File.write((wt / ".env").to_s, "COMPOSE_PROJECT_NAME=wt-hooks\n")
      FileUtils.mkdir_p((wt / ".ctree").to_s)
      File.write(
        (wt / ".ctree" / "config.yml").to_s,
        "post_update_hooks:\n  - /bin/sh -c 'echo line one; echo line two'\n",
      )
      system("git", "-C", wt.to_s, "add", ".ctree/config.yml", out: File::NULL, err: File::NULL)
      system("git", "-C", wt.to_s, "commit", "-q", "-m", "add config", out: File::NULL, err: File::NULL)

      allow(Ctree::Rebase).to receive(:exit)
      stub_sh(
        docker_system: [true, true],
        docker_capture3: [
          ["", "", true], # docker ps source
          ["", "", true], # docker ps target
          ["", "", true], # docker images
          ["", "", true], # docker volume ls
        ]
      )

      Dir.chdir(wt.to_s) do
        captured = capture_stdout do
          expect { Ctree::CLI.run(["update"]) }
            .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
        end

        expect(captured).to include("running post-update hook 1/1:")
        expect(captured).to include("line one")
        expect(captured).to include("line two")
        # No rotating frames, elapsed redraws, or line-erase sequences:
        expect(captured).not_to include("\r")
      end
    ensure
      if defined?(wt) && wt
        system("git", "-C", @work.to_s, "worktree", "remove", "--force", wt.to_s,
               out: File::NULL, err: File::NULL)
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

  describe "sizes in the log file" do
    let(:rsync_stats) do
      "Total file size: 43,433,984 bytes\nTotal transferred file size: 1,024 bytes\n"
    end

    def update_log_for(config_yaml:, docker_capture3:)
      FileUtils.mkdir_p((@work / ".ctree").to_s)
      File.write((@work / ".ctree" / "config.yml").to_s, config_yaml)
      system("git", "-C", @work.to_s, "add", ".ctree", out: File::NULL, err: File::NULL)
      system("git", "-C", @work.to_s, "commit", "-q", "--amend", "--no-edit",
             out: File::NULL, err: File::NULL)

      wt = @parent / "wt_timing"
      system("git", "-C", @work.to_s, "worktree", "add", "-q", "-b", "wt-timing", wt.to_s,
             out: File::NULL, err: File::NULL)
      File.write((wt / ".env").to_s, "COMPOSE_PROJECT_NAME=wt_timing\n")

      stub_sh(docker_system: [true], docker_capture3: docker_capture3)

      Dir.mktmpdir do |log_dir|
        log_path = File.join(log_dir, "ctree.log")
        Dir.chdir(wt.to_s) do
          expect { Ctree::CLI.run(["update", "--log-file=#{log_path}"]) }
            .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
        end
        File.read(log_path)
      end
    ensure
      if defined?(wt) && wt
        system("git", "-C", @work.to_s, "worktree", "remove", "--force", wt.to_s,
               out: File::NULL, err: File::NULL)
      end
    end

    def volume_capture3
      [
        ["", "", true],
        ["", "", true],
        ["", "", true],
        ["src_locales\n", "", true],
        ["", "", true],
        ["", "", true],
        [rsync_stats, "", true],
      ]
    end

    def no_volume_capture3
      [["", "", true], ["", "", true], ["", "", true], ["", "", true]]
    end

    it "logs the size of each updated volume and an aggregate line" do
      log = update_log_for(config_yaml: "update_volumes:\n  - locales\n", docker_capture3: volume_capture3)

      expect(log).to match(/updated src_locales -> wt_timing_locales \(41\.4MB\)/)
      expect(log).to match(/updated 1 volume \(41\.4MB\)/)
    end

    it "logs each updated volume exactly once in debug mode and omits the aggregate" do
      log = update_log_for(
        config_yaml: "update_volumes:\n  - locales\nlog_level: debug\n",
        docker_capture3: volume_capture3,
      )

      expect(log.scan("updated src_locales -> wt_timing_locales").size).to eq(1)
      expect(log).to match(/updated src_locales -> wt_timing_locales \(41\.4MB\)/)
      expect(log).not_to match(/updated 1 volume/)
    end

    def update_console_for(config_yaml:)
      FileUtils.mkdir_p((@work / ".ctree").to_s)
      File.write((@work / ".ctree" / "config.yml").to_s, config_yaml)
      system("git", "-C", @work.to_s, "add", ".ctree", out: File::NULL, err: File::NULL)
      system("git", "-C", @work.to_s, "commit", "-q", "--amend", "--no-edit",
             out: File::NULL, err: File::NULL)
      wt = @parent / "wt_console"
      system("git", "-C", @work.to_s, "worktree", "add", "-q", "-b", "wt-console", wt.to_s,
             out: File::NULL, err: File::NULL)
      File.write((wt / ".env").to_s, "COMPOSE_PROJECT_NAME=wt_console\n")
      stub_sh(docker_system: [true], docker_capture3: volume_capture3)

      Dir.chdir(wt.to_s) do
        capture_stdout do
          expect { Ctree::CLI.run(["update"]) }
            .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
        end
      end
    ensure
      if defined?(wt) && wt
        system("git", "-C", @work.to_s, "worktree", "remove", "--force", wt.to_s,
               out: File::NULL, err: File::NULL)
      end
    end

    it "prints the per-volume line with its size on the console in debug mode without a log file" do
      console = update_console_for(config_yaml: "update_volumes:\n  - locales\nlog_level: debug\n")

      expect(console.scan("updated src_locales -> wt_console_locales").size).to eq(1)
      expect(console).to match(/updated src_locales -> wt_console_locales \(41\.4MB\)/)
    end

    it "prints only the aggregate volume line on the console at info level without a log file" do
      console = update_console_for(config_yaml: "update_volumes:\n  - locales\n")

      expect(console).not_to include("updated src_locales -> wt_console_locales")
      expect(console).to match(/updated 1 volume \(41\.4MB\)/)
    end

    it "logs the stack stops without an elapsed time" do
      log = update_log_for(
        config_yaml: "log_level: info\n",
        docker_capture3: [
          ["abc\n", "", true],
          ["", "", true],
          ["def\n", "", true],
          ["", "", true],
          ["", "", true],
          ["", "", true],
        ],
      )

      expect(log).to match(/stopped source compose stack$/)
      expect(log).to match(/stopped worktree compose stack$/)
    end

    it "logs the combined size of the updated files and directories at info level" do
      File.write((@work / "sample.lock").to_s, "x" * 2048)
      FileUtils.mkdir_p((@work / "assets" / "sub").to_s)
      File.write((@work / "assets" / "a.bin").to_s, "x" * 1024)
      File.write((@work / "assets" / "sub" / "b.bin").to_s, "x" * 1024)

      log = update_log_for(
        config_yaml: "update:\n  - sample.lock\n  - assets\n",
        docker_capture3: no_volume_capture3,
      )

      expect(log).to match(/updated 2 files \(4\.0KB\)/)
    end

    it "logs the size of each updated file and directory in debug mode" do
      File.write((@work / "sample.lock").to_s, "x" * 2048)
      FileUtils.mkdir_p((@work / "assets" / "sub").to_s)
      File.write((@work / "assets" / "a.bin").to_s, "x" * 1024)
      File.write((@work / "assets" / "sub" / "b.bin").to_s, "x" * 1024)

      log = update_log_for(
        config_yaml: "update:\n  - sample.lock\n  - assets\nlog_level: debug\n",
        docker_capture3: no_volume_capture3,
      )

      expect(log).to match(/updated sample\.lock \(2\.0KB\)$/)
      expect(log).to match(/updated assets\/ \(2\.0KB\)$/)
      expect(log).not_to match(/updated 2 files/)
    end
  end

  it "does not write update summary block to the log file" do
    FileUtils.mkdir_p((@work / ".ctree").to_s)
    File.write((@work / ".ctree" / "config.yml").to_s, "log_level: debug\n")

    stub_sh(
      docker_system: [true],
      docker_capture3: [
        ["", "", true],   # docker info
        ["", "", true],   # docker ps source
        ["", "", true],   # docker ps target
        ["", "", true],   # docker images source
        ["", "", true],   # docker images target
        ["", "", true],   # docker volume ls
      ]
    )

    Dir.mktmpdir do |log_dir|
      log_path = File.join(log_dir, "ctree.log")
      wt = @parent / "wt_update_summary"
      system("git", "-C", @work.to_s, "worktree", "add", "-q", "-b", "wt_update_summary", wt.to_s,
             out: File::NULL, err: File::NULL)
      File.write((wt / ".env").to_s, "COMPOSE_PROJECT_NAME=wt_update_summary\n")

      Dir.chdir(wt.to_s) do
        expect {
          Ctree::CLI.run(["update", "--log-file=#{log_path}"])
        }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }

        expect(File.read(log_path)).not_to match(/=== update summary ===/)
      end
    ensure
      Ctree::LogFile.reset!
      if defined?(wt) && wt
        system("git", "-C", @work.to_s, "worktree", "remove", "--force", wt.to_s,
               out: File::NULL, err: File::NULL)
      end
    end
  end
end
