# frozen_string_literal: true

require "tmpdir"

RSpec.describe Ctree::Sizes do
  describe ".human" do
    it "returns 0B for nil" do
      expect(described_class.human(nil)).to eq("0B")
    end

    it "returns 0B for zero" do
      expect(described_class.human(0)).to eq("0B")
    end

    it "renders bytes" do
      expect(described_class.human(512)).to eq("512.0B")
    end

    it "renders KB" do
      expect(described_class.human(2048)).to eq("2.0KB")
    end

    it "renders MB" do
      expect(described_class.human(5 * 1024 * 1024)).to eq("5.0MB")
    end

    it "renders GB" do
      expect(described_class.human(3 * 1024**3)).to eq("3.0GB")
    end

    it "caps at TB" do
      huge = 5 * 1024**5
      expect(described_class.human(huge)).to end_with("TB")
    end
  end

  describe ".note" do
    it "returns an empty string when the size is unknown" do
      expect(described_class.note(nil)).to eq("")
    end

    it "renders a zero size as 0B" do
      expect(described_class.note(0)).to eq(" (0B)")
    end

    it "renders the size in parentheses after a space" do
      expect(described_class.note(2048)).to eq(" (2.0KB)")
    end
  end

  describe ".path_bytes" do
    around do |ex|
      Dir.mktmpdir do |dir|
        @dir = Pathname.new(dir)
        ex.run
      end
    end

    it "returns the size of a regular file" do
      File.write(@dir / "a.lock", "x" * 2048)

      expect(described_class.path_bytes(@dir / "a.lock")).to eq(2048)
    end

    it "sums the regular files in nested directories, dotfiles included" do
      FileUtils.mkdir_p(@dir / "assets" / "sub")
      File.write(@dir / "assets" / "a.bin", "x" * 1024)
      File.write(@dir / "assets" / "sub" / "b.bin", "x" * 512)
      File.write(@dir / "assets" / ".hidden", "x" * 256)

      expect(described_class.path_bytes(@dir / "assets")).to eq(1792)
    end

    it "does not count symlinks inside a directory" do
      FileUtils.mkdir_p(@dir / "assets")
      File.write(@dir / "big.bin", "x" * 4096)
      File.symlink(@dir / "big.bin", @dir / "assets" / "link")

      expect(described_class.path_bytes(@dir / "assets")).to eq(0)
    end

    it "returns zero for an empty directory" do
      FileUtils.mkdir_p(@dir / "empty")

      expect(described_class.path_bytes(@dir / "empty")).to eq(0)
    end
  end
end
