# frozen_string_literal: true

require "tmpdir"

RSpec.describe Ctree::Volume do
  describe ".rsync_with_progress" do
    let(:rsync_stats) do
      "Number of files: 3\n" \
        "Total file size: 43,433,984 bytes\n" \
        "Total transferred file size: 1,024 bytes\n"
    end

    around do |ex|
      Dir.mktmpdir do |dir|
        @log_path = File.join(dir, "ctree.log")
        ex.run
      end
    end

    def stub_rsync(stdout:, success: true)
      allow(Ctree::Sh).to receive(:capture3).and_return([stdout, "boom", fake_status(success)])
    end

    it "returns the total volume size, not the transferred size" do
      stub_rsync(stdout: rsync_stats)

      _, _, bytes = described_class.rsync_with_progress("src_vol", "tgt_vol")

      expect(bytes).to eq(43_433_984)
    end

    it "writes one completion line with the size to the log file" do
      Ctree::LogFile.configure(@log_path)
      stub_rsync(stdout: rsync_stats)

      described_class.rsync_with_progress("src_vol", "tgt_vol")

      lines = File.readlines(@log_path).select { |l| l.include?("updated src_vol -> tgt_vol") }
      expect(lines.size).to eq(1)
      expect(lines.first).to match(/updated src_vol -> tgt_vol \(41\.4MB\)$/)
    end

    it "writes the same single line when debug mode is on" do
      Ctree::LogFile.configure(@log_path)
      Ctree::Log.debug_mode = true
      stub_rsync(stdout: rsync_stats)

      described_class.rsync_with_progress("src_vol", "tgt_vol")

      expect(File.read(@log_path).scan("updated src_vol -> tgt_vol").size).to eq(1)
    end

    it "returns nil for the size when rsync prints no total size" do
      stub_rsync(stdout: "")

      _, _, bytes = described_class.rsync_with_progress("src_vol", "tgt_vol")

      expect(bytes).to be_nil
    end

    it "shows 0B for an empty volume" do
      Ctree::LogFile.configure(@log_path)
      stub_rsync(stdout: "Total file size: 0 bytes\n")

      described_class.rsync_with_progress("src_vol", "tgt_vol")

      expect(File.read(@log_path)).to match(/updated src_vol -> tgt_vol \(0B\)\n/)
    end

    it "adds no size when rsync prints no total size" do
      Ctree::LogFile.configure(@log_path)
      stub_rsync(stdout: "")

      described_class.rsync_with_progress("src_vol", "tgt_vol")

      expect(File.read(@log_path)).to match(/updated src_vol -> tgt_vol\n/)
    end

    it "writes no completion line when rsync fails" do
      Ctree::LogFile.configure(@log_path)
      stub_rsync(stdout: rsync_stats, success: false)

      st, err, _ = described_class.rsync_with_progress("src_vol", "tgt_vol")

      expect(st.success?).to eq(false)
      expect(err).to eq("boom")
      expect(File.read(@log_path)).not_to include("updated src_vol")
    end

    it "prints the completion line on the console in debug mode when no log file is configured" do
      Ctree::Log.debug_mode = true
      stub_rsync(stdout: rsync_stats)

      expect { described_class.rsync_with_progress("src_vol", "tgt_vol") }
        .to output(/updated src_vol -> tgt_vol \(41\.4MB\)/).to_stdout
    end

    it "prints no completion line on the console at info level when no log file is configured" do
      stub_rsync(stdout: rsync_stats)

      expect { described_class.rsync_with_progress("src_vol", "tgt_vol") }
        .not_to output(/updated src_vol/).to_stdout
    end

    it "keeps the console clear of the completion line when a log file is configured" do
      Ctree::LogFile.configure(@log_path)
      Ctree::Log.debug_mode = true
      stub_rsync(stdout: rsync_stats)

      expect { described_class.rsync_with_progress("src_vol", "tgt_vol") }
        .not_to output(/updated src_vol/).to_stdout
    end
  end
end
