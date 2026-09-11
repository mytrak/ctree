# frozen_string_literal: true

RSpec.describe Ctree::Prompt do
  describe ".confirm" do
    it "returns true immediately when force and default is :yes, without reading stdin" do
      expect(Ctree::Prompt).not_to receive(:read_line)
      result = nil
      expect { result = Ctree::Prompt.confirm("proceed?", default: :yes, force: true) }
        .to output("").to_stdout
      expect(result).to eq(true)
    end

    it "returns false immediately when force and default is :no" do
      expect(Ctree::Prompt).not_to receive(:read_line)
      result = nil
      expect { result = Ctree::Prompt.confirm("proceed?", default: :no, force: true) }
        .to output("").to_stdout
      expect(result).to eq(false)
    end

    it "returns true immediately when force and default is nil (explicit-yes prompts)" do
      expect(Ctree::Prompt).not_to receive(:read_line)
      result = nil
      expect { result = Ctree::Prompt.confirm("Type 'yes' to confirm:", default: nil, force: true) }
        .to output("").to_stdout
      expect(result).to eq(true)
    end

    it "honors an empty answer as the :yes default when not forced" do
      allow(Ctree::Prompt).to receive(:read_line).and_return("")
      expect(Ctree::Prompt.confirm("proceed?", default: :yes)).to eq(true)
    end

    it "treats an explicit 'y' as yes when not forced" do
      allow(Ctree::Prompt).to receive(:read_line).and_return("y")
      expect(Ctree::Prompt.confirm("proceed?", default: :yes)).to eq(true)
    end

    it "returns false for 'n' when default is :yes and not forced" do
      allow(Ctree::Prompt).to receive(:read_line).and_return("n")
      expect(Ctree::Prompt.confirm("proceed?", default: :yes)).to eq(false)
    end

    it "returns false for an empty answer when default is :no and not forced" do
      allow(Ctree::Prompt).to receive(:read_line).and_return("")
      expect(Ctree::Prompt.confirm("proceed?", default: :no)).to eq(false)
    end

    it "returns true for 'yes' when default is :no and not forced" do
      allow(Ctree::Prompt).to receive(:read_line).and_return("yes")
      expect(Ctree::Prompt.confirm("proceed?", default: :no)).to eq(true)
    end

    it "requires the literal word 'yes' when default is nil and not forced" do
      allow(Ctree::Prompt).to receive(:read_line).and_return("sure")
      expect(Ctree::Prompt.confirm("Type 'yes' to confirm:", default: nil)).to eq(false)
    end

    it "accepts the literal word 'yes' when default is nil and not forced" do
      allow(Ctree::Prompt).to receive(:read_line).and_return("yes")
      expect(Ctree::Prompt.confirm("Type 'yes' to confirm:", default: nil)).to eq(true)
    end

    it "rejects 'y' (without the full word) when default is nil and not forced" do
      allow(Ctree::Prompt).to receive(:read_line).and_return("y")
      expect(Ctree::Prompt.confirm("Type 'yes' to confirm:", default: nil)).to eq(false)
    end

    it "prefixes the visible non-force read-line prompt with [ctree] and a trailing space" do
      expect(Ctree::Prompt).to receive(:read_line).with("[ctree] proceed? ")
      allow(Ctree::Prompt).to receive(:read_line).and_return("n")
      expect(Ctree::Prompt.confirm("proceed?", default: :yes)).to eq(false)
    end
  end

  describe ".for_env_var_change" do
    it "returns the current value immediately and skips stdin when force is true" do
      expect(Ctree::Prompt).not_to receive(:read_line)
      expect { Ctree::Prompt.for_env_var_change("KEY", "current", force: true) }
        .to output(/\[ctree\] KEY=current\n/).to_stdout
    end

    it "keeps the current value on an empty answer when not forced" do
      allow(Ctree::Prompt).to receive(:read_line).and_return("")
      expect(Ctree::Prompt.for_env_var_change("KEY", "current")).to eq("current")
    end

    it "returns the typed answer when not forced" do
      allow(Ctree::Prompt).to receive(:read_line).and_return("new-value")
      expect(Ctree::Prompt.for_env_var_change("KEY", "current")).to eq("new-value")
    end

    it "strips control characters from the typed answer when not forced" do
      allow(Ctree::Prompt).to receive(:read_line).and_return("new\x00value\x1b")
      expect(Ctree::Prompt.for_env_var_change("KEY", "current")).to eq("newvalue")
    end
  end
end