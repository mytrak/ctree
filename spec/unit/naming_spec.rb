# frozen_string_literal: true

RSpec.describe Ctree::Naming do
  describe ".sanitize_compose_project_name" do
    it "lowercases and replaces unsupported chars with _" do
      expect(described_class.sanitize_compose_project_name("My Project!")).to eq("my_project_")
    end

    it "strips leading non-alphanumeric chars" do
      expect(described_class.sanitize_compose_project_name("__abc")).to eq("abc")
    end

    it "preserves underscores and hyphens" do
      expect(described_class.sanitize_compose_project_name("foo_bar-baz")).to eq("foo_bar-baz")
    end

    it "lowercases an all-uppercase input" do
      expect(described_class.sanitize_compose_project_name("MYAPP")).to eq("myapp")
    end
  end
end

RSpec.describe "Ctree name patterns" do
  describe "NAME_PATTERN" do
    it "accepts lowercase alphanumeric with - and _" do
      %w[foo abc123 a-b a_b f1].each { |n| expect(n).to match(Ctree::NAME_PATTERN) }
    end

    it "rejects names starting with - or _" do
      %w[-foo _foo].each { |n| expect(n).not_to match(Ctree::NAME_PATTERN) }
    end

    it "rejects uppercase or special chars" do
      ["Foo", "foo/bar", "foo.bar"].each { |n| expect(n).not_to match(Ctree::NAME_PATTERN) }
    end

    it "rejects empty string" do
      expect("").not_to match(Ctree::NAME_PATTERN)
    end
  end

  describe "BRANCH_NAME_PATTERN" do
    it "accepts uppercase, slashes and dots" do
      ["Feature", "foo/bar", "foo.bar", "a1.b/c"].each { |n| expect(n).to match(Ctree::BRANCH_NAME_PATTERN) }
    end

    it "rejects branch starting with /" do
      expect("/foo").not_to match(Ctree::BRANCH_NAME_PATTERN)
    end

    it "rejects branch with whitespace" do
      expect("foo bar").not_to match(Ctree::BRANCH_NAME_PATTERN)
    end
  end
end
