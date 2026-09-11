# frozen_string_literal: true

require "tmpdir"

RSpec.describe Ctree::LogFile do
  after { Ctree::LogFile.reset! }

  describe ".enabled?" do
    it "is false until configured" do
      expect(Ctree::LogFile.enabled?).to eq(false)
    end

    it "is true after configure" do
      Dir.mktmpdir do |dir|
        Ctree::LogFile.configure(File.join(dir, "ctree.log"))
        expect(Ctree::LogFile.enabled?).to eq(true)
      end
    end
  end

  describe ".configure" do
    it "creates the file if missing" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "ctree.log")
        Ctree::LogFile.configure(path)
        expect(File.exist?(path)).to eq(true)
      end
    end

    it "truncates the file if it already has content" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "ctree.log")
        File.write(path, "stale content\n")
        Ctree::LogFile.configure(path)
        expect(File.read(path)).to eq("")
      end
    end
  end

  describe ".path" do
    it "returns the configured path" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "ctree.log")
        Ctree::LogFile.configure(path)
        expect(Ctree::LogFile.path).to eq(path)
      end
    end
  end

  describe ".write" do
    it "is a no-op when not configured" do
      expect { Ctree::LogFile.write("hello") }.not_to raise_error
    end

    it "appends a timestamped line" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "ctree.log")
        Ctree::LogFile.configure(path)
        Ctree::LogFile.write("hello")
        Ctree::LogFile.write("world")
        lines = File.readlines(path)
        expect(lines.size).to eq(2)
        expect(lines[0]).to match(/\A\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] hello\n\z/)
        expect(lines[1]).to match(/\A\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] world\n\z/)
      end
    end
  end

  describe ".write_block" do
    it "is a no-op when not configured" do
      expect { Ctree::LogFile.write_block("hello\nworld") }.not_to raise_error
    end

    it "timestamps only the first non-blank line, leaving the rest untouched" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "ctree.log")
        Ctree::LogFile.configure(path)
        Ctree::LogFile.write_block("\nheader\n  detail one\n\n  detail two\n")
        lines = File.readlines(path)
        expect(lines[0]).to match(/\A\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] header\n\z/)
        expect(lines[1..]).to eq(["  detail one\n", "\n", "  detail two\n"])
      end
    end

    it "writes nothing when the block is entirely blank" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "ctree.log")
        Ctree::LogFile.configure(path)
        Ctree::LogFile.write_block("\n\n")
        expect(File.read(path)).to eq("")
      end
    end
  end
end
