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
    end
  end
end
