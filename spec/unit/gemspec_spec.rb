# frozen_string_literal: true

require "pathname"
require "rubygems/specification"

RSpec.describe "ctree.gemspec" do
  let(:root) { Pathname.new(__dir__).parent.parent }
  let(:spec) { Gem::Specification.load((root / "ctree.gemspec").to_s) }

  it "declares no runtime dependencies" do
    # fiddle and reline are default gems on Ruby >= 3.0 and are required in
    # lib/ctree.rb with graceful fallbacks; they must not be gem dependencies.
    expect(spec.runtime_dependencies.map(&:name)).to be_empty
  end

  it "declares rspec as the only development dependency" do
    expect(spec.development_dependencies.map(&:name)).to eq(["rspec"])
  end

  it "requires Ruby 3.0 or newer" do
    expect(spec.required_ruby_version.to_s).to eq(">= 3.0")
  end

  it "declares the metadata RubyGems requires for publication" do
    expect(spec.metadata).to include("rubygems_mfa_required" => "true")
    expect(spec.metadata).to include("source_code_uri" => "https://github.com/mytrak/ctree")
  end

  it "packages the source, the executable, and the docs" do
    expect(spec.files).to include(
      "bin/ctree",
      "lib/ctree.rb",
      "lib/ctree/config.yml",
      "README.md",
      "LICENSE",
      "CHANGELOG.md"
    )
    expect(spec.executables).to eq(["ctree"])
  end

  it "excludes build artifacts, docs, and repo-only files from the package" do
    expect(spec.files.select { |f| f =~ /\.gem\z|\Adocs\// }).to be_empty
    expect(spec.files).not_to include("Rakefile", "Gemfile", "Gemfile.lock")
  end

  it "matches the newest released version in the changelog" do
    released = root.join("CHANGELOG.md").read.scan(/^## \[([^\]]+)\]/).flatten - ["Unreleased"]

    expect(released.first).to eq(Ctree::VERSION)
  end
end
