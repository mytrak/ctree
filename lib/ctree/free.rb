# frozen_string_literal: true

require "set"

module Ctree
  module Free
    module_function

    def run
      target_path = Pathname.pwd
      toplevel_out, _, status = Sh.capture3("git", "-C", target_path.to_s, "rev-parse", "--show-toplevel")
      Log.die "not inside a git repository" unless status.success?
      git_top = Pathname.new(toplevel_out.strip)
      unless target_path.realpath == git_top.realpath
        Log.die "must be invoked from the worktree top-level (cwd=#{target_path}, top=#{git_top})"
      end

      common_out, _, c_st = Sh.capture3("git", "-C", target_path.to_s, "rev-parse", "--git-common-dir")
      Log.die "could not resolve git common dir" unless c_st.success?
      common = Pathname.new(common_out.strip)
      common = (target_path / common) unless common.absolute?
      source_root = common.parent.realpath

      if source_root == target_path.realpath
        Log.die "already in the source project; run ctree free from inside a worktree"
      end

      config = Config.load(source_root)
      Log.log_prefix = config[:log_prefix]
      prefix = config[:free_branch_prefix]

      current_branch_out, _, cb_st = Sh.capture3("git", "-C", target_path.to_s, "rev-parse", "--abbrev-ref", "HEAD")
      Log.die "could not resolve current branch" unless cb_st.success?
      current_branch = current_branch_out.strip
      if !prefix.empty? && current_branch.start_with?(prefix)
        Log.info "already on a free branch (#{current_branch}); nothing to do"
        exit 0
      end

      branches_out, _, branches_st = Sh.capture3("git", "-C", source_root.to_s, "branch", "--list", "#{prefix}*")
      Log.die "git branch --list failed" unless branches_st.success?
      all_free = branches_out.lines.map { |l| l.sub(/\A[*+ ] /, "").strip }.reject(&:empty?).sort

      worktree_raw, _, wt_st = Sh.capture3("git", "-C", source_root.to_s, "worktree", "list", "--porcelain")
      Log.die "git worktree list failed" unless wt_st.success?
      occupied = List.parse_worktree_porcelain(worktree_raw).filter_map { |e| e[:branch] }.to_set

      branch = first_available_branch(all_free, occupied)
      if branch
        _, err, st = Spinner.with_spinner("checking out #{branch}") do
          Sh.capture3("git", "-C", target_path.to_s, "checkout", branch)
        end
        Log.die "git checkout #{branch} failed: #{err.strip}" unless st.success?
      else
        branch = next_sequential_branch(prefix, all_free)
        _, err, st = Spinner.with_spinner("checking out #{branch}") do
          Sh.capture3("git", "-C", target_path.to_s, "checkout", "-b", branch)
        end
        Log.die "git checkout -b #{branch} failed: #{err.strip}" unless st.success?
      end
      Log.info "checked out #{branch}"

      Rebase.rebase_branch_onto_master(target_path, branch)
    end

    def first_available_branch(all_free, occupied)
      all_free.sort.find { |b| !occupied.include?(b) }
    end

    def next_sequential_branch(prefix, all_free)
      numeric_pattern = /\A#{Regexp.escape(prefix)}(\d+)\z/
      numbers = all_free.filter_map { |b| b.match(numeric_pattern)&.then { |m| m[1].to_i } }.to_set
      n = 1
      n += 1 while numbers.include?(n)
      "#{prefix}#{n.to_s.rjust(3, "0")}"
    end
  end
end
