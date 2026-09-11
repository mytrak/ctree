# frozen_string_literal: true

require "stringio"

# Helpers shared by both describe blocks
module ConfigSpecHelper
  def write_repo_config(dir, content)
    d = File.join(dir.to_s, ".ctree")
    FileUtils.mkdir_p(d)
    File.write(File.join(d, "config.yml"), content)
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

RSpec.describe "Ctree::CLI config add / remove" do
  include ConfigSpecHelper

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
    @target = @work / ".ctree" / "config.yml"
  end

  it "creates <repo>/.ctree/config.yml from the shipped template" do
    Ctree::CLI.run(["config", "add"])
    expect(File).to be_file(@target.to_s)
    expect(@target.read).to eq(File.read(Ctree::Config::SHIPPED_CONFIG_PATH))
  end

  it "creates the file even when run from a subdirectory of the repo" do
    sub = @work / "nested"
    FileUtils.mkdir_p(sub.to_s)
    Dir.chdir(sub.to_s) { Ctree::CLI.run(["config", "add"]) }
    expect(File).to be_file(@target.to_s)
  end

  it "prompts to reset when the file already exists and preserves on N" do
    FileUtils.mkdir_p(@target.dirname.to_s)
    @target.write("existing: content\n")
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")
    expect {
      Ctree::CLI.run(["config", "add"])
    }.to output(/keeping existing config/).to_stdout
    expect(@target.read).to eq("existing: content\n")
  end

  it "resets the file when user confirms with y" do
    FileUtils.mkdir_p(@target.dirname.to_s)
    @target.write("existing: content\n")
    allow(Ctree::Prompt).to receive(:read_line).and_return("y")
    Ctree::CLI.run(["config", "add"])
    expect(@target.read).to eq(File.read(Ctree::Config::SHIPPED_CONFIG_PATH))
  end

  it "config delete deletes the file and the .ctree directory" do
    Ctree::CLI.run(["config", "add"])
    allow(Ctree::Prompt).to receive(:read_line).and_return("yes")
    Ctree::CLI.run(["config", "delete"])
    expect(File).not_to exist(@target.to_s)
    expect(Dir).not_to exist(@target.dirname.to_s)
  end

  it "config add --force keeps an existing config (reset prompt defaults to no)" do
    FileUtils.mkdir_p(@target.dirname.to_s)
    @target.write("existing: content\n")
    expect(Ctree::Prompt).not_to receive(:read_line)
    expect {
      Ctree::CLI.run(["config", "add", "--force"])
    }.to output(/keeping existing config/).to_stdout
    expect(@target.read).to eq("existing: content\n")
  end

  it "config delete --force removes the file and directory without prompting" do
    Ctree::CLI.run(["config", "add"])
    expect(Ctree::Prompt).not_to receive(:read_line)
    Ctree::CLI.run(["config", "delete", "--force"])
    expect(File).not_to exist(@target.to_s)
    expect(Dir).not_to exist(@target.dirname.to_s)
  end

  it "config delete aborts unless the user types 'yes'" do
    Ctree::CLI.run(["config", "add"])
    allow(Ctree::Prompt).to receive(:read_line).and_return("y")
    expect {
      Ctree::CLI.run(["config", "delete"])
    }.to output(/aborted — config file kept/).to_stdout
    expect(File).to exist(@target.to_s)
  end

  it "config delete keeps the .ctree directory when it holds other files" do
    Ctree::CLI.run(["config", "add"])
    (@work / ".ctree" / "keep.txt").write("x")
    allow(Ctree::Prompt).to receive(:read_line).and_return("yes")
    expect {
      Ctree::CLI.run(["config", "delete"])
    }.to output(/kept .* it still contains: keep.txt/).to_stderr
    expect(File).not_to exist(@target.to_s)
    expect(Dir).to exist(@target.dirname.to_s)
  end

  it "warns when config add is run outside a git repository" do
    Dir.mktmpdir do |non_repo|
      Dir.chdir(non_repo) do
        expect {
          Ctree::CLI.run(["config", "add"])
        }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
          .and output(/must be run from within a git repository/).to_stderr
      end
    end
  end

  it "shows usage when given an unknown flag" do
    expect {
      Ctree::CLI.run(["config", "--bogus"])
    }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      .and output(/Usage:/).to_stdout
  end
end

RSpec.describe "Ctree::CLI config list (prints local config)" do
  include ConfigSpecHelper

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
    system("git", "commit", "--allow-empty", "-q", "-m", "init",
           out: File::NULL, err: File::NULL)
  end

  it "notes that no local config exists when the repo has none" do
    expect {
      Ctree::CLI.run(["config", "list"])
    }.to output(/no local config file/).to_stdout
  end

  it "prints merged config when repo .ctree/config.yml partially overrides defaults" do
    write_repo_config(@work, "update_volumes:\n  - alpha\n  - beta\n")
    output = capture_stdout { Ctree::CLI.run(["config", "list"]) }
    parsed = YAML.safe_load(output)
    expect(parsed["update_volumes"]).to eq(["alpha", "beta"])
    expect(parsed["share_volumes"]).to eq(Ctree::Config.defaults[:share_volumes])
  end

  it "prints host_name_suffix immediately after host_name" do
    write_repo_config(@work, "host_name_suffix: docker\n")
    output = capture_stdout { Ctree::CLI.run(["config", "list"]) }
    keys = YAML.safe_load(output).keys
    expect(keys.index("host_name_suffix")).to eq(keys.index("host_name") + 1)
  end

  it "output is valid YAML that can be re-fed as a repo config" do
    write_repo_config(@work, "share_volumes:\n  - my-cache\n")
    output = capture_stdout { Ctree::CLI.run(["config", "list"]) }
    Dir.mktmpdir do |dir|
      system("git", "init", "-q", "-b", "main", chdir: dir, out: File::NULL, err: File::NULL)
      write_repo_config(dir, output)
      result = Ctree::Config.load(dir)
      expect(result[:share_volumes]).to eq(["my-cache"])
    end
  end

  it "errors when not at git top-level" do
    write_repo_config(@work, "host_name_suffix: docker\n")
    sub = @work / "nested"
    FileUtils.mkdir_p(sub.to_s)
    Dir.chdir(sub.to_s) do
      expect {
        Ctree::CLI.run(["config", "list"])
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        .and output(/must be invoked from project top-level/).to_stderr
    end
  end

  it "rejects an unknown config flag" do
    expect {
      Ctree::CLI.run(["config", "--print"])
    }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      .and output(/Usage:/).to_stdout
  end
end
