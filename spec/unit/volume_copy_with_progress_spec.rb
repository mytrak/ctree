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

    it "routes the start/finish debug lines to the log file instead of the console when active" do
      Dir.mktmpdir do |dir|
        log_path = File.join(dir, "ctree.log")
        Ctree::LogFile.configure(log_path)
        allow($stdout).to receive(:tty?).and_return(true)
        stub_popen3(lines: ["TOTAL:100\n", "PROGRESS:100\n"])

        out = StringIO.new
        original_stdout = $stdout
        $stdout = out
        begin
          Ctree::Volume.copy_with_progress("src_vol", "tgt_vol")
        ensure
          $stdout = original_stdout
        end

        expect(out.string).to eq("")
        log_contents = File.read(log_path)
        expect(log_contents).to include("copying src_vol -> tgt_vol")
        expect(log_contents).to include("copied src_vol -> tgt_vol")
      end
    ensure
      Ctree::LogFile.reset!
    end
  end
end
