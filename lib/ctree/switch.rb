# frozen_string_literal: true

module Ctree
  module Switch
    module_function

    def run(name:)
      source_root = Pathname.pwd
      toplevel_out, _, status = Sh.capture3("git", "-C", source_root.to_s, "rev-parse", "--show-toplevel")
      Log.die "not inside a git repository" unless status.success?
      git_top = Pathname.new(toplevel_out.strip)
      unless source_root.realpath == git_top.realpath
        Log.die "must be invoked from project top-level (cwd=#{source_root}, top=#{git_top})"
      end

      raw, _, st = Sh.capture3("git", "-C", source_root.to_s, "worktree", "list", "--porcelain")
      Log.die "git worktree list failed" unless st.success?

      entries = List.parse_worktree_porcelain(raw)
      match = entries.find { |e| File.basename(e[:path]) == name }
      Log.die "worktree '#{name}' not found" unless match

      target_path = match[:path]
      Log.info "switching to #{target_path}"
      shell = ENV["SHELL"] || "/bin/sh"
      Dir.chdir(target_path)
      exec(shell)
    end
  end
end
