# frozen_string_literal: true

require "stringio"
require "tmpdir"

RSpec.describe Ctree::Log do
  describe ".section" do
    it "puts the text as-is to the console when no log file is active" do
      expect { Ctree::Log.section("line one\nline two") }
        .to output("line one\nline two\n").to_stdout
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

      it "timestamps only the first line, leaving the rest of the block as-is" do
        Ctree::Log.section("line one\n\nline two")
        lines = File.readlines(@log_path)
        expect(lines.size).to eq(3)
        expect(lines[0]).to match(/\A\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] line one\n\z/)
        expect(lines[1]).to eq("\n")
        expect(lines[2]).to eq("line two\n")
      end

      it "skips leading blank lines so the timestamp lands on the first real content" do
        Ctree::Log.section("\n\nline one\nline two")
        lines = File.readlines(@log_path)
        expect(lines.size).to eq(2)
        expect(lines[0]).to match(/\A\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] line one\n\z/)
        expect(lines[1]).to eq("line two\n")
      end

      it "shows the text live on the console, pauses the scroller, and logs it when interactive and not forced" do
        expect(Ctree::Scroller).to receive(:pause)
        expect { Ctree::Log.section("line one\nline two", interactive: true, force: false) }
          .to output("line one\nline two\n").to_stdout
        expect(File.read(@log_path)).to include("line one")
      end

      it "is skipped entirely — console and file — when interactive but forced" do
        expect(Ctree::Scroller).not_to receive(:pause)
        expect { Ctree::Log.section("line one\nline two", interactive: true, force: true) }
          .to output("").to_stdout
        expect(File.read(@log_path)).to eq("")
      end

      it "stays silent on the console when not interactive" do
        expect(Ctree::Scroller).not_to receive(:pause)
        expect { Ctree::Log.section("line one\nline two") }
          .to output("").to_stdout
      end
    end
  end
end
