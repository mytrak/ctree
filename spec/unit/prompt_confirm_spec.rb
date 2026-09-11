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

    context "with a log file configured" do
      around do |ex|
        Dir.mktmpdir do |dir|
          @log_path = File.join(dir, "ctree.log")
          Ctree::LogFile.configure(@log_path)
          ex.run
        end
        Ctree::LogFile.reset!
      end

      it "pauses/resumes the scroller and logs the question and answer" do
        allow(Ctree::Prompt).to receive(:read_line).and_return("n")
        expect(Ctree::Scroller).to receive(:pause).ordered
        expect(Ctree::Scroller).to receive(:resume).ordered

        expect(Ctree::Prompt.confirm("proceed?", default: :yes)).to eq(false)

        contents = File.read(@log_path)
        expect(contents).to include("PROMPT: proceed?")
        expect(contents).to include("ANSWER: n")
      end

      it "does not pause/resume or log anything when forced" do
        expect(Ctree::Scroller).not_to receive(:pause)
        expect(Ctree::Scroller).not_to receive(:resume)
        expect(Ctree::Prompt.confirm("proceed?", default: :yes, force: true)).to eq(true)
        expect(File.read(@log_path)).to eq("")
      end

      it "logs a non-blank answer when the user just presses enter for the default" do
        allow(Ctree::Prompt).to receive(:read_line).and_return("")
        expect(Ctree::Prompt.confirm("proceed?", default: :yes)).to eq(true)
        expect(File.read(@log_path)).to include("ANSWER: (empty, default) -> yes")
      end
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

    context "with a log file configured" do
      around do |ex|
        Dir.mktmpdir do |dir|
          @log_path = File.join(dir, "ctree.log")
          Ctree::LogFile.configure(@log_path)
          ex.run
        end
        Ctree::LogFile.reset!
      end

      it "pauses/resumes the scroller and logs the question and answer" do
        allow(Ctree::Prompt).to receive(:read_line).and_return("new-value")
        expect(Ctree::Scroller).to receive(:pause).ordered
        expect(Ctree::Scroller).to receive(:resume).ordered

        expect(Ctree::Prompt.for_env_var_change("KEY", "current")).to eq("new-value")

        contents = File.read(@log_path)
        expect(contents).to include("KEY=current")
        expect(contents).to include("PROMPT: KEY=current")
        expect(contents).to include("ANSWER: new-value")
      end

      it "logs nothing at all and skips prompting/stdin when forced" do
        expect(Ctree::Prompt).not_to receive(:read_line)
        expect(Ctree::Scroller).not_to receive(:pause)
        expect(Ctree::Prompt.for_env_var_change("KEY", "current", force: true)).to eq("current")
        expect(File.read(@log_path)).to eq("")
      end

      it "logs only the PROMPT and ANSWER lines — no separate header/announcement line" do
        allow(Ctree::Prompt).to receive(:read_line).and_return("new-value")
        Ctree::Prompt.for_env_var_change("KEY", "current")
        lines = File.readlines(@log_path)
        expect(lines.size).to eq(2)
        expect(lines[0]).to match(/PROMPT: KEY=current /)
        expect(lines[1]).to match(/ANSWER: new-value/)
      end

      it "folds sibling worktree values into the PROMPT line instead of raw indented lines" do
        allow(Ctree::Prompt).to receive(:read_line).and_return("new-value")
        Ctree::Prompt.for_env_var_change("KEY", "current", worktree_values: { "wt1" => "a", "wt2" => "b" })
        prompt_line = File.readlines(@log_path).first
        expect(prompt_line).to include("PROMPT: KEY=current (worktree values: wt1=a, wt2=b) (enter to keep")
      end

      it "logs a non-blank answer when the user just presses enter to keep the default" do
        allow(Ctree::Prompt).to receive(:read_line).and_return("")
        expect(Ctree::Prompt.for_env_var_change("KEY", "current")).to eq("current")
        expect(File.read(@log_path)).to include("ANSWER: (empty, kept current)")
      end
    end
  end
end