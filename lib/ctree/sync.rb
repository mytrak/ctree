# frozen_string_literal: true

module Ctree
  module Sync
    module_function

    def run(force: false)
      begin
        Ctree::Rebase.run(force: force)
      rescue SystemExit => e
        exit e.status unless e.success?
      end

      Ctree::Update.run(force: force)
    end
  end
end