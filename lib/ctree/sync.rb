# frozen_string_literal: true

module Ctree
  module Sync
    module_function

    def run(force: false, log_file: nil)
      if log_file
        $stdout = File.open(log_file, 'a')
        $stderr = $stdout
      end

      begin
        Ctree::Rebase.run(force: force)
        Ctree::Update.run(force: force)
      ensure
        if log_file
          $stdout = STDOUT
          $stderr = STDERR
        end
      end
    end
  end
end