# frozen_string_literal: true

module Ctree
  module Delete
    module_function

    def run(name:, force: false)
      source_root = Pathname.pwd
      toplevel_out, _, status = Sh.capture3("git", "-C", source_root.to_s, "rev-parse", "--show-toplevel")
      Log.die "not inside a git repository" unless status.success?
      git_top = Pathname.new(toplevel_out.strip)
      unless source_root.realpath == git_top.realpath
        Log.die "must be invoked from project top-level (cwd=#{source_root}, top=#{git_top})"
      end

      if source_root.basename.to_s == name
        Log.die "refusing to remove '#{name}' — that's the current source project itself"
      end

      parent_dir = source_root.parent
      target_project = Naming.sanitize_compose_project_name(name)

      # Resolve the actual worktree path from git's registration first — the
      # registered absolute path may differ from parent_dir/name if the
      # worktree was created from a different pwd or via a symlinked directory.
      # Fall back to constructing the path if git has no matching entry.
      worktree_list_out, _, _ = Sh.capture3("git", "-C", source_root.to_s, "worktree", "list", "--porcelain")
      wt_records = worktree_list_out.split(/\n\n+/).filter_map do |block|
        record = {}
        block.each_line do |line|
          line = line.chomp
          record[:path]   = line.delete_prefix("worktree ")          if line.start_with?("worktree ")
          record[:branch] = line.delete_prefix("branch refs/heads/") if line.start_with?("branch refs/heads/")
        end
        record unless record.empty?
      end
      matching_record   = wt_records.find { |r| r[:path] && File.basename(r[:path]) == name }
      registered_wt_path = matching_record&.fetch(:path, nil)
      worktree_branch    = matching_record&.fetch(:branch, nil)
      target_path = registered_wt_path ? Pathname.new(registered_wt_path) : (parent_dir / name)

      # Discover what currently exists for this name.
      docker_ok = Sh.system("docker", "info", out: File::NULL, err: File::NULL)
      Log.warn_ "docker not reachable — volumes and compose stack will not be touched" unless docker_ok

      # Read the worktree's compose override file (if present) to find any
      # `external: true` volumes whose explicit `name:` is NOT under the
      # target project prefix. Those are source-shared (e.g. yarn-cache
      # mounted from the source project) and must be preserved during removal.
      config = Config.load(source_root)
      Log.log_prefix = config[:log_prefix]
      override_rel = config[:compose_override_file].to_s
      shared_external_vols = []
      override_path = override_rel.empty? ? nil : (target_path / override_rel)
      if override_path&.file?
        begin
          override_doc = YAML.safe_load(File.read(override_path.to_s), aliases: true)
          if override_doc.is_a?(Hash) && override_doc["volumes"].is_a?(Hash)
            override_doc["volumes"].each_value do |v|
              next unless v.is_a?(Hash) && v["external"]
              nm = v["name"]
              next unless nm.is_a?(String) && !nm.empty?
              next if nm.start_with?("#{target_project}_")
              shared_external_vols << nm
            end
          end
        rescue Psych::SyntaxError => e
          Log.warn_ "could not parse #{override_path}: #{e.message}; cannot identify shared volumes for preservation"
        end
        shared_external_vols.uniq!
      end

      vols = []
      if docker_ok
        vols_out, _, st = Sh.capture3("docker", "volume", "ls", "--format", "{{.Name}}")
        Log.die "docker volume ls failed" unless st.success?
        prefix_re = /\A#{Regexp.escape(target_project)}_/
        vols = vols_out.lines.map(&:strip).reject(&:empty?).select { |v| v =~ prefix_re }.sort
        # Belt-and-suspenders: explicitly drop any source-shared volume even
        # though the prefix filter above should already exclude them.
        vols -= shared_external_vols
      end

      containers = []
      if docker_ok
        ps_out, _, st = Sh.capture3(
          "docker", "ps", "--all",
          "--filter", "label=com.docker.compose.project=#{target_project}",
          "--format", "{{.Names}}"
        )
        containers = ps_out.lines.map(&:strip).reject(&:empty?).sort if st.success?
      end

      tagged_images = []
      if docker_ok
        imgs_out, _, st = Sh.capture3("docker", "images",
                                       "--format", "{{.Repository}}",
                                       "--filter", "reference=#{target_project}-*")
        tagged_images = imgs_out.lines.map(&:strip).reject(&:empty?).sort if st.success?
      end

      branch_to_check = worktree_branch || name
      _, _, st = Sh.capture3("git", "-C", source_root.to_s, "show-ref", "--verify", "--quiet", "refs/heads/#{branch_to_check}")
      branch_exists = st.success?

      target_real = target_path.exist? ? target_path.realpath.to_s : target_path.to_s
      worktree_registered = !registered_wt_path.nil?

      # Branches are never deleted by remove (see below), so the presence
      # of a same-named branch alone is not a reason to do work.
      nothing_to_do = vols.empty? && containers.empty? && tagged_images.empty? && !worktree_registered && !target_path.exist?
      if nothing_to_do
        Log.info "nothing to remove for '#{name}' — no worktree, branch, containers, or volumes found"
        exit 0
      end

      # Show the user exactly what will happen.
      summary = []
      summary << ""
      summary << "[#{PROG}] About to delete '#{name}':"
      summary << ""
      summary << "  worktree path:  #{target_path}"
      summary << "    - dir:        #{target_path.exist? ? "EXISTS — will be deleted" : "absent"}"
      summary << "    - registered: #{worktree_registered ? "YES — will run `git worktree remove --force`" : "no"}"
      summary << ""
      if branch_exists
        summary << "  git branch:     #{branch_to_check}  — preserved (run `git branch -D #{branch_to_check}` manually to delete)"
      else
        summary << "  git branch:     #{branch_to_check}  — not found"
      end
      summary << ""
      summary << "  compose stack:  -p #{target_project}"
      if containers.empty?
        summary << "    - containers: none running for this project"
      else
        summary << "    - containers (will be stopped and removed via `docker compose down`):"
        containers.each { |c| summary << "        #{c}" }
      end
      summary << ""
      if vols.empty?
        summary << "  docker volumes: none matching ^#{target_project}_"
      else
        summary << "  docker volumes (#{vols.size}, all will be PERMANENTLY deleted):"
        vols.each { |v| summary << "        #{v}" }
      end
      summary << ""
      unless shared_external_vols.empty?
        summary << "  shared volumes (mounted from source via override yml; will NOT be touched):"
        shared_external_vols.sort.each { |v| summary << "        #{v}" }
        summary << ""
      end
      if tagged_images.empty?
        summary << "  docker images:  no tags matching #{target_project}-*"
      else
        summary << "  docker image tags (#{tagged_images.size}, tags will be deleted — image layers preserved):"
        tagged_images.each { |img| summary << "        #{img}" }
      end
      summary << ""
      summary << "  Source project (#{source_root}) will NOT be touched."
      summary << ""

      Log.section(summary.join("\n"), interactive: true, force: force)

      unless Prompt.confirm("Type 'yes' to confirm deletion of '#{name}':", default: nil, force: force)
        warn "[#{PROG}] aborted: confirmation not given. No changes made."
        exit 1
      end

      # === execute ===

      failures = []

      if docker_ok && !containers.empty?
        _, err, st = Spinner.with_spinner("stopping compose stack -p #{target_project}") do
          Sh.capture3("docker", "compose", "-p", target_project, "down", chdir: target_path.to_s)
        end
        if st.success?
          Log.info "compose stack stopped"
        else
          Log.warn_ "compose down returned non-zero: #{err.strip}"
          failures << "compose down"
        end
      end

      if docker_ok && !tagged_images.empty?
        _, rmi_err, rmi_st = Spinner.with_spinner("removing #{tagged_images.size} image tag(s)") do
          Sh.capture3("docker", "rmi", *tagged_images)
        end
        if rmi_st.success?
          Log.info "deleted #{tagged_images.size} image tag(s): #{tagged_images.join(", ")}"
        else
          Log.warn_ "docker rmi returned non-zero: #{rmi_err.strip}"
          failures << "image rmi"
        end
      end

      if docker_ok && !vols.empty?
        # Batch removal: single subprocess call, single round-trip to the
        # docker daemon. Falls back to per-volume on partial failure so
        # error messages remain attributable.
        _, batch_err, batch_st = Spinner.with_spinner("removing #{vols.size} volume(s)") do
          Sh.capture3("docker", "volume", "rm", *vols)
        end
        if batch_st.success?
          Log.info "deleted #{vols.size} volume(s): #{vols.join(", ")}"
        else
          Log.warn_ "batch volume removal failed; retrying one at a time: #{batch_err.strip}"
          vols.each do |v|
            _, _, exists_st = Sh.capture3("docker", "volume", "inspect", v)
            unless exists_st.success?
              Log.info "deleted volume #{v} (already gone)"
              next
            end
            _, err, st = Spinner.with_spinner("removing volume #{v}") do
              Sh.capture3("docker", "volume", "rm", v)
            end
            if st.success?
              Log.info "deleted volume #{v}"
            else
              Log.warn_ "failed to remove volume #{v}: #{err.strip}"
              failures << "volume rm #{v}"
            end
          end
        end
      end

      # Worktree directory removal: rename + background-detached rm -rf.
      # On the same filesystem, rename(2) is O(1) so remove returns in
      # seconds regardless of how many files are in the worktree. The
      # detached rm survives shell exit via Process.spawn's pgroup: true.
      # On cross-filesystem rename (EXDEV) or rename failure for any other
      # reason, we fall back to synchronous `git worktree remove --force`.
      if worktree_registered || target_path.exist?
        remove_failed = false

        if target_path.exist?
          quarantine = quarantine_path_for(target_path)

          begin
            File.rename(target_path.to_s, quarantine.to_s)
            Log.info "worktree dir renamed -> #{quarantine.basename}"

            bg_pid = Sh.spawn(
              "rm", "-rf", quarantine.to_s,
              out: File::NULL, err: File::NULL, in: File::NULL,
              pgroup: true
            )
            Sh.detach(bg_pid)
            Log.info "queued background worktree dir delete job (pid #{bg_pid})"
          rescue Errno::EXDEV, Errno::EACCES, Errno::EPERM, SystemCallError => e
            Log.warn_ "rename failed (#{e.class}: #{e.message}); falling back to synchronous removal"
            _, fallback_err, fallback_st = Spinner.with_spinner("removing worktree #{target_path}") do
              Sh.capture3("git", "-C", source_root.to_s, "worktree", "remove", "--force", target_path.to_s)
            end
            unless fallback_st.success?
              Log.warn_ "git worktree remove failed: #{fallback_err.strip}"
              begin
                FileUtils.rm_rf(target_path.to_s, secure: true)
                if target_path.exist?
                  Log.warn_ "fallback rm_rf left #{target_path} behind"
                  remove_failed = true
                else
                  Log.info "removed directory #{target_path} (fallback)"
                end
              rescue StandardError => rmerr
                Log.warn_ "fallback rm_rf failed for #{target_path}: #{rmerr.message}"
                remove_failed = true
              end
            end
          end
        end

        # Prune always — cleans up the dangling registration after the
        # rename, or any leftover from a prior failed removal.
        _, prune_err, prune_st = Sh.capture3("git", "-C", source_root.to_s, "worktree", "prune")
        if prune_st.success?
          Log.info "pruned worktree registration"
        else
          Log.warn_ "git worktree prune failed: #{prune_err.strip}"
          failures << "worktree prune"
        end

        failures << "worktree remove" if remove_failed
      end

      # Branches are intentionally preserved — see the README "remove"
      # section for rationale. Even an auto-derived branch (created when
      # `ctree add` is called without an explicit branch name) can carry
      # commits the user wants to keep, push, or merge later. To clean up
      # an orphan, run `git branch -D <name>` manually.

      puts unless LogFile.enabled?
      if failures.empty?
        exit 0
      else
        Log.warn_ "removal completed with failures: #{failures.join(", ")}"
        exit 2
      end
    end

    # Builds a unique sibling path adjacent to target_path used as the
    # rename destination. Includes the destroying process's pid and a
    # short random suffix so concurrent destroys of distinct worktrees
    # never collide and a re-run after a stuck prior attempt doesn't
    # either.
    def quarantine_path_for(target_path)
      base = target_path.basename.to_s
      parent = target_path.parent
      suffix = ".ctree-destroying-#{Process.pid}-#{rand(2**32).to_s(36)}"
      parent / "#{base}#{suffix}"
    end
  end
end
