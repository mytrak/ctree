# frozen_string_literal: true

module Ctree
  module List
    module_function

    def run(filter: nil)
      source_root = Pathname.pwd
      toplevel_out, _, status = Sh.capture3("git", "-C", source_root.to_s, "rev-parse", "--show-toplevel")
      Log.die "not inside a git repository" unless status.success?
      git_top = Pathname.new(toplevel_out.strip)
      unless source_root.realpath == git_top.realpath
        Log.die "must be invoked from project top-level (cwd=#{source_root}, top=#{git_top})"
      end

      cfg = Config.load(source_root)
      empty_prefix = cfg[:free_branch_prefix]

      raw, _, st = Sh.capture3("git", "-C", source_root.to_s, "worktree", "list", "--porcelain")
      Log.die "git worktree list failed" unless st.success?

      entries = parse_worktree_porcelain(raw)

      current_top = git_top.realpath.to_s
      entries.each do |entry|
        entry[:current] = (Pathname.new(entry[:path]).realpath.to_s == current_top)
      rescue SystemCallError
        entry[:current] = false
      end

      if !empty_prefix.nil? && !empty_prefix.empty?
        entries.each do |entry|
          branch = entry[:branch] || ""
          entry[:free] = branch.start_with?(empty_prefix)
        end
      end

      visible = case filter
                when :free then entries.select { |e| e[:free] }
                when :used then entries.reject { |e| e[:free] }
                else entries
                end

      puts
      puts "=== worktrees ==="
      puts

      if (filter == :free || filter == :used) && visible.empty?
        if empty_prefix.nil? || empty_prefix.empty?
          puts "  (free_branch_prefix not set in .ctree/config.yml)"
        elsif filter == :free
          puts "  no free worktrees matching \"#{empty_prefix}\""
        else
          puts "  no used worktrees"
        end
        puts
        return
      end

      name_width = visible.map { |e| File.basename(e[:path]).length }.max.to_i

      visible.each do |entry|
        name   = File.basename(entry[:path]).ljust(name_width)
        branch = entry[:branch] || "detached"
        branch_label = (entry[:free] ? "#{branch} (free)" : branch)
        tags = []
        tags << "source" if entry[:source]
        tags << "current" if entry[:current]
        marker = tags.empty? ? "" : " ← #{tags.join(", ")}"
        puts "  #{name}  #{entry[:path]}  [#{branch_label}]#{marker}"
      end

      puts
    end

    def parse_worktree_porcelain(raw)
      entries = []
      current = {}

      raw.each_line do |line|
        line = line.chomp
        if line.empty?
          entries << current unless current.empty?
          current = {}
        elsif line.start_with?("worktree ")
          current[:path] = line.sub("worktree ", "")
        elsif line.start_with?("branch ")
          current[:branch] = line.sub("branch refs/heads/", "").sub("branch ", "")
        elsif line == "detached"
          current[:branch] = nil
        end
      end
      entries << current unless current.empty?

      # Mark the first entry (main worktree) as source.
      entries.first[:source] = true if entries.any?
      entries
    end
  end
end
