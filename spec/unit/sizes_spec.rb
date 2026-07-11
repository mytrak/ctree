# frozen_string_literal: true

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
end
