# frozen_string_literal: true

RSpec.describe "Ctree::CLI create" do
  around do |ex|
    Dir.mktmpdir do |parent_dir|
      @parent = Pathname.new(parent_dir).realpath
      @work = @parent / "src"
      FileUtils.mkdir_p(@work.to_s)
      Dir.chdir(@work) { ex.run }
    end
  end

  before do
    system("git", "init", "-q", "-b", "master", out: File::NULL, err: File::NULL)
    system("git", "config", "user.email", "test@example.com")
    system("git", "config", "user.name", "Test")
    File.write(".env", "COMPOSE_PROJECT_NAME=src\nDB_PORT=5432\n")
    system("git", "add", ".env", out: File::NULL, err: File::NULL)
    system("git", "commit", "-q", "-m", "init", out: File::NULL, err: File::NULL)
  end

  # Stubs Clonefile to perform a real FileUtils.cp_r so the target directory
  # is properly populated for subsequent git/File operations.
  def stub_clonefile
    allow(Ctree::Clonefile).to receive(:available?).and_return(true)
    allow(Ctree::Clonefile).to receive(:clone) do |src, tgt|
      FileUtils.cp_r(src.to_s, tgt.to_s)
      true
    end
  end

  it "rejects an invalid worktree name" do
    expect {
      Ctree::CLI.run(["create", "Bad Name", "wt1"])
    }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
  end

  it "refuses to create a worktree of a worktree" do
    existing_wt = @parent / "existing-wt"
    system("git", "-C", @work.to_s, "worktree", "add", "-b", "existing-branch",
           existing_wt.to_s, out: File::NULL, err: File::NULL)

    Dir.chdir(existing_wt.to_s) do
      expect {
        Ctree::CLI.run(["create", "wt2", "wt2"])
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        .and output(/must be run from a source repo, not from a worktree/).to_stderr
    end

    system("git", "-C", @work.to_s, "worktree", "remove", "--force", existing_wt.to_s,
           out: File::NULL, err: File::NULL)
  end

  def docker_stubs
    [
      ["", "", true],   # docker info
      ["", "", true],   # docker ps source -- no running containers
      ["", "", true],   # docker images -- no source images to tag
      ["", "", true],   # docker volume ls -- no source volumes
      ["", "", true],   # docker volume ls -- pre-existing snapshot
      ["web\n", "", true], # docker compose config --services
      ["", "", true],   # docker compose up --no-start --no-build web
    ]
  end

  it "creates a sibling worktree on a new branch with updated .env" do
    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")
    stub_clonefile
    stub_sh(docker_capture3: docker_stubs)

    expect {
      Ctree::CLI.run(["create", "wt1", "wt1"])
    }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }

    sibling = @work.parent / "wt1"
    expect(sibling).to be_directory
    env_content = (sibling / ".env").read
    expect(env_content).to include("COMPOSE_PROJECT_NAME=wt1")
    expect(env_content).to include("HOST_NAME=wt1")
    expect(env_content).to include("DB_PORT=5432")
    expect(env_content).not_to include("HOST_NAME_SUFFIX")

    system("git", "-C", @work.to_s, "worktree", "remove", "--force", sibling.to_s,
           out: File::NULL, err: File::NULL)
  end

  it "brings up each compose service individually rather than all at once" do
    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")
    stub_clonefile
    stub_sh(docker_capture3: [
      ["", "", true],                       # docker info
      ["", "", true],                       # docker ps source
      ["", "", true],                       # docker images
      ["", "", true],                       # docker volume ls -- no source volumes
      ["", "", true],                       # docker volume ls -- pre-existing snapshot
      ["web\nwebpack\njobs\n", "", true],   # docker compose config --services
      ["", "", true],                       # up --no-start --no-build web
      ["", "", true],                       # up --no-start --no-build webpack
      ["", "", true],                       # up --no-start --no-build jobs
    ])

    expect {
      Ctree::CLI.run(["create", "wt1", "wt1"])
    }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }

    sibling = @work.parent / "wt1"
    %w[web webpack jobs].each do |service|
      expect(Ctree::Sh).to have_received(:capture3).with(
        "docker", "compose", "--project-directory", sibling.to_s,
        "--project-name", "wt1", "up", "--no-start", "--no-build", service,
        chdir: sibling.to_s
      )
    end
    expect(Ctree::Sh).not_to have_received(:capture3).with(
      "docker", "compose", "--project-directory", sibling.to_s,
      "--project-name", "wt1", "up", "--no-start", "--no-build",
      chdir: sibling.to_s
    )

    system("git", "-C", @work.to_s, "worktree", "remove", "--force", sibling.to_s,
           out: File::NULL, err: File::NULL)
  end

  # Regression guard for CTR-002: docker compose resolves relative COMPOSE_FILE
  # entries against the OS-level cwd, not --project-directory. Every compose
  # call must therefore chdir into the target worktree, or shared volumes get
  # silently created as local copies from the source repo's override file.
  it "runs every docker compose call with chdir: pointing at the target worktree" do
    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")
    stub_clonefile
    stub_sh(docker_capture3: docker_stubs)

    compose_calls = []
    allow(Ctree::Sh).to receive(:capture3).and_wrap_original do |original, *cmd, **kw|
      compose_calls << [cmd, kw] if cmd.first(2) == ["docker", "compose"]
      original.call(*cmd, **kw)
    end

    expect {
      Ctree::CLI.run(["create", "wt1", "wt1"])
    }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }

    sibling = @work.parent / "wt1"
    expect(compose_calls).not_to be_empty
    compose_calls.each do |cmd, kw|
      expect(cmd).to include("--project-directory", sibling.to_s)
      expect(kw[:chdir]).to eq(sibling.to_s)
    end

    system("git", "-C", @work.to_s, "worktree", "remove", "--force", sibling.to_s,
           out: File::NULL, err: File::NULL)
  end

  it "falls back to a single up --no-start --no-build when compose services can't be listed" do
    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")
    stub_clonefile
    stub_sh(docker_capture3: [
      ["", "", true],                 # docker info
      ["", "", true],                 # docker ps source
      ["", "", true],                 # docker images
      ["", "", true],                 # docker volume ls -- no source volumes
      ["", "", true],                 # docker volume ls -- pre-existing snapshot
      ["", "boom", false],            # docker compose config --services -- fails
      ["", "", true],                 # fallback: up --no-start --no-build (all services)
    ])

    expect {
      Ctree::CLI.run(["create", "wt1", "wt1"])
    }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
      .and output(/could not list compose services/).to_stderr

    sibling = @work.parent / "wt1"
    expect(Ctree::Sh).to have_received(:capture3).with(
      "docker", "compose", "--project-directory", sibling.to_s,
      "--project-name", "wt1", "up", "--no-start", "--no-build",
      chdir: sibling.to_s
    )

    system("git", "-C", @work.to_s, "worktree", "remove", "--force", sibling.to_s,
           out: File::NULL, err: File::NULL)
  end

  it "writes HOST_NAME_SUFFIX to the worktree .env when configured" do
    FileUtils.mkdir_p((@work / ".ctree").to_s)
    File.write((@work / ".ctree" / "config.yml").to_s, "host_name_suffix: docker\n")

    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")
    stub_clonefile
    stub_sh(docker_capture3: docker_stubs)

    expect {
      Ctree::CLI.run(["create", "wt1", "wt1"])
    }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }

    sibling = @work.parent / "wt1"
    env_content = (sibling / ".env").read
    expect(env_content).to include("HOST_NAME_SUFFIX=docker")

    system("git", "-C", @work.to_s, "worktree", "remove", "--force", sibling.to_s,
           out: File::NULL, err: File::NULL)
  end

  it "reads and writes the configured env_filename instead of .env" do
    FileUtils.mkdir_p((@work / ".ctree").to_s)
    File.write((@work / ".ctree" / "config.yml").to_s, "env_filename: .env.custom\n")
    File.write((@work / ".env.custom").to_s, "COMPOSE_PROJECT_NAME=src\nDB_PORT=5432\n")
    system("git", "-C", @work.to_s, "add", ".ctree", ".env.custom", out: File::NULL, err: File::NULL)
    system("git", "-C", @work.to_s, "commit", "-q", "--amend", "--no-edit",
           out: File::NULL, err: File::NULL)

    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")
    stub_clonefile
    stub_sh(docker_capture3: docker_stubs)

    expect {
      Ctree::CLI.run(["create", "wt1", "wt1"])
    }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
      .and output(/updated \.env\.custom/).to_stdout

    sibling = @work.parent / "wt1"
    env_content = (sibling / ".env.custom").read
    expect(env_content).to include("COMPOSE_PROJECT_NAME=wt1")
    expect(env_content).to include("HOST_NAME=wt1")

    system("git", "-C", @work.to_s, "worktree", "remove", "--force", sibling.to_s,
           out: File::NULL, err: File::NULL)
  end

  it "injects shared volumes into the compose override file and appends it to COMPOSE_FILE" do
    FileUtils.mkdir_p((@work / ".ctree").to_s)
    File.write((@work / ".ctree" / "config.yml").to_s,
               "share_volumes:\n  - yarn-cache\ncompose_override_file: docker-compose.local.ctree.yml\n")
    File.write((@work / ".env").to_s,
               "COMPOSE_PROJECT_NAME=src\nCOMPOSE_FILE=docker-compose.yml\nDB_PORT=5432\n")
    File.write((@work / "docker-compose.local.ctree.yml").to_s,
               "services:\n  web:\n    labels: []\n")
    system("git", "-C", @work.to_s, "add", ".", out: File::NULL, err: File::NULL)
    system("git", "-C", @work.to_s, "commit", "-q", "--amend", "--no-edit",
           out: File::NULL, err: File::NULL)

    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")
    stub_clonefile

    stub_sh(docker_capture3: [
      ["", "", true],                          # docker info
      ["", "", true],                          # docker ps source
      ["", "", true],                          # docker images
      ["src_yarn-cache\n", "", true],          # docker volume ls -- source has yarn-cache
      ["", "", true],                          # docker volume ls -- pre-existing snapshot
      ["web\n", "", true],                     # docker compose config --services
      ["", "", true],                          # docker compose up --no-start --no-build web
    ])

    expect {
      Ctree::CLI.run(["create", "wt1", "wt1"])
    }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }

    sibling = @work.parent / "wt1"
    override = YAML.safe_load((sibling / "docker-compose.local.ctree.yml").read)
    expect(override["volumes"]["yarn-cache"]).to eq(
      "external" => true, "name" => "src_yarn-cache"
    )
    env_content = (sibling / ".env").read
    expect(env_content).to match(/COMPOSE_FILE=.*docker-compose\.local\.ctree\.yml/)

    system("git", "-C", @work.to_s, "worktree", "remove", "--force", sibling.to_s,
           out: File::NULL, err: File::NULL)
  end

  it "warns when compose_override_file is missing from the worktree and share_volumes is configured" do
    FileUtils.mkdir_p((@work / ".ctree").to_s)
    File.write((@work / ".ctree" / "config.yml").to_s,
               "share_volumes:\n  - yarn-cache\ncompose_override_file: docker-compose.local.ctree.yml\n")
    system("git", "-C", @work.to_s, "add", ".ctree", out: File::NULL, err: File::NULL)
    system("git", "-C", @work.to_s, "commit", "-q", "--amend", "--no-edit",
           out: File::NULL, err: File::NULL)

    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")
    stub_clonefile
    stub_sh(docker_capture3: docker_stubs)

    expect {
      Ctree::CLI.run(["create", "wt1", "wt1"])
    }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
      .and output(/docker-compose\.local\.ctree\.yml not found in worktree.*yarn-cache/).to_stderr

    system("git", "-C", @work.to_s, "worktree", "remove", "--force",
           (@work.parent / "wt1").to_s, out: File::NULL, err: File::NULL)
  end

  it "warns for each share_volume whose source Docker volume does not exist" do
    FileUtils.mkdir_p((@work / ".ctree").to_s)
    File.write((@work / ".ctree" / "config.yml").to_s,
               "share_volumes:\n  - yarn-cache\n  - missing-vol\ncompose_override_file: docker-compose.local.ctree.yml\n")
    File.write((@work / ".env").to_s,
               "COMPOSE_PROJECT_NAME=src\nCOMPOSE_FILE=docker-compose.yml\nDB_PORT=5432\n")
    File.write((@work / "docker-compose.local.ctree.yml").to_s,
               "services:\n  web:\n    labels: []\n")
    system("git", "-C", @work.to_s, "add", ".", out: File::NULL, err: File::NULL)
    system("git", "-C", @work.to_s, "commit", "-q", "--amend", "--no-edit",
           out: File::NULL, err: File::NULL)

    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")
    stub_clonefile

    stub_sh(docker_capture3: [
      ["", "", true],                 # docker info
      ["", "", true],                 # docker ps source
      ["", "", true],                 # docker images
      ["src_yarn-cache\n", "", true], # docker volume ls -- yarn-cache exists, missing-vol does not
      ["", "", true],                 # docker volume ls -- pre-existing snapshot
      ["web\n", "", true],            # docker compose config --services
      ["", "", true],                 # docker compose up --no-start --no-build web
    ])

    expect {
      Ctree::CLI.run(["create", "wt1", "wt1"])
    }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
      .and output(/source volume src_missing-vol not found.*missing-vol will not be shared/).to_stderr

    sibling = @work.parent / "wt1"
    override = YAML.safe_load((sibling / "docker-compose.local.ctree.yml").read)
    expect(override["volumes"]["yarn-cache"]).to eq("external" => true, "name" => "src_yarn-cache")
    expect(override["volumes"]).not_to have_key("missing-vol")

    system("git", "-C", @work.to_s, "worktree", "remove", "--force", sibling.to_s,
           out: File::NULL, err: File::NULL)
  end

  it "warns when all share_volumes are absent from Docker and no external references are written" do
    FileUtils.mkdir_p((@work / ".ctree").to_s)
    File.write((@work / ".ctree" / "config.yml").to_s,
               "share_volumes:\n  - yarn-cache\ncompose_override_file: docker-compose.local.ctree.yml\n")
    File.write((@work / ".env").to_s,
               "COMPOSE_PROJECT_NAME=src\nCOMPOSE_FILE=docker-compose.yml\nDB_PORT=5432\n")
    File.write((@work / "docker-compose.local.ctree.yml").to_s,
               "services:\n  web:\n    labels: []\n")
    system("git", "-C", @work.to_s, "add", ".", out: File::NULL, err: File::NULL)
    system("git", "-C", @work.to_s, "commit", "-q", "--amend", "--no-edit",
           out: File::NULL, err: File::NULL)

    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")
    stub_clonefile
    stub_sh(docker_capture3: docker_stubs)

    expect {
      Ctree::CLI.run(["create", "wt1", "wt1"])
    }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
      .and output(/no source volumes found for share_volumes.*worktree will use its own isolated copies/).to_stderr

    system("git", "-C", @work.to_s, "worktree", "remove", "--force",
           (@work.parent / "wt1").to_s, out: File::NULL, err: File::NULL)
  end

  it "preserves !override and !reset YAML tags in the compose override file" do
    FileUtils.mkdir_p((@work / ".ctree").to_s)
    File.write((@work / ".ctree" / "config.yml").to_s,
               "share_volumes:\n  - yarn-cache\ncompose_override_file: docker-compose.local.ctree.yml\n")
    File.write((@work / ".env").to_s,
               "COMPOSE_PROJECT_NAME=src\nCOMPOSE_FILE=docker-compose.yml\nDB_PORT=5432\n")
    File.write((@work / "docker-compose.local.ctree.yml").to_s,
               "services:\n  web:\n    ports: !override []\n    aliases: !reset []\n")
    system("git", "-C", @work.to_s, "add", ".", out: File::NULL, err: File::NULL)
    system("git", "-C", @work.to_s, "commit", "-q", "--amend", "--no-edit",
           out: File::NULL, err: File::NULL)

    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")
    stub_clonefile

    stub_sh(docker_capture3: [
      ["", "", true],                          # docker info
      ["", "", true],                          # docker ps source
      ["", "", true],                          # docker images
      ["src_yarn-cache\n", "", true],          # docker volume ls -- source has yarn-cache
      ["", "", true],                          # docker volume ls -- pre-existing snapshot
      ["web\n", "", true],                     # docker compose config --services
      ["", "", true],                          # docker compose up --no-start --no-build web
    ])

    expect {
      Ctree::CLI.run(["create", "wt1", "wt1"])
    }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }

    sibling = @work.parent / "wt1"
    override_content = (sibling / "docker-compose.local.ctree.yml").read
    expect(override_content).to include("!override")
    expect(override_content).to include("!reset")
    override_doc = YAML.safe_load(override_content, aliases: true)
    expect(override_doc["volumes"]["yarn-cache"]).to eq(
      "external" => true, "name" => "src_yarn-cache"
    )

    system("git", "-C", @work.to_s, "worktree", "remove", "--force", sibling.to_s,
           out: File::NULL, err: File::NULL)
  end

  it "removes files present in source but not on the target branch" do
    system("git", "checkout", "-q", "-b", "feature-branch", out: File::NULL, err: File::NULL)
    system("git", "checkout", "-q", "master", out: File::NULL, err: File::NULL)
    File.write("extra.rb", "# extra")
    system("git", "add", "extra.rb", out: File::NULL, err: File::NULL)
    system("git", "commit", "-q", "-m", "add extra", out: File::NULL, err: File::NULL)

    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")
    stub_clonefile
    stub_sh(docker_capture3: docker_stubs)

    expect {
      Ctree::CLI.run(["create", "wt1", "feature-branch"])
    }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }

    sibling = @work.parent / "wt1"
    expect(sibling / "extra.rb").not_to exist

    system("git", "-C", @work.to_s, "worktree", "remove", "--force", sibling.to_s,
           out: File::NULL, err: File::NULL)
  end

  it "does not clone top-level directories listed in exclude" do
    FileUtils.mkdir_p((@work / ".ctree").to_s)
    File.write((@work / ".ctree" / "config.yml").to_s, "exclude:\n  - node_modules\n")
    File.write((@work / ".gitignore").to_s, "node_modules/\n")
    FileUtils.mkdir_p((@work / "node_modules").to_s)
    File.write((@work / "node_modules" / "package.json").to_s, "{}")
    system("git", "-C", @work.to_s, "add", ".gitignore", ".ctree", out: File::NULL, err: File::NULL)
    system("git", "-C", @work.to_s, "commit", "-q", "--amend", "--no-edit",
           out: File::NULL, err: File::NULL)

    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")
    stub_clonefile
    stub_sh(docker_capture3: docker_stubs)

    expect {
      Ctree::CLI.run(["create", "wt1", "wt1"])
    }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }

    sibling = @work.parent / "wt1"
    expect(sibling / "node_modules").not_to exist
    expect(sibling / ".env").to exist

    system("git", "-C", @work.to_s, "worktree", "remove", "--force", sibling.to_s,
           out: File::NULL, err: File::NULL)
  end

  it "does not clone top-level files listed in exclude" do
    FileUtils.mkdir_p((@work / ".ctree").to_s)
    File.write((@work / ".ctree" / "config.yml").to_s, "exclude:\n  - secrets.yml\n")
    File.write((@work / ".gitignore").to_s, "secrets.yml\n")
    File.write((@work / "secrets.yml").to_s, "api_key: secret")
    system("git", "-C", @work.to_s, "add", ".gitignore", ".ctree", out: File::NULL, err: File::NULL)
    system("git", "-C", @work.to_s, "commit", "-q", "--amend", "--no-edit",
           out: File::NULL, err: File::NULL)

    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")
    stub_clonefile
    stub_sh(docker_capture3: docker_stubs)

    expect {
      Ctree::CLI.run(["create", "wt1", "wt1"])
    }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }

    sibling = @work.parent / "wt1"
    expect(sibling / "secrets.yml").not_to exist
    expect(sibling / ".env").to exist

    system("git", "-C", @work.to_s, "worktree", "remove", "--force", sibling.to_s,
           out: File::NULL, err: File::NULL)
  end

  it "copies update file from source, overwriting the branch version after git checkout" do
    FileUtils.mkdir_p((@work / ".ctree").to_s)
    File.write((@work / ".ctree" / "config.yml").to_s, "update:\n  - lockfile.test\n")
    File.write((@work / "lockfile.test").to_s, "source-version")
    system("git", "-C", @work.to_s, "add", ".ctree", "lockfile.test",
           out: File::NULL, err: File::NULL)
    system("git", "-C", @work.to_s, "commit", "-q", "--amend", "--no-edit",
           out: File::NULL, err: File::NULL)

    system("git", "-C", @work.to_s, "checkout", "-q", "-b", "wt1",
           out: File::NULL, err: File::NULL)
    File.write((@work / "lockfile.test").to_s, "old-version")
    system("git", "-C", @work.to_s, "add", "lockfile.test",
           out: File::NULL, err: File::NULL)
    system("git", "-C", @work.to_s, "commit", "-q", "-m", "old lockfile",
           out: File::NULL, err: File::NULL)
    system("git", "-C", @work.to_s, "checkout", "-q", "master",
           out: File::NULL, err: File::NULL)

    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")
    stub_clonefile
    stub_sh(docker_capture3: docker_stubs)

    expect {
      Ctree::CLI.run(["create", "wt1", "wt1"])
    }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }

    sibling = @work.parent / "wt1"
    expect((sibling / "lockfile.test").read).to eq("source-version")

    system("git", "-C", @work.to_s, "worktree", "remove", "--force", sibling.to_s,
           out: File::NULL, err: File::NULL)
  end

  it "fails when the target sibling path already exists" do
    sibling = @work.parent / "wt2"
    FileUtils.mkdir_p(sibling.to_s)

    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")

    expect {
      Ctree::CLI.run(["create", "wt2", "wt2"])
    }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
  ensure
    FileUtils.rm_rf(sibling.to_s) if sibling
  end

  it "creates empty volumes for suffixes listed in empty_volumes without copying" do
    FileUtils.mkdir_p((@work / ".ctree").to_s)
    File.write((@work / ".ctree" / "config.yml").to_s,
               "empty_volumes:\n  - log\nlog_level: debug\n")
    system("git", "-C", @work.to_s, "add", ".ctree",
           out: File::NULL, err: File::NULL)
    system("git", "-C", @work.to_s, "commit", "-q", "--amend", "--no-edit",
           out: File::NULL, err: File::NULL)

    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")
    stub_clonefile
    stub_sh(docker_capture3: [
      ["", "", true],              # docker info
      ["", "", true],              # docker ps source
      ["", "", true],              # docker images
      ["src_log\n", "", true],    # docker volume ls — source has log volume
      ["", "", true],              # docker volume ls — pre-existing snapshot
      ["web\n", "", true],         # docker compose config --services
      ["", "", true],              # docker compose up --no-start --no-build web
    ])

    expect {
      Ctree::CLI.run(["create", "wt1", "wt1"])
    }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
      .and output(/\[empty {2}\].*wt1_log.*\(empty volume\)/).to_stdout

    system("git", "-C", @work.to_s, "worktree", "remove", "--force",
           (@work.parent / "wt1").to_s, out: File::NULL, err: File::NULL)
  end

  # Makes .env gitignored (as it is in real projects) so create's .env edits
  # don't leave unstaged changes that would block git rebase.
  def untrack_env
    File.write(".gitignore", ".env\n")
    system("git", "rm", "-q", "--cached", ".env", out: File::NULL, err: File::NULL)
    system("git", "add", ".gitignore", out: File::NULL, err: File::NULL)
    system("git", "commit", "-q", "-m", "ignore .env", out: File::NULL, err: File::NULL)
  end

  it "offers to rebase a stale existing branch onto master and rebases when accepted" do
    untrack_env
    system("git", "checkout", "-q", "-b", "stale", out: File::NULL, err: File::NULL)
    system("git", "checkout", "-q", "master", out: File::NULL, err: File::NULL)
    File.write("newer.rb", "# newer")
    system("git", "add", "newer.rb", out: File::NULL, err: File::NULL)
    system("git", "commit", "-q", "-m", "advance master", out: File::NULL, err: File::NULL)

    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line) { |prompt| prompt =~ /rebase/ ? "y" : "n" }
    stub_clonefile
    stub_sh(docker_capture3: docker_stubs)

    expect {
      Ctree::CLI.run(["create", "wt1", "stale"])
    }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
      .and output(/branch 'stale' is 1 commit\(s\) behind master/).to_stderr

    sibling = @work.parent / "wt1"
    expect(sibling / "newer.rb").to exist
    expect(`git -C #{sibling} rev-list --count HEAD..master`.strip).to eq("0")

    system("git", "-C", @work.to_s, "worktree", "remove", "--force", sibling.to_s,
           out: File::NULL, err: File::NULL)
  end

  it "leaves a stale branch unrebased when the user declines" do
    untrack_env
    system("git", "checkout", "-q", "-b", "stale", out: File::NULL, err: File::NULL)
    system("git", "checkout", "-q", "master", out: File::NULL, err: File::NULL)
    File.write("newer.rb", "# newer")
    system("git", "add", "newer.rb", out: File::NULL, err: File::NULL)
    system("git", "commit", "-q", "-m", "advance master", out: File::NULL, err: File::NULL)

    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")
    stub_clonefile
    stub_sh(docker_capture3: docker_stubs)

    expect {
      Ctree::CLI.run(["create", "wt1", "stale"])
    }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }

    sibling = @work.parent / "wt1"
    expect(sibling / "newer.rb").not_to exist
    expect(`git -C #{sibling} rev-list --count HEAD..master`.strip).to eq("1")

    system("git", "-C", @work.to_s, "worktree", "remove", "--force", sibling.to_s,
           out: File::NULL, err: File::NULL)
  end

  describe "master branch check" do
    it "does not prompt about master when source is already on master" do
      allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
      allow(Ctree::Prompt).to receive(:read_line).and_return("n")
      expect(Ctree::Prompt).not_to receive(:read_line).with(/master/)
      stub_clonefile
      stub_sh(docker_capture3: docker_stubs)

      expect {
        Ctree::CLI.run(["create", "wt1", "wt1"])
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }

      system("git", "-C", @work.to_s, "worktree", "remove", "--force", (@work.parent / "wt1").to_s,
             out: File::NULL, err: File::NULL)
    end

    it "exits when source is not on master, no uncommitted changes, user declines to switch" do
      system("git", "checkout", "-q", "-b", "feature-x", out: File::NULL, err: File::NULL)
      allow(Ctree::Prompt).to receive(:read_line).and_return("n")

      expect {
        Ctree::CLI.run(["create", "wt1", "wt1"])
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end

    it "exits when source is not on master, with uncommitted changes, user declines to stash and switch" do
      system("git", "checkout", "-q", "-b", "feature-x", out: File::NULL, err: File::NULL)
      File.write(".env", "COMPOSE_PROJECT_NAME=src\nDB_PORT=5432\nDIRTY=true\n")
      allow(Ctree::Prompt).to receive(:read_line).and_return("n")

      expect {
        Ctree::CLI.run(["create", "wt1", "wt1"])
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end

    it "switches source to master and continues when not on master, no uncommitted changes, user accepts" do
      system("git", "checkout", "-q", "-b", "feature-x", out: File::NULL, err: File::NULL)
      allow(Ctree::Prompt).to receive(:read_line) { |prompt| prompt =~ /switch source to master/ ? "y" : "n" }
      allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
      stub_clonefile
      stub_sh(docker_capture3: docker_stubs)

      expect {
        Ctree::CLI.run(["create", "wt1", "wt1"])
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }

      current = `git -C #{@work} rev-parse --abbrev-ref HEAD`.strip
      expect(current).to eq("master")

      system("git", "-C", @work.to_s, "worktree", "remove", "--force", (@work.parent / "wt1").to_s,
             out: File::NULL, err: File::NULL)
    end

    it "stashes uncommitted changes, switches to master, and continues when user accepts" do
      system("git", "checkout", "-q", "-b", "feature-x", out: File::NULL, err: File::NULL)
      File.write(".env", "COMPOSE_PROJECT_NAME=src\nDB_PORT=5432\nDIRTY=true\n")
      allow(Ctree::Prompt).to receive(:read_line) { |prompt| prompt =~ /stash uncommitted changes/ ? "y" : "n" }
      allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
      stub_clonefile
      stub_sh(docker_capture3: docker_stubs)

      expect {
        Ctree::CLI.run(["create", "wt1", "wt1"])
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }

      current = `git -C #{@work} rev-parse --abbrev-ref HEAD`.strip
      expect(current).to eq("master")
      expect(`git -C #{@work} stash list`.strip).not_to be_empty

      system("git", "-C", @work.to_s, "worktree", "remove", "--force", (@work.parent / "wt1").to_s,
             out: File::NULL, err: File::NULL)
    end

    it "accepts --config <path> and uses the custom config for the worktree" do
      FileUtils.mkdir_p((@work / ".ctree").to_s)
      File.write((@work / ".ctree" / "config.yml").to_s, "exclude: []\nupdate_volumes:\n  - something\n")
      File.write((@work / ".gitignore").to_s, "node_modules/\n")
      FileUtils.mkdir_p((@work / "node_modules").to_s)
      File.write((@work / "node_modules" / "package.json").to_s, "{}")
      system("git", "-C", @work.to_s, "add", ".ctree", ".gitignore", out: File::NULL, err: File::NULL)
      system("git", "-C", @work.to_s, "commit", "-q", "--amend", "--no-edit",
             out: File::NULL, err: File::NULL)

      # Write a custom config that excludes node_modules
      custom = @parent / "custom_config.yml"
      File.write(custom.to_s, "exclude:\n  - node_modules\n")

      allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
      allow(Ctree::Prompt).to receive(:read_line).and_return("n")
      stub_clonefile
      stub_sh(docker_capture3: docker_stubs)

      expect {
        Ctree::CLI.run(["create", "wt1", "wt1", "--config", custom.to_s])
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }

      sibling = @work.parent / "wt1"

      # The custom config was persisted into the worktree
      persisted = sibling / ".ctree" / "config.yml"
      expect(persisted).to exist
      expect(persisted.read).to eq(File.read(custom.to_s))

      # The exclude took effect (node_modules was not cloned)
      expect(sibling / "node_modules").not_to exist

      system("git", "-C", @work.to_s, "worktree", "remove", "--force", sibling.to_s,
             out: File::NULL, err: File::NULL)
    end
  end

  describe ".ctree exclusion" do
    it "recreates .ctree/config.yml from source when source has one" do
      FileUtils.mkdir_p((@work / ".ctree").to_s)
      File.write((@work / ".ctree" / "config.yml").to_s,
                 "exclude:\n  - node_modules\nshare_volumes:\n  - gems\n")
      File.write((@work / ".gitignore").to_s, ".ctree/\n")
      system("git", "-C", @work.to_s, "add", ".gitignore", out: File::NULL, err: File::NULL)
      system("git", "-C", @work.to_s, "commit", "-q", "--amend", "--no-edit",
             out: File::NULL, err: File::NULL)

      allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
      allow(Ctree::Prompt).to receive(:read_line).and_return("n")
      stub_clonefile
      stub_sh(docker_capture3: docker_stubs)

      expect {
        Ctree::CLI.run(["create", "wt1", "wt1"])
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }

      sibling = @work.parent / "wt1"
      expect(sibling / ".ctree" / "config.yml").to exist
      expect((sibling / ".ctree" / "config.yml").read).to eq(
        "exclude:\n  - node_modules\nshare_volumes:\n  - gems\n"
      )

      system("git", "-C", @work.to_s, "worktree", "remove", "--force", sibling.to_s,
             out: File::NULL, err: File::NULL)
    end

    it "does not clone extra files from source .ctree/ into worktree" do
      FileUtils.mkdir_p((@work / ".ctree").to_s)
      File.write((@work / ".ctree" / "config.yml").to_s, "share_volumes:\n  - gems\n")
      File.write((@work / ".ctree" / "scratch.txt").to_s, "stray file")
      File.write((@work / ".gitignore").to_s, ".ctree/\n")
      system("git", "-C", @work.to_s, "add", ".gitignore", out: File::NULL, err: File::NULL)
      system("git", "-C", @work.to_s, "commit", "-q", "--amend", "--no-edit",
             out: File::NULL, err: File::NULL)

      allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
      allow(Ctree::Prompt).to receive(:read_line).and_return("n")
      stub_clonefile
      stub_sh(docker_capture3: docker_stubs)

      expect {
        Ctree::CLI.run(["create", "wt1", "wt1"])
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }

      sibling = @work.parent / "wt1"
      expect(sibling / ".ctree" / "config.yml").to exist
      expect(sibling / ".ctree" / "scratch.txt").not_to exist

      system("git", "-C", @work.to_s, "worktree", "remove", "--force", sibling.to_s,
             out: File::NULL, err: File::NULL)
    end

    it "creates no .ctree/ in worktree when source has none" do
      allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
      allow(Ctree::Prompt).to receive(:read_line).and_return("n")
      stub_clonefile
      stub_sh(docker_capture3: docker_stubs)

      expect {
        Ctree::CLI.run(["create", "wt1", "wt1"])
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }

      sibling = @work.parent / "wt1"
      expect(sibling / ".ctree").not_to exist

      system("git", "-C", @work.to_s, "worktree", "remove", "--force", sibling.to_s,
             out: File::NULL, err: File::NULL)
    end

    it "accepts exclude: [.ctree] as a harmless no-op" do
      FileUtils.mkdir_p((@work / ".ctree").to_s)
      File.write((@work / ".ctree" / "config.yml").to_s,
                 "exclude:\n  - .ctree\nshare_volumes:\n  - gems\n")
      File.write((@work / ".gitignore").to_s, ".ctree/\n")
      system("git", "-C", @work.to_s, "add", ".gitignore", out: File::NULL, err: File::NULL)
      system("git", "-C", @work.to_s, "commit", "-q", "--amend", "--no-edit",
             out: File::NULL, err: File::NULL)

      allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
      allow(Ctree::Prompt).to receive(:read_line).and_return("n")
      stub_clonefile
      stub_sh(docker_capture3: docker_stubs)

      expect {
        Ctree::CLI.run(["create", "wt1", "wt1"])
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }

      sibling = @work.parent / "wt1"
      expect(sibling / ".ctree" / "config.yml").to exist
      expect((sibling / ".ctree" / "config.yml").read).to eq(
        "exclude:\n  - .ctree\nshare_volumes:\n  - gems\n"
      )

      system("git", "-C", @work.to_s, "worktree", "remove", "--force", sibling.to_s,
             out: File::NULL, err: File::NULL)
    end
  end
end
