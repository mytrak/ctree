# frozen_string_literal: true

module Ctree
  module Update
    module_function

    # Runs from INSIDE a worktree. The worktree is a `git worktree` of the
    # source repo, so the source root is the parent of git's common dir. The
    # worktree's own .ctree config (on its branch) governs the update.
    def run(force: false)
      target_path = Pathname.pwd
      toplevel_out, _, status = Sh.capture3("git", "-C", target_path.to_s, "rev-parse", "--show-toplevel")
      Log.die "not inside a git repository" unless status.success?
      git_top = Pathname.new(toplevel_out.strip)
      unless target_path.realpath == git_top.realpath
        Log.die "must be invoked from the worktree top-level (cwd=#{target_path}, top=#{git_top})"
      end

      # The main worktree (source) lives one level up from the git common dir.
      common_out, _, c_st = Sh.capture3("git", "-C", target_path.to_s, "rev-parse", "--git-common-dir")
      Log.die "could not resolve git common dir" unless c_st.success?
      common = Pathname.new(common_out.strip)
      common = (target_path / common) unless common.absolute?
      source_root = common.parent.realpath

      if source_root == target_path.realpath
        Log.die "already in the source project; run ctree update from inside a worktree"
      end

      config = Config.load(target_path)
      Log.debug_mode = config[:log_level] == "debug"
      share_volumes = config[:share_volumes]
      update_volumes = config[:update_volumes]
      empty_volumes = config[:empty_volumes]
      override_rel = config[:compose_override_file].to_s
      env_filename = config[:env_filename]

      source_env_vars = EnvFile.parse(source_root / env_filename)
      env_source_project = source_env_vars["COMPOSE_PROJECT_NAME"]
      source_project = if env_source_project && !env_source_project.empty?
                         env_source_project
                       else
                         Naming.sanitize_compose_project_name(source_root.basename.to_s)
                       end

      target_env_vars = EnvFile.parse(target_path / env_filename)
      env_target_project = target_env_vars["COMPOSE_PROJECT_NAME"]
      target_project = if env_target_project && !env_target_project.empty?
                         env_target_project
                       else
                         Naming.sanitize_compose_project_name(target_path.basename.to_s)
                       end

      unless ComposeOverride.valid?(
        target_path: target_path, override_rel: override_rel,
        share_volumes: share_volumes, source_project: source_project
      )
        Log.die "invalid ctree override file. run 'ctree compose-config fix' to fix"
      end

      Log.info "updated worktree #{target_path.basename} from #{source_root.basename}"
      Log.debug "source project (compose):  #{source_project}  [#{source_root}]"
      Log.debug "target project (compose):  #{target_project}  [#{target_path}]"

      # === docker preflight ===

      docker_ok = Sh.system("docker", "info", out: File::NULL, err: File::NULL)
      unless docker_ok
        Log.warn_ "docker not reachable — skipping update"
        exit 1
      end

      src_branch_out, _, _ = Sh.capture3("git", "-C", source_root.to_s, "rev-parse", "--abbrev-ref", "HEAD")
      src_branch = src_branch_out.strip
      default_branch = detect_default_branch(source_root)
      if !src_branch.empty? && src_branch != default_branch
        Log.warn_ "source repo is on branch '#{src_branch}' (not '#{default_branch}')"
        unless Prompt.confirm("proceed with update? [y/N]:", default: :no, force: force)
          Log.info "update aborted"
          exit 1
        end
      end

      src_ps_out, _, src_ps_st = Sh.capture3(
        "docker", "ps",
        "--filter", "label=com.docker.compose.project=#{source_project}",
        "--quiet"
      )
      Log.die "docker ps failed" unless src_ps_st.success?
      unless src_ps_out.strip.empty?
        Log.warn_ "source compose stack has running containers"
        if Prompt.confirm("stop source containers before updating? [Y/n]:", default: :yes, force: force)
          _, err, st = Spinner.with_spinner("stopping source compose stack") do
            Sh.capture3("docker", "compose", "-p", source_project, "down", chdir: source_root.to_s)
          end
          if st.success?
            Log.info "stopped source compose stack"
          else
            Log.die "failed to stop source compose stack: #{err.strip}"
          end
        else
          Log.warn_ "source containers still running; aborting"
          exit 1
        end
      end

      ps_out, _, status = Sh.capture3(
        "docker", "ps",
        "--filter", "label=com.docker.compose.project=#{target_project}",
        "--quiet"
      )
      Log.die "docker ps failed" unless status.success?
      unless ps_out.strip.empty?
        _, err, st = Spinner.with_spinner("stopping worktree compose stack") do
          Sh.capture3("docker", "compose", "-p", target_project, "down")
        end
        if st.success?
          Log.info "stopped worktree compose stack"
        else
          Log.die "failed to stop worktree compose stack: #{err.strip}"
        end
      end

      # === re-tag source images so the worktree picks up freshly built layers ===

      tagged = Images.tag_to_target(source_project, target_project)
      Log.info "tagged #{tagged.size} docker images" if tagged.any? && !Log.debug?

      # === identify volumes mounted externally from source via override yml ===

      shared_suffixes = share_volumes.dup
      override_path = override_rel.empty? ? nil : (target_path / override_rel)
      if override_path&.file?
        begin
          override_doc = YAML.safe_load(File.read(override_path.to_s), aliases: true)
          if override_doc.is_a?(Hash) && override_doc["volumes"].is_a?(Hash)
            override_doc["volumes"].each do |key, v|
              next unless v.is_a?(Hash) && v["external"]
              nm = v["name"]
              next unless nm.is_a?(String) && !nm.empty?
              next if nm.start_with?("#{target_project}_")
              shared_suffixes << key
            end
          end
        rescue Psych::SyntaxError => e
          Log.warn_ "could not parse #{override_path}: #{e.message}; using only built-in skip list"
        end
        shared_suffixes.uniq!
      end

      vols_out, _, status = Sh.capture3("docker", "volume", "ls", "--format", "{{.Name}}")
      Log.die "docker volume ls failed" unless status.success?
      prefix_re = /\A#{Regexp.escape(source_project)}_/
      source_volumes = vols_out.lines.map(&:strip).reject(&:empty?).select { |v| v =~ prefix_re }

      if source_volumes.empty?
        Log.info "no source volumes found with prefix '#{source_project}_'"
      end

      to_sync = []
      to_skip_buckets = {
        "empty volume" => [],
        "not in sync allowlist" => [],
        "shared from source" => [],
        "no target volume" => []
      }

      source_volumes.each do |src_vol|
        suffix = src_vol.sub(prefix_re, "")
        tgt_vol = "#{target_project}_#{suffix}"

        if empty_volumes.include?(suffix)
          to_skip_buckets["empty volume"] << [src_vol, tgt_vol]
          next
        end

        if shared_suffixes.include?(suffix)
          to_skip_buckets["shared from source"] << [src_vol, tgt_vol]
          next
        end

        unless update_volumes.include?(suffix)
          to_skip_buckets["not in sync allowlist"] << [src_vol, tgt_vol]
          next
        end

        _, _, st = Sh.capture3("docker", "volume", "inspect", tgt_vol)
        unless st.success?
          to_skip_buckets["no target volume"] << [src_vol, tgt_vol]
          next
        end

        to_sync << [src_vol, tgt_vol]
      end

      Volume.ensure_rsync_image! if to_sync.any?

      sync_results = []
      volume_start = Time.now
      volume_bytes = 0
      updated_vol_count = 0

      to_sync.each do |src_vol, tgt_vol|
        st, err, bytes = Volume.rsync_with_progress(src_vol, tgt_vol)
        if st.success?
          Log.debug "updated #{src_vol} -> #{tgt_vol}"
          volume_bytes += bytes.to_i
          updated_vol_count += 1
          sync_results << [src_vol, tgt_vol, :updated, ""]
        else
          Log.warn_ "rsync failed for #{tgt_vol}: #{err.strip}"
          sync_results << [src_vol, tgt_vol, :failed, "rsync failed: #{err.strip}"]
        end
      end

      ["empty volume", "not in sync allowlist", "shared from source", "no target volume"].each do |reason|
        to_skip_buckets[reason].each do |src_vol, tgt_vol|
          Log.debug "skipped #{src_vol} (#{reason})"
          sync_results << [src_vol, tgt_vol, :skipped, reason]
        end
      end

      if updated_vol_count > 0
        volume_elapsed = (Time.now - volume_start).to_i
        size_note = volume_bytes > 0 ? "#{Sizes.human(volume_bytes)} in " : ""
        Log.info "updated #{updated_vol_count} volume#{updated_vol_count == 1 ? "" : "s"} (#{size_note}#{volume_elapsed}s)" unless Log.debug?
      end

      sync_file_results = []
      updated_file_count = 0
      config[:update].each do |rel|
        if !override_rel.empty? && rel == override_rel
          Log.debug "skipped #{rel} (compose override file managed by ctree create)"
          sync_file_results << [rel, :skipped, "compose override file"]
          next
        end
        if rel == ".ctree" || rel.start_with?(".ctree/")
          Log.debug "skipped #{rel} (reserved directory managed by ctree create)"
          sync_file_results << [rel, :skipped, "reserved directory"]
          next
        end
        src = source_root / rel
        tgt = target_path / rel
        if src.directory?
          FileUtils.mkdir_p(tgt.to_s)
          _, err, st = Spinner.with_spinner("rsync #{rel}/") do
            Sh.capture3("rsync", "-a", "--checksum", "--delete", "#{src}/", "#{tgt}/")
          end
          if st.success?
            Log.debug "updated directory #{rel}"
            updated_file_count += 1
            sync_file_results << [rel, :updated, ""]
          else
            Log.warn_ "rsync failed for #{rel}: #{err.strip}"
            sync_file_results << [rel, :failed, "rsync failed: #{err.strip}"]
          end
        elsif src.file?
          _, err, st = Spinner.with_spinner("rsync #{rel}") do
            Sh.capture3("rsync", "-a", "--checksum", src.to_s, tgt.to_s)
          end
          if st.success?
            Log.debug "updated file #{rel}"
            updated_file_count += 1
            sync_file_results << [rel, :updated, ""]
          else
            Log.warn_ "rsync failed for #{rel}: #{err.strip}"
            sync_file_results << [rel, :failed, "rsync failed: #{err.strip}"]
          end
        else
          Log.warn_ "update: source not found: #{rel}"
          sync_file_results << [rel, :missing, "source not found"]
        end
      end
      Log.info "updated #{updated_file_count} file#{updated_file_count == 1 ? "" : "s"}" if updated_file_count > 0 && !Log.debug?

      failed = sync_results.any? { |_, _, st, _| st == :failed } ||
               sync_file_results.any? { |_, st, _| st == :failed }

      post_update_hooks = config[:post_update_hooks]
      unless post_update_hooks.empty?
        run_post_update_hooks = lambda do
          post_update_hooks.each_with_index do |cmd, idx|
            label = "post-update hook #{idx + 1}/#{post_update_hooks.size}"
            if Log.debug?
              Spinner.with_spinner("running #{label}: #{cmd}") { system(cmd) }
            else
              system(cmd)
            end
            unless $?.success?
              Log.die "post-update hook failed (exit #{$?.exitstatus}): #{cmd}"
            end
          end
        end

        post_start = Time.now
        if Log.debug?
          run_post_update_hooks.call
        else
          Spinner.with_spinner("running post-update hooks") { run_post_update_hooks.call }
        end
        Log.info "ran post-update hooks (#{(Time.now - post_start).to_i}s)"
      end

      if Log.debug?
        lines = []
        lines << ""
        lines << "=== ctree update summary ==="
        lines << "worktree:  #{target_path}"

        if sync_results.any?
          lines << "volumes:"
          sync_results.each do |src, tgt, st, msg|
            line = "  [#{st.to_s.ljust(7)}] #{src}  ->  #{tgt}"
            line += "  (#{msg})" unless msg.to_s.empty?
            lines << line
          end
        end

        if sync_file_results.any?
          lines << "files/dirs:"
          sync_file_results.each do |rel, st, msg|
            line = "  [#{st.to_s.ljust(7)}] #{rel}"
            line += "  (#{msg})" unless msg.to_s.empty?
            lines << line
          end
        end

        if post_update_hooks.any?
          lines << "post-update hooks:"
          post_update_hooks.each do |cmd|
            lines << "  [ran    ] #{cmd}"
          end
        end

        Log.section(lines.join("\n"))
      end

      exit(failed ? 2 : 0)
    end

    def detect_default_branch(root)
      ref_out, _, ref_st = Sh.capture3("git", "-C", root.to_s,
                                       "symbolic-ref", "refs/remotes/origin/HEAD")
      return ref_out.strip.sub("refs/remotes/origin/", "") if ref_st.success?

      _, _, m_st = Sh.capture3("git", "-C", root.to_s,
                               "show-ref", "--verify", "--quiet", "refs/heads/master")
      m_st.success? ? "master" : "main"
    end
  end
end
