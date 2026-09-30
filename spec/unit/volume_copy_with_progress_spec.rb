# frozen_string_literal: true

require "stringio"
require "tmpdir"

RSpec.describe Ctree::Volume do
  describe ".copy_with_progress" do
    around do |ex|
      original_debug = Ctree::Log.debug?
      Ctree::Log.debug_mode = true
      ex.run
      Ctree::Log.debug_mode = original_debug
    end

    def stub_popen3(lines:, success: true)
      allow(Ctree::Sh).to receive(:popen3) do |*_cmd, &blk|
        stdout = StringIO.new(lines.join)
        stderr = StringIO.new("")
        wait_thr = instance_double(Thread, value: fake_status(success))
        blk.call(nil, stdout, stderr, wait_thr)
      end
    end

    def fake_status(success)
      instance_double(
        Process::Status,
        success?: success,
        exitstatus: success ? 0 : 1
      )
    end

    it "writes only the past-tense completion line to the log file, independent of debug mode" do
      Dir.mktmpdir do |dir|
        log_path = File.join(dir, "ctree.log")
        Ctree::LogFile.configure(log_path)
        stub_popen3(lines: ["TOTAL:100\n", "PROGRESS:100\n"])

        out = StringIO.new
        allow(out).to receive(:tty?).and_return(true)
        original_stdout = $stdout
        $stdout = out
        begin
          Ctree::Volume.copy_with_progress("src_vol", "tgt_vol", live: true)
        ensure
          $stdout = original_stdout
        end
        expect(out.string).to eq("")
        log_contents = File.read(log_path)
        expect(log_contents).not_to include("copying src_vol -> tgt_vol")
        expect(log_contents).to match(/copied src_vol -> tgt_vol \(\S+ in \d+s\)/)
        expect(log_contents.scan("copied src_vol -> tgt_vol").size).to eq(1)
      end
    ensure
      Ctree::LogFile.reset!
    end

    it "does not duplicate the completion line in the log file when debug mode is on (CTR-055)" do
      Dir.mktmpdir do |dir|
        log_path = File.join(dir, "ctree.log")
        Ctree::LogFile.configure(log_path)
        stub_popen3(lines: ["TOTAL:100\n", "PROGRESS:100\n"])

        original_stdout = $stdout
        $stdout = StringIO.new
        begin
          Ctree::Volume.copy_with_progress("src_vol", "tgt_vol", live: true)
        ensure
          $stdout = original_stdout
        end

        completion_lines = File.readlines(log_path).select { |l| l.include?("copied src_vol -> tgt_vol") }
        expect(completion_lines.size).to eq(1)
      end
    ensure
      Ctree::LogFile.reset!
    end

    it "still writes the present-tense line to the console for piped runs without a log file" do
      allow($stdout).to receive(:tty?).and_return(false)
      stub_popen3(lines: ["TOTAL:100\n", "PROGRESS:100\n"])
      out = StringIO.new
      original_stdout = $stdout
      $stdout = out
      begin
        Ctree::Volume.copy_with_progress("src_vol", "tgt_vol", live: true)
      ensure
        $stdout = original_stdout
      end
      expect(out.string).to include("copying src_vol -> tgt_vol")
    end

    it "still prints the present-tense line on the console when --log-file is active (non-TTY)" do
      allow($stdout).to receive(:tty?).and_return(false)
      Dir.mktmpdir do |dir|
        log_path = File.join(dir, "ctree.log")
        Ctree::LogFile.configure(log_path)
        stub_popen3(lines: ["TOTAL:100\n", "PROGRESS:100\n"])
        out = StringIO.new
        original_stdout = $stdout
        $stdout = out
        begin
          Ctree::Volume.copy_with_progress("src_vol", "tgt_vol", live: true)
        ensure
          $stdout = original_stdout
        end
        expect(out.string).to include("copying src_vol -> tgt_vol")
      end
    ensure
      Ctree::LogFile.reset!
    end

    it "prints no plain start line on a TTY (spinner owns the console)" do
      out = StringIO.new
      allow(out).to receive(:tty?).and_return(true)
      stub_popen3(lines: ["TOTAL:100\n", "PROGRESS:100\n"])
      original_stdout = $stdout
      $stdout = out
      begin
        Ctree::Volume.copy_with_progress("src_vol", "tgt_vol", live: true)
      ensure
        $stdout = original_stdout
      end
      expect(out.string).not_to include("copying src_vol -> tgt_vol")
    end
  end
end
