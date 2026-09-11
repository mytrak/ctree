# frozen_string_literal: true

require "stringio"

RSpec.describe Ctree::Scroller do
  around do |ex|
    original = $stdout
    $stdout = StringIO.new
    ex.run
    $stdout = original
  end

  after { Ctree::Scroller.stop }

  describe ".start" do
    it "prints the message once on a non-tty stdout, without spawning a thread" do
      allow($stdout).to receive(:tty?).and_return(false)
      Ctree::Scroller.start("doing thing")
      expect($stdout.string).to include("[ctree] doing thing")
    end
  end

  describe ".pause / .resume / .stop" do
    it "are safe no-ops when start was never called" do
      expect { Ctree::Scroller.pause }.not_to raise_error
      expect { Ctree::Scroller.resume }.not_to raise_error
      expect { Ctree::Scroller.stop }.not_to raise_error
    end

    it "stop is idempotent" do
      allow($stdout).to receive(:tty?).and_return(false)
      Ctree::Scroller.start("doing thing")
      expect { Ctree::Scroller.stop }.not_to raise_error
      expect { Ctree::Scroller.stop }.not_to raise_error
    end
  end

  describe ".stop with a final message" do
    it "prints the past-tense message with elapsed time on a non-tty console" do
      allow($stdout).to receive(:tty?).and_return(false)
      Ctree::Scroller.start("doing thing")
      Ctree::Scroller.stop("did thing")
      expect($stdout.string).to include("[ctree] did thing (0s)")
    end

    it "prints nothing extra when no final message is given" do
      allow($stdout).to receive(:tty?).and_return(false)
      Ctree::Scroller.start("doing thing")
      $stdout.string = ""
      Ctree::Scroller.stop
      expect($stdout.string).to eq("")
    end
  end
end
