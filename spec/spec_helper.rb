# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "ctree"

require "tmpdir"
require "fileutils"

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
  config.mock_with :rspec do |m|
    m.verify_partial_doubles = true
  end
  config.filter_run_excluding docker: true
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  config.after do
    Ctree::LogFile.reset!
    Ctree::Log.reset!
  end
end

# Shared status double that quacks like Process::Status.
def fake_status(success)
  instance_double(Process::Status, success?: success)
end

# Selectively stub Ctree::Sh so docker/* calls return canned responses while
# git/* and other commands shell out for real.
#
# `docker_capture3_responses` is consumed in order on docker capture3 calls.
# Each entry is either a [stdout, stderr, success_bool] tuple or
# [stdout, stderr, status_object]. Raises if exhausted.
#
# `docker_system_responses` is consumed in order on docker Sh.system calls.
# Each entry is a bool.
module CtreeShStub
  def stub_sh(docker_capture3:, docker_system: [])
    @docker_capture3 = docker_capture3.dup
    @docker_system = docker_system.dup
    @capture3_calls = []

    allow(Ctree::Sh).to receive(:capture3) do |*cmd, **opts|
      @capture3_calls << [cmd, opts]
      if cmd.first == "docker"
        resp = @docker_capture3.shift
        raise "unexpected docker capture3 call: #{cmd.inspect}" unless resp
        out, err, st = resp
        st = fake_status(st) if st == true || st == false
        [out, err, st]
      else
        Open3.capture3(*cmd, **opts)
      end
    end

    allow(Ctree::Sh).to receive(:system) do |*cmd, **kw|
      if cmd.first == "docker"
        resp = @docker_system.shift
        raise "unexpected docker system call: #{cmd.inspect}" if resp.nil?
        resp
      else
        Kernel.system(*cmd, **kw)
      end
    end

    allow(Ctree::Sh).to receive(:popen3).and_raise("popen3 not stubbed; integration specs should not exercise volume copy directly")

    # Sh.spawn / Sh.detach back the background-detached rm -rf in
    # Ctree::Delete. Default to a fake pid and a no-op detach so tests
    # don't actually fork rm processes or interfere with Open3 internals
    # (which use the real Process.detach).
    allow(Ctree::Sh).to receive(:spawn).and_return(123_456)
    allow(Ctree::Sh).to receive(:detach)
  end

  # Every capture3 call routed through the stub, as [cmd, opts] pairs.
  def capture3_calls
    @capture3_calls
  end
end

RSpec.configure { |c| c.include CtreeShStub }
