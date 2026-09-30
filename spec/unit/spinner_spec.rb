# frozen_string_literal: true

require "stringio"
require "tmpdir"

RSpec.describe Ctree::Spinner do
  describe ".with_spinner" do
    context "with a log file configured" do
      around do |ex|
        Dir.mktmpdir do |dir|
          @log_path = File.join(dir, "ctree.log")
          Ctree::LogFile.configure(@log_path)
          ex.run
        end
        Ctree::LogFile.reset!
      end

      it "does not log the present-tense progress message, only whatever the block itself logs" do
        result = Ctree::Spinner.with_spinner("removing 3 volume(s)") do
          Ctree::Log.info "deleted 3 volume(s): a, b, c"
          :ok
        end

        expect(result).to eq(:ok)
        contents = File.read(@log_path)
        expect(contents).not_to include("removing 3 volume(s)")
        expect(contents).to include("deleted 3 volume(s): a, b, c")
      end

      it "still runs and returns the block's value when the block logs nothing" do
        result = Ctree::Spinner.with_spinner("some progress label") { 42 }
        expect(result).to eq(42)
        expect(File.read(@log_path)).to eq("")
      end
    end

    context "without a log file" do
      it "prints the progress label once on a non-tty console" do
        allow($stdout).to receive(:tty?).and_return(false)
        expect { Ctree::Spinner.with_spinner("doing thing") { :ok } }
          .to output("[ctree] doing thing\n").to_stdout
      end

      it "includes the progress label in the animated spinner line on a tty" do
        allow($stdout).to receive(:tty?).and_return(true)
        # Capture stdout during the spinner execution using a StringIO buffer
        output = StringIO.new
        original_stdout = $stdout
        $stdout = output
        begin
          Ctree::Spinner.with_spinner("rebasing free003 onto master") { sleep 0.15 }
        ensure
          $stdout = original_stdout
        end
        result = output.string
        expect(result).to include("rebasing free003 onto master")
      end
    end
  describe ".with_progress" do
    context "with a log file configured" do
      around do |ex|
        Dir.mktmpdir do |dir|
          @log_path = File.join(dir, "ctree.log")
          Ctree::LogFile.configure(@log_path)
          ex.run
        end
        Ctree::LogFile.reset!
      end

      it "yields silently under --log-file" do
        result = Ctree::Spinner.with_progress("progress msg") { :done }
        expect(result).to eq(:done)
        expect(File.read(@log_path)).to eq("")
      end
    end

    context "without a log file" do
      it "returns the block result" do
        expect(Ctree::Spinner.with_progress("label") { 42 }).to eq(42)
      end

      it "prints one prefixed line on non-TTY stdout and does not redraw" do
        $stdout = StringIO.new
        allow($stdout).to receive(:tty?).and_return(false)
        out = Ctree::Spinner.with_progress("running hook") { :done }
        expect($stdout.string).to eq("[ctree] running hook\n")
        expect($stdout.string).not_to include("\r")
        expect(out).to eq(:done)
      end

      it "prints the same single line on TTY stdout (no spinner frames)" do
        $stdout = StringIO.new
        allow($stdout).to receive(:tty?).and_return(true)
        out = String.new
        $stdout.string = out
        Ctree::Spinner.with_progress("running hook") { out << "hook-output\n" }
        expect(out).to eq("[ctree] running hook\nhook-output\n")
        expect(out).not_to include("(")
        expect(out).not_to include("\r")
      end

      it "propagates exceptions from the block" do
        $stdout = StringIO.new
        allow($stdout).to receive(:tty?).and_return(false)
        expect { Ctree::Spinner.with_progress("x") { raise "boom" } }
          .to raise_error("boom")
      end
    end
  end
  end
end
