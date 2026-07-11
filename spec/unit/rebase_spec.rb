# frozen_string_literal: true

RSpec.describe "Ctree::Rebase main branch skip logic" do
  def stub_run_up_to(target, source, branch:, ancestor:)
    allow(Ctree::Sh).to receive(:capture3) do |*cmd|
      case [cmd[0], cmd[3], cmd[4]]
      when ["git", "rev-parse", "--show-toplevel"]  then [target.to_s, "", fake_status(true)]
      when ["git", "rev-parse", "--git-common-dir"] then ["../.git", "", fake_status(true)]
      when ["git", "rev-parse", "--abbrev-ref"]     then [branch, "", fake_status(true)]
      when ["git", "merge-base", "--is-ancestor"]   then ["", "", fake_status(ancestor)]
      when ["git", "status", "--porcelain"]         then ["", "", fake_status(true)]
      else raise "unexpected: #{cmd.inspect}"
      end
    end
    allow(Ctree::Config).to receive(:load).and_return(Ctree::Config.defaults)
    allow(Ctree::Rebase).to receive(:embedded_repos).and_return([])
    allow(Ctree::Rebase).to receive(:exit)
  end

  around do |ex|
    Dir.mktmpdir do |tmp|
      @source = Pathname.new(tmp).realpath
      Dir.mkdir((@source / "worktree").to_s)
      @target = (@source / "worktree").realpath
      Dir.chdir(@target.to_s) { ex.run }
    end
  end

  it "skips rebase when master is already an ancestor of HEAD" do
    stub_run_up_to(@target, @source, branch: "CTR-001", ancestor: true)
    expect(Ctree::Sh).not_to receive(:capture3).with("git", anything, anything, "rebase", "master")
    expect { Ctree::Rebase.run }.to output(/already up to date with master/).to_stdout
  end

  it "rebases when master is not yet an ancestor of HEAD" do
    stub_run_up_to(@target, @source, branch: "CTR-001", ancestor: false)
    allow(Ctree::Sh).to receive(:capture3).with("git", "-C", @target.to_s, "rebase", "master") do
      ["", "", fake_status(true)]
    end
    expect { Ctree::Rebase.run }.to output(/rebased CTR-001 onto master/).to_stdout
  end
end

RSpec.describe "Ctree::Rebase embedded repo discovery" do
  around do |ex|
    Dir.mktmpdir do |tmp|
      @root = Pathname.new(tmp).realpath
      ex.run
    end
  end

  def make_embedded_repo(path)
    FileUtils.mkdir_p(path.to_s)
    FileUtils.mkdir_p((path / ".git").to_s)
  end

  def make_submodule_entry(root, rel_path)
    gitmodules = root / ".gitmodules"
    File.open(gitmodules.to_s, "a") do |f|
      f.puts "[submodule \"#{rel_path}\"]"
      f.puts "\tpath = #{rel_path}"
      f.puts "\turl = https://example.com/#{File.basename(rel_path)}"
    end
  end

  it "returns embedded repos found under the configured paths" do
    make_embedded_repo(@root / "gems/plugins/foo")
    make_embedded_repo(@root / "gems/plugins/bar")
    FileUtils.mkdir_p((@root / "gems/plugins/not_a_repo").to_s)

    result = Ctree::Rebase.send(:embedded_repos, @root, ["gems/plugins"])
    expect(result.map { |p| p.basename.to_s }.sort).to eq(["bar", "foo"])
  end

  it "skips dirs that are listed in .gitmodules" do
    make_embedded_repo(@root / "gems/plugins/submod")
    make_embedded_repo(@root / "gems/plugins/embedded")
    make_submodule_entry(@root, "gems/plugins/submod")

    result = Ctree::Rebase.send(:embedded_repos, @root, ["gems/plugins"])
    expect(result.map { |p| p.basename.to_s }).to eq(["embedded"])
  end

  it "returns empty when rebase is empty" do
    make_embedded_repo(@root / "gems/plugins/foo")
    expect(Ctree::Rebase.send(:embedded_repos, @root, [])).to eq([])
  end

  it "returns empty when the scan directory does not exist" do
    result = Ctree::Rebase.send(:embedded_repos, @root, ["nonexistent/path"])
    expect(result).to eq([])
  end
end
