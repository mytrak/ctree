# frozen_string_literal: true

RSpec.describe Ctree::ComposeOverride do
  around do |ex|
    Dir.mktmpdir do |dir|
      @dir = Pathname.new(dir)
      ex.run
    end
  end

  let(:override_rel)    { "docker-compose.local.ctree.yml" }
  let(:override_path)   { @dir / override_rel }
  let(:source_project)  { "src" }
  let(:share_volumes)   { %w[yarn-cache gems] }
  let(:source_volumes)  { %w[src_yarn-cache src_gems] }

  def repair_call(sv: share_volumes, srcv: source_volumes)
    Ctree::ComposeOverride.fix(
      target_path:    @dir,
      override_rel:   override_rel,
      share_volumes:  sv,
      source_project: source_project,
      source_volumes: srcv
    )
  end

  def validate_call(sv: share_volumes, srcv: source_volumes)
    Ctree::ComposeOverride.check(
      target_path:    @dir,
      override_rel:   override_rel,
      share_volumes:  sv,
      source_project: source_project,
      source_volumes: srcv
    )
  end

  def audit_call(sv: share_volumes, srcv: source_volumes)
    Ctree::ComposeOverride.audit(
      target_path:    @dir,
      override_rel:   override_rel,
      share_volumes:  sv,
      source_project: source_project,
      source_volumes: srcv
    )
  end

  def parsed
    YAML.safe_load(override_path.read, aliases: true)
  end

  describe ".audit" do
    it "categorises all correct entries as ok" do
      override_path.write(<<~YAML)
        services:
          web:
            labels: []
        volumes:
          yarn-cache:
            external: true
            name: src_yarn-cache
          gems:
            external: true
            name: src_gems
      YAML

      result = audit_call
      expect(result[:ok]).to contain_exactly("yarn-cache", "gems")
      expect(result[:fixable]).to be_empty
      expect(result[:unfixable]).to be_empty
    end

    it "categorises entries missing from Docker as unfixable" do
      override_path.write("services:\n  web:\n    labels: []\n")

      result = audit_call(sv: %w[missing-vol], srcv: [])
      expect(result[:unfixable]).to eq(["missing-vol"])
      expect(result[:fixable]).to be_empty
      expect(result[:ok]).to be_empty
    end

    it "categorises entries present in Docker but missing from override as fixable" do
      override_path.write("services:\n  web:\n    labels: []\n")

      result = audit_call
      expect(result[:fixable]).to contain_exactly("yarn-cache", "gems")
      expect(result[:unfixable]).to be_empty
      expect(result[:ok]).to be_empty
    end

    it "returns all unfixable when the override file does not exist" do
      result = audit_call
      expect(result[:unfixable]).to eq(share_volumes)
      expect(result[:ok]).to be_empty
      expect(result[:fixable]).to be_empty
    end

    it "returns all unfixable and logs a warning on YAML parse error" do
      override_path.write("{ bad: yaml: [")

      expect { result = audit_call }.to output(/could not parse/).to_stderr
    end
  end

  describe ".repair" do
    it "is a no-op when all external references are already correct" do
      override_path.write(<<~YAML)
        services:
          web:
            labels: []
        volumes:
          yarn-cache:
            external: true
            name: src_yarn-cache
          gems:
            external: true
            name: src_gems
      YAML

      original = override_path.read
      expect { repair_call }.not_to output.to_stderr
      expect(override_path.read).to eq(original)
    end

    it "fixes a missing external reference" do
      override_path.write(<<~YAML)
        services:
          web:
            labels: []
      YAML

      expect { repair_call }
        .to output(/fixed 2 share volumes in #{override_rel}.*yarn-cache.*gems/).to_stdout

      vols = parsed["volumes"]
      expect(vols["yarn-cache"]).to eq("external" => true, "name" => "src_yarn-cache")
      expect(vols["gems"]).to eq("external" => true, "name" => "src_gems")
    end

    it "fixes only the missing entry when one reference is already correct" do
      override_path.write(<<~YAML)
        services:
          web:
            labels: []
        volumes:
          yarn-cache:
            external: true
            name: src_yarn-cache
      YAML

      expect { repair_call }
        .to output(/fixed 1 share volume in #{override_rel}.*gems/).to_stdout

      vols = parsed["volumes"]
      expect(vols["yarn-cache"]).to eq("external" => true, "name" => "src_yarn-cache")
      expect(vols["gems"]).to eq("external" => true, "name" => "src_gems")
    end

    it "warns but does not modify the file when all source Docker volumes are absent" do
      override_path.write("services:\n  web:\n    labels: []\n")
      original = override_path.read

      expect {
        Ctree::ComposeOverride.fix(
          target_path:    @dir,
          override_rel:   override_rel,
          share_volumes:  %w[missing-vol],
          source_project: source_project,
          source_volumes: []
        )
      }.to output(/source volume src_missing-vol not found in Docker; skipping missing-vol/).to_stderr

      expect(override_path.read).to eq(original)
    end

    it "fixes fixable entries and warns about unfixable ones in the same pass" do
      override_path.write("services:\n  web:\n    labels: []\n")

      warnings = []
      allow(Ctree::Log).to receive(:warn_).and_wrap_original do |m, msg|
        warnings << msg
        m.call(msg)
      end

      Ctree::ComposeOverride.fix(
        target_path:    @dir,
        override_rel:   override_rel,
        share_volumes:  %w[yarn-cache missing-vol],
        source_project: source_project,
        source_volumes: %w[src_yarn-cache]
      )

      expect(warnings).to include(match(/source volume src_missing-vol not found in Docker; skipping missing-vol/))

      vols = parsed["volumes"]
      expect(vols["yarn-cache"]).to eq("external" => true, "name" => "src_yarn-cache")
      expect(vols).not_to have_key("missing-vol")
    end

    it "warns and returns false when the override file does not exist" do
      result = nil
      expect { result = repair_call }.to output(/not found; nothing to fix/).to_stderr
      expect(result).to eq(false)
    end

    it "is a no-op when share_volumes is empty" do
      override_path.write("services:\n  web:\n    labels: []\n")
      expect {
        Ctree::ComposeOverride.fix(
          target_path:    @dir,
          override_rel:   override_rel,
          share_volumes:  [],
          source_project: source_project,
          source_volumes: source_volumes
        )
      }.not_to output.to_stderr
    end

    it "preserves !override and !reset YAML tags when fixing" do
      override_path.write(<<~YAML)
        services:
          web:
            ports: !override []
            aliases: !reset []
      YAML

      repair_call

      content = override_path.read
      expect(content).to include("!override")
      expect(content).to include("!reset")
      vols = YAML.safe_load(content, aliases: true)["volumes"]
      expect(vols["yarn-cache"]).to eq("external" => true, "name" => "src_yarn-cache")
    end

    it "returns true when fixes are applied and false when nothing to fix" do
      override_path.write("services:\n  web:\n    labels: []\n")
      expect(repair_call).to eq(true)

      expect(repair_call).to eq(false)
    end
  end

  describe ".validate" do
    it "warns about unfixable volumes without modifying the file" do
      override_path.write("services:\n  web:\n    labels: []\n")
      original = override_path.read

      expect {
        Ctree::ComposeOverride.check(
          target_path:    @dir,
          override_rel:   override_rel,
          share_volumes:  %w[missing-vol],
          source_project: source_project,
          source_volumes: []
        )
      }.to output(/share volume 'missing-vol' missing from #{override_rel}/).to_stderr

      expect(override_path.read).to eq(original)
    end

    it "warns about fixable volumes and suggests repair without modifying the file" do
      override_path.write("services:\n  web:\n    labels: []\n")
      original = override_path.read

      warnings = []
      allow(Ctree::Log).to receive(:warn_).and_wrap_original do |m, msg|
        warnings << msg
        m.call(msg)
      end
      validate_call

      expect(warnings).to include(match(/2 share volumes missing external reference in #{override_rel}/))
      expect(warnings).to include(match(/run `ctree compose-config fix`/))
      expect(override_path.read).to eq(original)
    end

    it "is silent when all references are correct" do
      override_path.write(<<~YAML)
        volumes:
          yarn-cache:
            external: true
            name: src_yarn-cache
          gems:
            external: true
            name: src_gems
      YAML

      expect { validate_call }.not_to output.to_stderr
    end

    it "is a no-op when override_rel is empty" do
      expect {
        Ctree::ComposeOverride.check(
          target_path:    @dir,
          override_rel:   "",
          share_volumes:  share_volumes,
          source_project: source_project,
          source_volumes: source_volumes
        )
      }.not_to output.to_stderr
    end

    it "is a no-op when share_volumes is empty" do
      override_path.write("services:\n  web:\n    labels: []\n")
      expect {
        Ctree::ComposeOverride.check(
          target_path:    @dir,
          override_rel:   override_rel,
          share_volumes:  [],
          source_project: source_project,
          source_volumes: source_volumes
        )
      }.not_to output.to_stderr
    end
  end
end
