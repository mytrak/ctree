# frozen_string_literal: true

RSpec.describe Ctree::EnvFile do
  describe ".parse" do
    it "returns {} for missing file" do
      expect(described_class.parse("/nonexistent/path/.env")).to eq({})
    end

    it "parses simple key=value" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".env")
        File.write(path, "FOO=bar\nBAZ=qux\n")
        expect(described_class.parse(path)).to eq("FOO" => "bar", "BAZ" => "qux")
      end
    end

    it "strips matching surrounding quotes (single and double)" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".env")
        File.write(path, %(A="hello"\nB='world'\nC=plain\n))
        expect(described_class.parse(path)).to eq("A" => "hello", "B" => "world", "C" => "plain")
      end
    end

    it "skips comments and blank lines" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".env")
        File.write(path, "# a comment\n\nFOO=1\n  \n# another\nBAR=2\n")
        expect(described_class.parse(path)).to eq("FOO" => "1", "BAR" => "2")
      end
    end

    it "strips leading 'export '" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".env")
        File.write(path, "export X=1\n")
        expect(described_class.parse(path)).to eq("X" => "1")
      end
    end

    it "ignores lines without '='" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".env")
        File.write(path, "garbage\nFOO=1\n")
        expect(described_class.parse(path)).to eq("FOO" => "1")
      end
    end
  end

  describe ".upsert" do
    it "creates the file with the new line if missing" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".env")
        expect(described_class.upsert(path, "FOO", "bar")).to eq(:created)
        expect(File.read(path)).to eq("FOO=bar\n")
      end
    end

    it "replaces an existing key in place, preserving newline" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".env")
        File.write(path, "A=1\nFOO=old\nB=2\n")
        expect(described_class.upsert(path, "FOO", "new")).to eq(:replaced)
        expect(File.read(path)).to eq("A=1\nFOO=new\nB=2\n")
      end
    end

    it "appends if the key is missing, ensuring trailing newline" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".env")
        File.write(path, "A=1")
        expect(described_class.upsert(path, "FOO", "bar")).to eq(:appended)
        expect(File.read(path)).to eq("A=1\nFOO=bar\n")
      end
    end

    it "preserves existing trailing newline when appending" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".env")
        File.write(path, "A=1\n")
        expect(described_class.upsert(path, "FOO", "bar")).to eq(:appended)
        expect(File.read(path)).to eq("A=1\nFOO=bar\n")
      end
    end
  end

  describe ".delete" do
    it "removes the matching key line" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".env")
        File.write(path, "A=1\nFOO=bar\nB=2\n")
        described_class.delete(path, "FOO")
        expect(File.read(path)).to eq("A=1\nB=2\n")
      end
    end

    it "is a no-op when the key is not present" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, ".env")
        File.write(path, "A=1\n")
        described_class.delete(path, "MISSING")
        expect(File.read(path)).to eq("A=1\n")
      end
    end

    it "is a no-op when the file does not exist" do
      expect { described_class.delete("/nonexistent/path/.env", "FOO") }.not_to raise_error
    end
  end
end
