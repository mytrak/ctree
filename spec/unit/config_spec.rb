# frozen_string_literal: true

RSpec.describe Ctree::Config do
  def write_repo_config(dir, content)
    config_dir = File.join(dir, ".ctree")
    FileUtils.mkdir_p(config_dir)
    File.write(File.join(config_dir, "config.yml"), content)
  end

  describe ".defaults" do
    it "returns the shipped defaults file as a symbol-keyed hash" do
      defaults = described_class.defaults
      expect(defaults).to have_key(:update_volumes)
      expect(defaults).to have_key(:share_volumes)
      expect(defaults[:update_volumes]).to all(be_a(String))
      expect(defaults[:share_volumes]).to all(be_a(String))
    end

    it "matches the contents of lib/ctree/config.yml" do
      file = YAML.safe_load(File.read(described_class::SHIPPED_CONFIG_PATH))
      expect(described_class.defaults[:update_volumes]).to eq(file["update_volumes"])
      expect(described_class.defaults[:share_volumes]).to eq(file["share_volumes"])
    end
  end

  describe ".load" do
    it "returns defaults when no config files exist" do
      Dir.mktmpdir do |dir|
        result = described_class.load(dir)
        expect(result).to eq(described_class.defaults)
      end
    end

    it "repo config overrides defaults" do
      Dir.mktmpdir do |dir|
        write_repo_config(dir, <<~YAML)
          update_volumes:
            - data
          share_volumes:
            - cache
        YAML
        result = described_class.load(dir)
        expect(result[:update_volumes]).to eq(["data"])
        expect(result[:share_volumes]).to eq(["cache"])
      end
    end

    it "repo config overrides only the keys it specifies; rest fall through" do
      Dir.mktmpdir do |dir|
        write_repo_config(dir, "update_volumes:\n  - only_this\n")
        result = described_class.load(dir)
        expect(result[:update_volumes]).to eq(["only_this"])
        expect(result[:share_volumes]).to eq(described_class.defaults[:share_volumes])
      end
    end

    it "warns and falls back when config file is malformed YAML" do
      Dir.mktmpdir do |dir|
        write_repo_config(dir, "this: is: not: valid: yaml: [\n")
        expect {
          result = described_class.load(dir)
          expect(result).to eq(described_class.defaults)
        }.to output(/could not parse.*ignoring overrides/).to_stderr
      end
    end

    it "warns and falls back when config file top level is not a mapping" do
      Dir.mktmpdir do |dir|
        write_repo_config(dir, "- a\n- b\n")
        expect {
          result = described_class.load(dir)
          expect(result).to eq(described_class.defaults)
        }.to output(/top-level must be a YAML mapping; ignoring overrides/).to_stderr
      end
    end

    it "aborts when a key has the wrong type" do
      Dir.mktmpdir do |dir|
        write_repo_config(dir, "update_volumes: \"not a list\"\n")
        expect {
          described_class.load(dir)
        }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
          .and output(/missing or invalid "update_volumes"/).to_stderr
      end
    end

    it "defaults exclude to [] when absent" do
      Dir.mktmpdir do |dir|
        result = described_class.load(dir)
        expect(result[:exclude]).to eq([])
      end
    end

    it "loads exclude from repo config when present" do
      Dir.mktmpdir do |dir|
        write_repo_config(dir, "exclude:\n  - node_modules\n  - .cache\n")
        result = described_class.load(dir)
        expect(result[:exclude]).to eq(["node_modules", ".cache"])
      end
    end

    it "aborts when exclude is not an array" do
      Dir.mktmpdir do |dir|
        write_repo_config(dir, "exclude: \"not-a-list\"\n")
        expect {
          described_class.load(dir)
        }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
          .and output(/missing or invalid "exclude"/).to_stderr
      end
    end

    it "defaults update to [] when absent" do
      Dir.mktmpdir do |dir|
        result = described_class.load(dir)
        expect(result[:update]).to eq([])
      end
    end

    it "loads update from repo config when present" do
      Dir.mktmpdir do |dir|
        write_repo_config(dir, "update:\n  - Gemfile.rails80.plugins.lock\n")
        result = described_class.load(dir)
        expect(result[:update]).to eq(["Gemfile.rails80.plugins.lock"])
      end
    end

    it "aborts when update is not an array" do
      Dir.mktmpdir do |dir|
        write_repo_config(dir, "update: \"not-a-list\"\n")
        expect {
          described_class.load(dir)
        }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
          .and output(/missing or invalid "update"/).to_stderr
      end
    end

    it "defaults empty_volumes to [] when absent" do
      Dir.mktmpdir do |dir|
        result = described_class.load(dir)
        expect(result[:empty_volumes]).to eq([])
      end
    end

    it "loads empty_volumes from repo config when present" do
      Dir.mktmpdir do |dir|
        write_repo_config(dir, "empty_volumes:\n  - log\n  - tmp\n")
        result = described_class.load(dir)
        expect(result[:empty_volumes]).to eq(["log", "tmp"])
      end
    end

    it "aborts when empty_volumes is not an array" do
      Dir.mktmpdir do |dir|
        write_repo_config(dir, "empty_volumes: \"not-a-list\"\n")
        expect {
          described_class.load(dir)
        }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
          .and output(/missing or invalid "empty_volumes"/).to_stderr
      end
    end

    it "silently ignores unknown keys" do
      Dir.mktmpdir do |dir|
        write_repo_config(dir, "copy_repo_paths:\n  - node_modules\n")
        result = described_class.load(dir)
        expect(result).to have_key(:update_volumes)
        expect(result).not_to have_key(:copy_repo_paths)
      end
    end

    it "defaults post_update_hooks to [] when absent" do
      Dir.mktmpdir do |dir|
        result = described_class.load(dir)
        expect(result[:post_update_hooks]).to eq([])
      end
    end

    it "loads post_update_hooks from repo config when present" do
      Dir.mktmpdir do |dir|
        write_repo_config(dir, "post_update_hooks:\n  - echo hello\n  - echo world\n")
        result = described_class.load(dir)
        expect(result[:post_update_hooks]).to eq(["echo hello", "echo world"])
      end
    end

    it "aborts when post_update_hooks is not an array of strings" do
      Dir.mktmpdir do |dir|
        write_repo_config(dir, "post_update_hooks: not_an_array\n")
        expect {
          described_class.load(dir)
        }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
          .and output(/missing or invalid "post_update_hooks"/).to_stderr
      end
    end

    it "defaults free_branch_prefix to FREE- when absent" do
      Dir.mktmpdir do |dir|
        result = described_class.load(dir)
        expect(result[:free_branch_prefix]).to eq("FREE-")
      end
    end

    it "loads free_branch_prefix from repo config when present" do
      Dir.mktmpdir do |dir|
        write_repo_config(dir, "free_branch_prefix: \"CTR-\"\n")
        result = described_class.load(dir)
        expect(result[:free_branch_prefix]).to eq("CTR-")
      end
    end

    it "aborts when free_branch_prefix is not a string" do
      Dir.mktmpdir do |dir|
        write_repo_config(dir, "free_branch_prefix:\n  - not\n  - a_string\n")
        expect {
          described_class.load(dir)
        }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
          .and output(/missing or invalid "free_branch_prefix"/).to_stderr
      end
    end
  end
end
