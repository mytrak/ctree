# frozen_string_literal: true

module Ctree
  module Rebase
    module_function

    # Runs from INSIDE a worktree. Rebases the worktree's feature branch onto
    # the source's local master, then rebases each embedded repo (discovered
    # via rebase config) from its source counterpart.
    #
    # All operations are local — no network calls. The source is the authority:
    # rebase the source repo first, then run `ctree rebase` from the worktree
    # to catch it up.
    def run(force: false)
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
        Log.die "already in the source project; run ctree rebase from inside a worktree"
      end

      branch_out, _, _ = Sh.capture3("git", "-C", target_path.to_s, "rev-parse", "--abbrev-ref", "HEAD")
      current_branch = branch_out.strip
      if current_branch == "master" || current_branch == "main"
        Log.die "worktree is on '#{current_branch}' — ctree rebase is for feature branches only; " \
                "run `git pull --rebase origin #{current_branch}` directly"
      end

      config = Config.load(target_path)
      Log.debug_mode = config[:log_level] == "debug"
      rebase_repo_paths = config[:rebase]

      Log.info "worktree:  #{target_path}  [#{current_branch}]"
      Log.info "source:    #{source_root}"

      # === uncommitted-changes check ===

      dirty = []
      dirty << target_path.to_s unless working_tree_clean?(target_path)
      embedded_repos(target_path, rebase_repo_paths).each do |wt_repo|
        dirty << wt_repo.to_s unless working_tree_clean?(wt_repo)
      end

      unless dirty.empty?
        Log.warn_ "uncommitted changes in:"
        dirty.each { |d| Log.warn_ "  #{d}" }
        unless Prompt.confirm("proceed anyway? [y/N]:", default: :no, force: force)
          Log.info "rebase aborted"
          exit 1
        end
      end

      results = []

      # === rebase worktree feature branch onto source master ===

      status = rebase_branch_onto_master(target_path, current_branch)
      results << [status, target_path.basename.to_s, status == :skipped ? "already up to date" : ""]

      # === rebase each embedded repo from its source counterpart ===

      embedded_repos(target_path, rebase_repo_paths).each do |wt_repo|
        rel = wt_repo.relative_path_from(target_path)
        src_repo = source_root / rel

        unless src_repo.directory? && (src_repo / ".git").exist?
          Log.warn_ "no source counterpart for #{rel}; skipping"
          results << [:skipped, rel.to_s, "no source counterpart"]
          next
        end

        _, f_err, f_st = Spinner.with_spinner("fetching #{rel}") do
          Sh.capture3("git", "-C", wt_repo.to_s, "fetch", src_repo.to_s, "master")
        end
        unless f_st.success?
          Log.warn_ "git fetch #{src_repo} failed for #{rel}: #{f_err.strip}"
          results << [:failed, rel.to_s, f_err.strip]
          next
        end

        wt_head, _, _ = Sh.capture3("git", "-C", wt_repo.to_s, "rev-parse", "HEAD")
        fetch_head, _, _ = Sh.capture3("git", "-C", wt_repo.to_s, "rev-parse", "FETCH_HEAD")
        if wt_head.strip == fetch_head.strip
          Log.info "skipped #{rel} (up to date)"
          results << [:skipped, rel.to_s, "already up to date"]
          next
        end

        _, r_err, r_st = Spinner.with_spinner("rebasing #{rel}") do
          Sh.capture3("git", "-C", wt_repo.to_s, "rebase", "FETCH_HEAD")
        end
        if r_st.success?
          Log.info "rebased #{rel}"
          results << [:ok, rel.to_s, ""]
        else
          Log.warn_ "git rebase failed for #{rel}: #{r_err.strip}"
          results << [:failed, rel.to_s, r_err.strip]
        end
      end

      if Log.debug?
        puts
        puts "=== ctree rebase summary ==="
        results.each do |status, name, msg|
          line = "  [#{status.to_s.ljust(7)}] #{name}"
          line += "  (#{msg})" unless msg.empty?
          puts line
        end
        puts
      end

      failed = results.any? { |st, _, _| st == :failed }
      exit(failed ? 2 : 0)
    end

    # Rebases current_branch (checked out at target_path) onto local master.
    # Returns :skipped if already up to date, :ok if rebased. Dies (and aborts
    # the rebase) on conflict.
    def rebase_branch_onto_master(target_path, current_branch)
      _, _, ancestor_st = Sh.capture3("git", "-C", target_path.to_s, "merge-base", "--is-ancestor", "master", "HEAD")
      if ancestor_st.success?
        Log.info "#{current_branch} already up to date with master"
        return :skipped
      end

      _, err, st = Spinner.with_spinner("rebasing #{current_branch} onto master") do
        Sh.capture3("git", "-C", target_path.to_s, "rebase", "master")
      end
      if st.success?
        Log.info "rebased #{current_branch} onto master"
        :ok
      else
        Sh.capture3("git", "-C", target_path.to_s, "rebase", "--abort")
        Log.die "rebase conflict in #{target_path.basename} — rebase aborted; resolve the conflict manually and re-run ctree rebase"
      end
    end

    def working_tree_clean?(path)
      out, _, st = Sh.capture3("git", "-C", path.to_s, "status", "--porcelain")
      st.success? && out.strip.empty?
    end

    # Returns Pathname objects for each immediate subdirectory under each
    # rebase entry that has a .git entry and is not a submodule.
    def embedded_repos(root, repo_paths)
      submodule_relpaths = load_submodule_paths(root)
      repos = []
      repo_paths.each do |rel_dir|
        scan_dir = root / rel_dir
        next unless scan_dir.directory?
        scan_dir.children.select(&:directory?).sort.each do |subdir|
          next unless (subdir / ".git").exist?
          rel = subdir.relative_path_from(root).to_s
          next if submodule_relpaths.include?(rel)
          repos << subdir
        end
      end
      repos
    end

    def load_submodule_paths(root)
      gitmodules = root / ".gitmodules"
      return [] unless gitmodules.file?
      File.readlines(gitmodules.to_s)
          .grep(/^\s*path\s*=/)
          .map { |l| l.split("=", 2).last.strip }
    end

    private_class_method :working_tree_clean?, :embedded_repos, :load_submodule_paths
  end
end
