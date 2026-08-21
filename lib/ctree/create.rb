# frozen_string_literal: true

module Ctree
  module Create
    module_function

    def run(name:, branch:, config_path: nil)
      source_root = Pathname.pwd
      toplevel_out, _, status = Sh.capture3("git", "-C", source_root.to_s, "rev-parse", "--show-toplevel")
      Log.die "not inside a git repository" unless status.success?
      git_top = Pathname.new(toplevel_out.strip)
      unless source_root.realpath == git_top.realpath
        Log.die "must be invoked from project top-level (cwd=#{source_root}, top=#{git_top})"
      end

      # A linked worktree's --git-dir (.../.git/worktrees/<name>) differs from
      # its --git-common-dir (the shared .git); the main checkout's are the
      # same path. Refuse to create a worktree of a worktree.
      git_dir_out, _, gd_st = Sh.capture3("git", "-C", source_root.to_s, "rev-parse", "--git-dir")
      common_dir_out, _, gc_st = Sh.capture3("git", "-C", source_root.to_s, "rev-parse", "--git-common-dir")
      if gd_st.success? && gc_st.success?
        git_dir = Pathname.new(git_dir_out.strip)
        git_dir = (source_root / git_dir) unless git_dir.absolute?
        common_dir = Pathname.new(common_dir_out.strip)
        common_dir = (source_root / common_dir) unless common_dir.absolute?
        if git_dir.realpath != common_dir.realpath
          Log.die "ctree create must be run from a source repo, not from a worktree"
        end
      end

      source_basename = source_root.basename.to_s
      parent_dir = source_root.parent
      target_path = parent_dir / name

      Log.die "target path already exists: #{target_path}" if target_path.exist?

      # === verify source is on master branch ===

      current_branch_out, _, cb_st = Sh.capture3("git", "-C", source_root.to_s, "rev-parse", "--abbrev-ref", "HEAD")
      if cb_st.success?
        current_branch = current_branch_out.strip
        unless current_branch == "master"
          Log.warn_ "source repo is on branch '#{current_branch}', not 'master'"

          dirty_out, _, _ = Sh.capture3("git", "-C", source_root.to_s, "status", "--porcelain")
          has_changes = !dirty_out.strip.empty?

          if has_changes
            raw = Prompt.read_line("[#{PROG}] stash uncommitted changes and switch to master? [Y/n]: ")
            answer = raw.to_s.gsub(/[\x00-\x1f\x7f]/, "").strip.downcase
            if answer.empty? || answer == "y" || answer == "yes"
              _, stash_err, stash_st = Sh.capture3("git", "-C", source_root.to_s, "stash")
              Log.die "git stash failed: #{stash_err.strip}" unless stash_st.success?
              Log.info "stashed uncommitted changes"
              _, co_err, co_st = Sh.capture3("git", "-C", source_root.to_s, "checkout", "master")
              Log.die "git checkout master failed: #{co_err.strip}" unless co_st.success?
              Log.info "switched source to master"
            else
              Log.die "please checkout master in the source repo and re-run ctree"
            end
          else
            raw = Prompt.read_line("[#{PROG}] switch source to master branch? [Y/n]: ")
            answer = raw.to_s.gsub(/[\x00-\x1f\x7f]/, "").strip.downcase
            if answer.empty? || answer == "y" || answer == "yes"
              _, co_err, co_st = Sh.capture3("git", "-C", source_root.to_s, "checkout", "master")
              Log.die "git checkout master failed: #{co_err.strip}" unless co_st.success?
              Log.info "switched source to master"
            else
              Log.die "please checkout master in the source repo and re-run ctree"
            end
          end
        end
      end

      config = if config_path
           Config.load_with_override(config_path)
         else
           Config.load(source_root)
         end
      Log.debug_mode = config[:log_level] == "debug"
      share_volumes = config[:share_volumes]
      empty_volumes = config[:empty_volumes]
      exclude = config[:exclude]
      env_filename = config[:env_filename]

      # === resolve compose project names ===

      source_env_vars = EnvFile.parse(source_root / env_filename)
      env_compose_project = source_env_vars["COMPOSE_PROJECT_NAME"]
      if env_compose_project && !env_compose_project.empty?
        source_project = env_compose_project
        source_project_origin = "from #{source_root / env_filename} (COMPOSE_PROJECT_NAME)"
      else
        source_project = Naming.sanitize_compose_project_name(source_basename)
        source_project_origin = "from source dir basename (no COMPOSE_PROJECT_NAME in #{env_filename})"
      end
      target_project = Naming.sanitize_compose_project_name(name)

      Log.debug "source project (compose): #{source_project}  [#{source_project_origin}]"
      Log.debug "target project (compose): #{target_project}"
      Log.debug "identified source volumes by prefix: #{source_project}_"

      # === pre-flight ===

      _, _, status = Sh.capture3("git", "-C", source_root.to_s, "show-ref", "--verify", "--quiet", "refs/heads/#{branch}")
      branch_exists = status.success?

      _, _, status = Sh.capture3("docker", "info")
      Log.die "docker not available (is the daemon running?)" unless status.success?

      ps_out, _, status = Sh.capture3(
        "docker", "ps",
        "--filter", "label=com.docker.compose.project=#{source_project}",
        "--quiet"
      )
      Log.die "docker ps failed" unless status.success?
      unless ps_out.strip.empty?
        Log.warn_ "source compose stack has running containers"
        raw = Prompt.read_line("[#{PROG}] stop source containers before creating worktree? [Y/n]: ")
        answer = raw.to_s.gsub(/[\x00-\x1f\x7f]/, "").strip.downcase
        if answer.empty? || answer == "y" || answer == "yes"
          _, err, st = Spinner.with_spinner("stopping source compose stack") do
            Sh.capture3("docker", "compose", "-p", source_project, "down")
          end
          if st.success?
            Log.info "stopped source compose stack"
          else
            Log.die "failed to stop source compose stack: #{err.strip}"
          end
        else
          Log.die "source containers still running; please stop them and re-run ctree"
        end
      end

      # === register worktree + clone all source content ===
      # git worktree add --no-checkout creates an empty target dir with a
      # .git FILE pointer but skips the file checkout. We then clone every
      # top-level item from source into target (excluding .git, which is
      # already a FILE from step 1). This brings tracked AND gitignored
      # content (node_modules, build artifacts, plugin lock files, etc.)
      # in O(N top-level items) clonefile(2) calls — each call clones a
      # whole subtree. On macOS APFS, each call is instant CoW. On Linux,
      # cp --reflink=auto gives CoW on btrfs/xfs and falls back on ext4.

      worktree_args = if branch_exists
        ["worktree", "add", "--no-checkout", target_path.to_s, branch]
      else
        ["worktree", "add", "--no-checkout", "-b", branch, target_path.to_s]
      end
      _, wt_err, wt_st = Sh.capture3("git", "-C", source_root.to_s, *worktree_args)
      Log.die "git worktree add failed: #{wt_err.strip}" unless wt_st.success?
      Log.debug "created worktree at #{target_path}"
      Log.debug branch_exists ? "checked out existing branch #{branch}" : "checked out new branch #{branch}"
      Log.info "created worktree #{name} (branch: #{branch}) from #{source_basename}"

      items = Dir.glob(File.join(source_root.to_s, "*"), File::FNM_DOTMATCH)
                 .reject { |p| %w[. .. .git .ctree].include?(File.basename(p)) }
      excluded = []
      if exclude.any?
        items, excluded = items.partition { |p| !exclude.include?(File.basename(p)) }
        excluded.each { |p| Log.debug "skipped #{File.basename(p)} (exclude)" }
      end
      total = items.size
      failed_items = []

      # On non-TTY the spinner doesn't run, so log the start explicitly.
      # On TTY the spinner itself is the start indicator — skip the static line
      # to avoid showing both "copying source content" and the spinner line.
      Log.debug "copying source content" unless $stdout.tty?

      state_mutex = Mutex.new
      done_count = 0
      clone_done = false
      clone_start = Time.now
      clone_elapsed = 0
      source_size_bytes = nil

      # Measure total size of cloned items in parallel so it's ready by the
      # time cloning finishes (cloning typically takes much longer than du).
      du_thread = Thread.new do
        out, _, st = Sh.capture3("du", "-sk", *items)
        source_size_bytes = out.lines.sum { |l| l.split("\t").first.to_i } * 1024 if st.success?
      end

      render_thread = if $stdout.tty?
        Thread.new do
          spinner_idx = 0
          until state_mutex.synchronize { clone_done }
            n = state_mutex.synchronize { done_count }
            elapsed = (Time.now - clone_start).to_i
            pct = total > 0 ? (n * 100 / total) : 0
            print format("\r\e[K[ctree] copying source content %d%% (%s) %ds",
                         pct, SPINNER_FRAMES[spinner_idx % SPINNER_FRAMES.length], elapsed)
            $stdout.flush
            spinner_idx += 1
            sleep 0.1
          end
        end
      end

      items.each do |src_child|
        base = File.basename(src_child)
        tgt_child = (target_path / base).to_s

        item_ok = if File.symlink?(src_child)
          # clonefile(2) follows symlinks in src regardless of flags on this
          # macOS version, producing a regular file. Handle symlinks explicitly.
          begin
            File.symlink(File.readlink(src_child), tgt_child)
            true
          rescue SystemCallError
            false
          end
        elsif Clonefile.available? && Clonefile.clone(src_child, tgt_child)
          true
        else
          _, _, st = Sh.capture3("cp", "--reflink=auto", "-R", src_child, tgt_child)
          st.success?
        end

        failed_items << base unless item_ok
        state_mutex.synchronize { done_count += 1 }
      end

      clone_elapsed = (Time.now - clone_start).to_i
      state_mutex.synchronize { clone_done = true }

      # Stop the spinner first so the user isn't staring at a frozen 100%
      # bar while we wait for du to finish.
      if render_thread
        render_thread.join
        print "\r\e[K"
        $stdout.flush
      end

      # Give du up to 3s to finish. If it misses the window (shouldn't
      # happen since cloning takes much longer), just omit the size.
      du_thread.join(3)

      size_str = source_size_bytes ? "#{Sizes.human(source_size_bytes)} in " : ""
      excl_note = excluded.any? ? ", #{excluded.size} excluded" : ""
      Log.info "copied source content (#{size_str}#{clone_elapsed}s#{excl_note})"
      failed_items.each { |b| Log.warn_ "failed to clone #{b}" }

      # Sync the index, restore tracked files, and remove stale untracked files.
      #
      # Clonefile copies the SOURCE working tree into the new worktree. If the
      # feature branch diverges from the source branch, git reports every
      # differing tracked file as "modified" and every source-only file as
      # "untracked". Three-step fix:
      #   1. git reset HEAD      — syncs the index to the branch's HEAD
      #   2. git checkout HEAD . — restores tracked working-tree files to match
      #   3. git clean -fd       — removes untracked files that exist in the
      #                            source but not on this branch (e.g. files
      #                            committed to master after branching)
      #
      # Gitignored files (.env, docker-compose.local.ctree.yml, node_modules,
      # etc.) are untouched by git checkout and git clean -fd, so the source
      # content ctree copied for those paths is preserved.
      sync_start = Time.now
      _, _, rst = Spinner.with_spinner("syncing git index") do
        Sh.capture3("git", "-C", target_path.to_s, "reset", "HEAD")
      end
      if rst.success?
        _, co_err, co_st = Spinner.with_spinner("restoring tracked files to branch HEAD") do
          Sh.capture3("git", "-C", target_path.to_s, "checkout", "HEAD", "--", ".")
        end
        if co_st.success?
          _, cl_err, cl_st = Spinner.with_spinner("removing source-only untracked files") do
            Sh.capture3("git", "-C", target_path.to_s, "clean", "-fd")
          end
          if cl_st.success?
            Log.info "synced git index and working tree (#{(Time.now - sync_start).to_i}s)"
          else
            Log.warn_ "git clean -fd failed: #{cl_err.strip}; git status may show untracked files"
          end
        else
          Log.warn_ "git checkout HEAD failed: #{co_err.strip}; git status may show unexpected changes"
        end
      else
        Log.warn_ "git reset HEAD returned non-zero; git status may show unexpected changes"
      end

      # Recreate .ctree/config.yml from source after the git sync.
      # .ctree is gitignored, so git checkout/clean never touches it.
      # Without this step the worktree would have no .ctree/config.yml at all,
      # since the hardcoded .ctree skip above prevents raw-cloning the directory.
      tgt_ctree_config = target_path / ".ctree" / "config.yml"
      unless tgt_ctree_config.file?
        src_ctree_config = source_root / ".ctree" / "config.yml"
        if src_ctree_config.file?
          FileUtils.mkdir_p(tgt_ctree_config.dirname.to_s)
          FileUtils.cp(src_ctree_config.to_s, tgt_ctree_config.to_s)
          Log.debug "recreated .ctree/config.yml in worktree (source not git-tracked)"
        end
      end

      # When --config was given, persist the custom config into the worktree's
      # .ctree/config.yml so later commands run from inside it pick it up.
      # This must happen AFTER the git-sync step above, otherwise git checkout
      # HEAD -- . would overwrite it with the committed version.
      if config_path
        ctree_dir = target_path / ".ctree"
        FileUtils.mkdir_p(ctree_dir.to_s)
        FileUtils.cp(File.expand_path(config_path, Dir.pwd), (ctree_dir / "config.yml").to_s)
        Log.info "using custom config #{config_path} for this worktree (persisted to .ctree/config.yml)"
      end

      config[:update].each do |rel|
        if rel == ".ctree" || rel.start_with?(".ctree/")
          Log.debug "skipped #{rel} (reserved directory managed by ctree create)"
          next
        end
        src = source_root / rel
        tgt = target_path / rel
        begin
          if src.directory?
            FileUtils.mkdir_p(tgt.to_s)
            FileUtils.cp_r(src.children.map(&:to_s), tgt.to_s)
            Log.debug "copied #{rel}/ from source (update)"
          elsif src.file?
            FileUtils.cp(src.to_s, tgt.to_s)
            Log.debug "copied #{rel} from source (update)"
          end
        rescue => e
          Log.warn_ "update: failed to copy #{rel}: #{e.message}"
        end
      end

      # === tag source images to target project names ===
      # Docker builds per-project images tagged <project>-<service>. Without
      # tagging, `docker compose up` in the new worktree rebuilds all images
      # even though they are identical to the source. Tagging costs zero time
      # (it is a metadata pointer) and makes subsequent dcup skip the build.
      # Must happen before docker compose up --no-start so --no-build can
      # resolve images.

      tagged = Images.tag_to_target(source_project, target_project)
      Log.info "tagged #{tagged.size} docker images" if tagged.any? && !Log.debug?

      # === discover and replicate volumes ===

      volume_results = []

      vols_out, _, status = Sh.capture3("docker", "volume", "ls", "--format", "{{.Name}}")
      Log.die "docker volume ls failed" unless status.success?

      prefix_re = /\A#{Regexp.escape(source_project)}_/
      source_volumes = vols_out.lines.map(&:strip).reject(&:empty?).select { |v| v =~ prefix_re }

      if source_volumes.empty?
        Log.debug "no source volumes found with prefix '#{source_project}_'"
      end

      # Rewrite override.yml to mark shared (cache) volumes as external BEFORE
      # docker compose up --no-start, so Compose points them at the source
      # volume rather than creating new empty ones.
      override_rel = config[:compose_override_file].to_s
      tgt_override = override_rel.empty? ? nil : (target_path / override_rel)
      externalized_suffixes = []

      if share_volumes.any?
        if override_rel.empty? || tgt_override.nil?
          Log.warn_ "compose_override_file not configured; shared volumes will not be externalized: #{share_volumes.join(", ")}"
        elsif !tgt_override.file?
          Log.warn_ "#{override_rel} not found in worktree; shared volumes will not be externalized: #{share_volumes.join(", ")}"
        else
          shared_keys = []
          begin
            stream = Psych.parse_stream(File.read(tgt_override.to_s))
            doc_node = stream.children.first || begin
              d = Psych::Nodes::Document.new
              stream.children << d
              d
            end

            root = doc_node.children.first
            unless root.is_a?(Psych::Nodes::Mapping)
              root = Psych::Nodes::Mapping.new
              doc_node.children.unshift(root)
            end

            vol_key_idx = nil
            root.children.each_with_index do |child, i|
              if i.even? && child.is_a?(Psych::Nodes::Scalar) && child.value == "volumes"
                vol_key_idx = i
                break
              end
            end

            volumes_node = if vol_key_idx
              root.children[vol_key_idx + 1]
            else
              m = Psych::Nodes::Mapping.new
              root.children << Psych::Nodes::Scalar.new("volumes")
              root.children << m
              m
            end

            if volumes_node.is_a?(Psych::Nodes::Mapping)
              share_volumes.each do |suffix|
                src_name = "#{source_project}_#{suffix}"
                unless source_volumes.include?(src_name)
                  Log.warn_ "source volume #{src_name} not found; #{suffix} will not be shared with source"
                  next
                end

                entry = Psych::Nodes::Mapping.new
                entry.children << Psych::Nodes::Scalar.new("external")
                entry.children << Psych::Nodes::Scalar.new("true", nil, nil, true, false)
                entry.children << Psych::Nodes::Scalar.new("name")
                entry.children << Psych::Nodes::Scalar.new(src_name)

                volumes_node.children << Psych::Nodes::Scalar.new(suffix)
                volumes_node.children << entry
                shared_keys << suffix
              end

              if shared_keys.any?
                File.write(tgt_override.to_s, stream.to_yaml)
                externalized_suffixes = shared_keys
                shared_keys.each { |k| Log.debug "shared #{k} -> #{source_project}_#{k}" }
                if Log.debug?
                  Log.debug "added shared volumes to #{File.basename(tgt_override.to_s)}"
                else
                  Log.info "updated #{File.basename(tgt_override.to_s)}"
                end
              else
                Log.warn_ "no source volumes found for share_volumes; worktree will use its own isolated copies"
              end
            else
              Log.warn_ "#{tgt_override}: 'volumes' is not a mapping; skipping shared volume override"
            end
          rescue Psych::SyntaxError => e
            Log.warn_ "could not parse #{tgt_override}: #{e.message}; skipping shared volume override"
          end
        end
      end

      # Write identity env vars before compose up so variable interpolation in
      # project-specific override files resolves correctly during volume creation.
      tgt_env_path = target_path / env_filename
      EnvFile.upsert(tgt_env_path.to_s, "COMPOSE_PROJECT_NAME", target_project)
      EnvFile.upsert(tgt_env_path.to_s, config[:host_name], name)
      pre_suffix = config[:host_name_suffix].to_s
      EnvFile.upsert(tgt_env_path.to_s, "HOST_NAME_SUFFIX", pre_suffix) unless pre_suffix.empty?

      override_file = config[:compose_override_file].to_s
      if !override_file.empty? && (target_path / override_file).file?
        current_cf = EnvFile.parse(tgt_env_path.to_s)["COMPOSE_FILE"].to_s
        parts = current_cf.split(":").map(&:strip).reject(&:empty?)
        unless parts.include?(override_file)
          cf_action = EnvFile.upsert(tgt_env_path.to_s, "COMPOSE_FILE", (parts + [override_file]).join(":"))
          Log.debug "appended #{override_file} to COMPOSE_FILE (#{cf_action}) in #{tgt_env_path}"
        end
      end

      # Snapshot volumes that exist before --no-start for idempotency: if a
      # target volume is already present, skip copying data into it.
      all_vols_out, _, _ = Sh.capture3("docker", "volume", "ls", "--format", "{{.Name}}")
      pre_existing_vols = all_vols_out.lines.map(&:strip).freeze

      # Let Compose create all non-external volumes with its ownership labels
      # so `docker compose up` later doesn't warn about externally managed volumes.
      #
      # Services are created one at a time rather than via a single `up` for
      # every service: when two containers mounting the same brand-new empty
      # volume are *created* concurrently, Docker races to populate that volume
      # from the image's baked-in content for each of them, and the loser fails
      # with "failed to mkdir ...: file exists" (e.g. multiple services sharing
      # a gem-cache volume). Creating services sequentially means a volume is
      # already non-empty by the time the second service mounts it, so Docker
      # skips the populate step entirely and there's nothing left to race on.
      services_out, services_err, services_st = Sh.capture3(
        "docker", "compose",
        "--project-directory", target_path.to_s,
        "--project-name", target_project,
        "config", "--services",
        chdir: target_path.to_s
      )
      services = services_st.success? ? services_out.lines.map(&:strip).reject(&:empty?) : []

      no_start_errors = []
      Spinner.with_spinner("creating target volumes") do
        if services.empty?
          Log.warn_ "could not list compose services (#{services_err.strip}); falling back to single up --no-start"
          _, err, st = Sh.capture3(
            "docker", "compose",
            "--project-directory", target_path.to_s,
            "--project-name", target_project,
            "up", "--no-start", "--no-build",
            chdir: target_path.to_s
          )
          no_start_errors << err.strip unless st.success?
        else
          services.each do |service|
            _, err, st = Sh.capture3(
              "docker", "compose",
              "--project-directory", target_path.to_s,
              "--project-name", target_project,
              "up", "--no-start", "--no-build", service,
              chdir: target_path.to_s
            )
            no_start_errors << "#{service}: #{err.strip}" unless st.success?
          end
        end
      end
      Log.warn_ "docker compose up --no-start: #{no_start_errors.join("; ")}" unless no_start_errors.empty?

      empty_count = 0
      source_volumes.each do |src_vol|
        suffix = src_vol.sub(prefix_re, "")
        tgt_vol = "#{target_project}_#{suffix}"
        next unless empty_volumes.include?(suffix)
        Log.debug "created #{tgt_vol} (empty volume)"
        empty_count += 1
      end
      Log.info "created #{empty_count} empty volumes" if empty_count > 0 && !Log.debug?

      volume_copy_start = Time.now
      volume_copy_bytes = 0
      source_volumes.each do |src_vol|
        suffix = src_vol.sub(prefix_re, "")
        tgt_vol = "#{target_project}_#{suffix}"

        if share_volumes.include?(suffix)
          if externalized_suffixes.include?(suffix)
            volume_results << [src_vol, tgt_vol, :shared, "shared from source"]
          else
            Log.debug "skipped copy of #{src_vol} (not shared: no entry in #{override_rel}; worktree will create a fresh volume)"
            volume_results << [src_vol, tgt_vol, :skipped, "not copied, not shared"]
          end
          next
        end

        if empty_volumes.include?(suffix)
          volume_results << [src_vol, tgt_vol, :empty, "empty volume"]
          next
        end

        if pre_existing_vols.include?(tgt_vol)
          Log.warn_ "skipping #{tgt_vol} (already exists)"
          volume_results << [src_vol, tgt_vol, :skipped, "already exists"]
          next
        end

        st, err, vol_bytes = Volume.copy_with_progress(src_vol, tgt_vol)
        if st.success?
          volume_copy_bytes += vol_bytes.to_i
          volume_results << [src_vol, tgt_vol, :copied, ""]
        else
          Log.warn_ "copy failed for #{tgt_vol}: #{err.strip}"
          volume_results << [src_vol, tgt_vol, :failed, "copy failed: #{err.strip}"]
        end
      end

      copied_count = volume_results.count { |_, _, st, _| st == :copied }
      if copied_count > 0
        volume_copy_elapsed = (Time.now - volume_copy_start).to_i
        size_note = volume_copy_bytes > 0 ? "#{Sizes.human(volume_copy_bytes)} in " : ""
        Log.info "copied #{copied_count} volumes (#{size_note}#{volume_copy_elapsed}s)" unless Log.debug?
      end

      # === update .env in the new worktree ===
      # The .env was carried over by the clone; only the fields that must
      # differ per worktree need updating.

      unless tgt_env_path.file?
        Log.info "source has no #{env_filename}; creating one in target"
      end

      # COMPOSE_PROJECT_NAME is always auto-set to the target project name.
      # config[:host_name] specifies which .env variable is auto-set to the
      # worktree name (for domain routing). Keys in config[:skip_env_keys] are
      # also auto-set from source. All others are presented interactively.
      host_env_key = config[:host_name]
      suffix = config[:host_name_suffix].to_s
      host_domain_env_key = config[:host_domain_env_key].to_s
      effective_skip_keys = config[:skip_env_keys].reject { |k| k == host_domain_env_key }
      auto_set = (["COMPOSE_PROJECT_NAME", "COMPOSE_FILE", host_env_key, "HOST_NAME_SUFFIX"] +
                  (host_domain_env_key.empty? ? [] : [host_domain_env_key]) +
                  effective_skip_keys).freeze

      cpn_action = EnvFile.upsert(tgt_env_path.to_s, "COMPOSE_PROJECT_NAME", target_project)
      Log.debug "COMPOSE_PROJECT_NAME=#{target_project} (#{cpn_action}) in #{tgt_env_path}"

      host_action = EnvFile.upsert(tgt_env_path.to_s, host_env_key, name)
      Log.debug "#{host_env_key}=#{name} (#{host_action}) in #{tgt_env_path}"

      unless suffix.empty?
        suffix_action = EnvFile.upsert(tgt_env_path.to_s, "HOST_NAME_SUFFIX", suffix)
        Log.debug "HOST_NAME_SUFFIX=#{suffix} (#{suffix_action}) in #{tgt_env_path}"
      end

      unless host_domain_env_key.empty? || suffix.empty?
        domain_val = "#{name}.#{suffix}"
        domain_action = EnvFile.upsert(tgt_env_path.to_s, host_domain_env_key, domain_val)
        Log.debug "#{host_domain_env_key}=#{domain_val} (#{domain_action}) in #{tgt_env_path}"
      end

      final_env_vars = { host_env_key => name }
      final_env_vars["HOST_NAME_SUFFIX"] = suffix unless suffix.empty?
      unless host_domain_env_key.empty? || suffix.empty?
        final_env_vars[host_domain_env_key] = "#{name}.#{suffix}"
      end
      promptable = source_env_vars.reject { |k, v| auto_set.include?(k) || v.nil? || v.empty? }

      # Collect sibling worktree .env values so the prompt can show what each
      # worktree already has, helping the user pick non-conflicting values.
      sibling_envs = {}
      wt_out, _, wt_st = Sh.capture3("git", "-C", source_root.to_s, "worktree", "list", "--porcelain")
      if wt_st.success?
        source_real = source_root.realpath
        target_real = begin; target_path.realpath; rescue Errno::ENOENT; target_path; end
        wt_out.each_line do |line|
          next unless line.start_with?("worktree ")
          wt_path = Pathname.new(line.strip.delete_prefix("worktree "))
          wt_real = begin; wt_path.realpath; rescue Errno::ENOENT; wt_path; end
          next if wt_real == source_real || wt_real == target_real
          env_path = wt_path / env_filename
          sibling_envs[wt_path.basename.to_s] = EnvFile.parse(env_path.to_s) if env_path.file?
        end
      end

      unless promptable.empty?
        puts
        promptable.each do |key, value|
          worktree_values = sibling_envs.filter_map { |wt, env| [wt, env[key]] if env[key] }.to_h
          new_value = Prompt.for_env_var_change(key, value, worktree_values: worktree_values)
          final_env_vars[key] = new_value

          if new_value != value
            action = EnvFile.upsert(tgt_env_path.to_s, key, new_value)
            Log.debug "#{key}=#{new_value} (#{action}) in #{tgt_env_path}"
          else
            Log.debug "#{key}=#{value} (kept) in #{tgt_env_path}"
          end
        end
      end

      Log.info "updated #{env_filename}" unless Log.debug?

      # === final report ===

      if Log.debug?
        puts
        puts "=== ctree summary ==="
        puts "worktree:  #{target_path}"
        puts "branch:    #{branch}#{branch_exists ? " (existing, checked out)" : " (new)"}"
        puts "#{env_filename}:      #{tgt_env_path}"
        final_env_vars.each { |k, v| puts "  #{k}=#{v}" }
        puts "override:  #{override_rel.empty? ? "(none configured)" : override_rel}"
        puts

        if volume_results.any?
          puts "volumes:"
          copied  = volume_results.select { |_, _, st, _| st == :copied || st == :skipped || st == :failed }
          empty   = volume_results.select { |_, _, st, _| st == :empty }
          shared  = volume_results.select { |_, _, st, _| st == :shared }
          (copied + empty + shared).each do |src, tgt, st, msg|
            line = case st
            when :shared then "  [shared ] #{src} (#{msg})"
            when :empty  then "  [empty  ] #{tgt} (#{msg})"
            else
              l = "  [#{st.to_s.ljust(7)}] #{src} -> #{tgt}"
              msg.to_s.empty? ? l : "#{l} (#{msg})"
            end
            puts line
          end
          puts
        end
      end

      any_failed = volume_results.any? { |_, _, st, _| st == :failed }

      # === offer to rebase a stale existing branch onto master ===
      # Worktree runtime state (gem/package volumes and their lockfiles) is
      # replicated from the source's master. An existing branch that is behind
      # master can have tracked lockfiles that no longer match the copied state,
      # which can prevent the stack from booting. Offer to rebase onto master
      # before the user moves into the worktree.
      if branch_exists
        behind_out, _, behind_st = Sh.capture3(
          "git", "-C", target_path.to_s, "rev-list", "--count", "HEAD..master"
        )
        behind = behind_st.success? ? behind_out.strip.to_i : 0
        if behind > 0
          Log.warn_ "branch '#{branch}' is #{behind} commit(s) behind master"
          Log.warn_ "its lockfiles may not match the replicated gem/package"
          Log.warn_ "volumes, which can prevent the stack from booting"
          raw = Prompt.read_line("[#{PROG}] rebase '#{branch}' onto master now? [Y/n]: ")
          answer = raw.to_s.gsub(/[\x00-\x1f\x7f]/, "").strip.downcase
          if answer.empty? || answer == "y" || answer == "yes"
            _, _, rb_st = Spinner.with_spinner("rebasing #{branch} onto master") do
              Sh.capture3("git", "-C", target_path.to_s, "rebase", "master")
            end
            if rb_st.success?
              Log.info "rebased #{branch} onto master"
            else
              Sh.capture3("git", "-C", target_path.to_s, "rebase", "--abort")
              Log.warn_ "rebase conflict — aborted; resolve manually with `ctree rebase` from the worktree"
            end
          else
            Log.info "skipped rebase; run `ctree rebase` from the worktree later if needed"
          end
        end
      end

      exit(any_failed ? 2 : 0)
    end
  end
end
