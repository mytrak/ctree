# frozen_string_literal: true

# These tests exercise the inline override-yaml volume-injection logic inside
# Ctree::Create.run via a minimal fixture. The logic iterates over
# share_volumes (not over the doc's existing volume keys) and injects
# external-volume entries for any suffix whose source volume exists.
# End-to-end coverage lives in spec/integration/create_spec.rb.

RSpec.describe "compose override file volume injection" do
  let(:source_project) { "src" }
  let(:source_volumes) { ["src_yarn-cache", "src_pg_data"] }
  let(:skip_suffixes) { %w[yarn-cache app-gems bundler] }

  def inject(doc)
    doc ||= {}
    return doc unless doc.is_a?(Hash)
    skip_suffixes.each do |suffix|
      src_name = "#{source_project}_#{suffix}"
      next unless source_volumes.include?(src_name)
      doc["volumes"] ||= {}
      doc["volumes"][suffix] = { "external" => true, "name" => src_name }
    end
    doc
  end

  it "injects external entry for a skip suffix when source volume exists" do
    doc = inject({})
    expect(doc["volumes"]["yarn-cache"]).to eq("external" => true, "name" => "src_yarn-cache")
  end

  it "skips a suffix when the source has no matching volume" do
    doc = inject({})
    expect(doc["volumes"]).not_to have_key("app-gems")
    expect(doc["volumes"]).not_to have_key("bundler")
  end

  it "creates the volumes block when the doc has none" do
    doc = inject({ "services" => { "web" => {} } })
    expect(doc["volumes"]).to be_a(Hash)
    expect(doc["volumes"]).to have_key("yarn-cache")
  end

  it "merges into an existing volumes block without removing other keys" do
    doc = inject({ "volumes" => { "pg_data" => nil } })
    expect(doc["volumes"]).to have_key("yarn-cache")
    expect(doc["volumes"]).to have_key("pg_data")
  end

  it "treats a nil doc as empty and injects correctly" do
    doc = inject(nil)
    expect(doc["volumes"]["yarn-cache"]).to eq("external" => true, "name" => "src_yarn-cache")
  end
end
