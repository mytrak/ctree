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
        begin
          Ctree::Rebase.run(force: force)
        rescue SystemExit => e
          exit e.status unless e.success?
        end

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