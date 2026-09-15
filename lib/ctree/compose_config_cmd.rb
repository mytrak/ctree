# frozen_string_literal: true

module Ctree
  module ComposeConfigCmd
    module_function

    def run(subcommand)
      target_path, source_root = resolve_worktree!
      config        = Config.load(target_path)
      Log.log_prefix = config[:log_prefix]
      override_rel  = config[:compose_override_file].to_s
      share_volumes = config[:share_volumes]
      env_filename  = config[:env_filename]

      case subcommand
      when "list"
        cmd_list(target_path, override_rel)
      when "check"
        source_project, source_volumes = resolve_source!(source_root, env_filename)
        cmd_check(target_path, override_rel, share_volumes, source_project, source_volumes)
      when "fix"
        source_project, source_volumes = resolve_source!(source_root, env_filename)
        cmd_fix(target_path, override_rel, share_volumes, source_project, source_volumes)
      else
        Log.die "unknown subcommand '#{subcommand}'; use: list, check, or fix"
      end
    end

    def resolve_worktree!
      target_path = Pathname.pwd
      toplevel_out, _, st = Sh.capture3("git", "-C", target_path.to_s, "rev-parse", "--show-toplevel")
      Log.die "not inside a git repository" unless st.success?
      git_top = Pathname.new(toplevel_out.strip)
      unless target_path.realpath == git_top.realpath
        Log.die "must be invoked from the worktree top-level"
      end
      common_out, _, c_st = Sh.capture3("git", "-C", target_path.to_s, "rev-parse", "--git-common-dir")
      Log.die "could not resolve git common dir" unless c_st.success?
      common = Pathname.new(common_out.strip)
      common = (target_path / common) unless common.absolute?
      source_root = common.parent.realpath
      if source_root == target_path.realpath
        Log.die "already in the source project; run ctree compose-config from inside a worktree"
      end
      [target_path.realpath, source_root]
    end

    def resolve_source!(source_root, env_filename)
      source_env = EnvFile.parse(source_root / env_filename)
      env_cpn = source_env["COMPOSE_PROJECT_NAME"]
      source_project = (env_cpn && !env_cpn.empty?) ? env_cpn :
                       Naming.sanitize_compose_project_name(source_root.basename.to_s)

      docker_ok = Sh.system("docker", "info", out: File::NULL, err: File::NULL)
      Log.die "docker not reachable" unless docker_ok

      vols_out, _, st = Sh.capture3("docker", "volume", "ls", "--format", "{{.Name}}")
      Log.die "docker volume ls failed" unless st.success?
      prefix_re = /\A#{Regexp.escape(source_project)}_/
      source_volumes = vols_out.lines.map(&:strip).reject(&:empty?).select { |v| v =~ prefix_re }
      [source_project, source_volumes]
    end

    def cmd_list(target_path, override_rel)
      Log.die "compose_override_file not configured" if override_rel.empty?
      override_path = target_path / override_rel
      Log.die "#{override_rel} not found" unless override_path.file?
      puts override_path.read
      exit 0
    end

    def cmd_check(target_path, override_rel, share_volumes, source_project, source_volumes)
      Log.die "compose_override_file not configured" if override_rel.empty?

      if share_volumes.empty?
        Log.info "no share_volumes configured"
        exit 0
      end

      override_path = target_path / override_rel
      unless override_path.file?
        Log.warn_ "#{override_rel} not found in worktree"
        exit 1
      end

      result = ComposeOverride.audit(
        target_path: target_path, override_rel: override_rel,
        share_volumes: share_volumes, source_project: source_project,
        source_volumes: source_volumes
      )

      total = result[:fixable].size + result[:unfixable].size
      if total > 0
        if result[:fixable].any?
          Log.warn_ "#{total} issue#{total == 1 ? "" : "s"} found — run `ctree compose-config fix` to fix"
        else
          Log.warn_ "#{total} issue#{total == 1 ? "" : "s"} found — source volumes missing, repair not possible"
        end
        exit 1
      end

      Log.info "#{override_rel} is valid"
      exit 0
    end

    def cmd_fix(target_path, override_rel, share_volumes, source_project, source_volumes)
      Log.die "compose_override_file not configured" if override_rel.empty?

      if share_volumes.empty?
        Log.info "no share_volumes configured"
        exit 0
      end

      result = ComposeOverride.audit(
        target_path: target_path, override_rel: override_rel,
        share_volumes: share_volumes, source_project: source_project,
        source_volumes: source_volumes
      )

      if result[:fixable].empty? && result[:unfixable].empty?
        Log.info "#{override_rel} is already correct"
        exit 0
      end

      ComposeOverride.fix(
        target_path: target_path, override_rel: override_rel,
        share_volumes: share_volumes, source_project: source_project,
        source_volumes: source_volumes
      )
      exit 0
    end

    private_class_method :resolve_worktree!, :resolve_source!,
                         :cmd_list, :cmd_check, :cmd_fix
  end
end
