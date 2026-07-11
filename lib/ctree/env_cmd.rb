# frozen_string_literal: true

module Ctree
  module EnvCmd
    module_function

    def run(subcommand)
      target_path, source_root = resolve_worktree!
      config    = Config.load(source_root)
      skip_keys = config[:skip_env_keys]

      case subcommand
      when "list"  then cmd_list(target_path, source_root, skip_keys, config[:env_filename])
      when "check" then cmd_check(target_path, source_root, config)
      when "fix"   then cmd_fix(target_path, source_root, config)
      else Log.die "unknown subcommand '#{subcommand}'; use: list, check, or fix"
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
        Log.die "already in the source project; run ctree env from inside a worktree"
      end
      [target_path.realpath, source_root]
    end

    def missing_keys(src_env, tgt_env, skip_keys)
      src_env.keys - tgt_env.keys - skip_keys
    end

    def ctree_managed_keys(config)
      keys = ["COMPOSE_PROJECT_NAME"]
      host_name_key = config[:host_name].to_s.strip
      keys << host_name_key unless host_name_key.empty?
      keys << "HOST_NAME_SUFFIX" unless config[:host_name_suffix].to_s.strip.empty?
      domain_key = config[:host_domain_env_key].to_s.strip
      keys << domain_key unless domain_key.empty?
      keys.uniq
    end

    def cmd_list(target_path, source_root, skip_keys, env_filename)
      tgt_env_path = target_path / env_filename
      Log.die "no #{env_filename} found at #{tgt_env_path}" unless tgt_env_path.file?
      src_env_path = source_root / env_filename
      Log.die "no #{env_filename} found in source repo at #{src_env_path}" unless src_env_path.file?

      tgt_env = EnvFile.parse(tgt_env_path.to_s)
      tgt_env.each { |k, v| puts "#{k}=#{v}" }
      exit 0
    end

    def cmd_check(target_path, source_root, config)
      env_filename = config[:env_filename]
      tgt_env_path = target_path / env_filename
      Log.die "no #{env_filename} found at #{tgt_env_path}" unless tgt_env_path.file?
      src_env_path = source_root / env_filename
      Log.die "no #{env_filename} found in source repo at #{src_env_path}" unless src_env_path.file?

      tgt_env = EnvFile.parse(tgt_env_path.to_s)
      src_env = EnvFile.parse(src_env_path.to_s)

      managed   = ctree_managed_keys(config)
      missing   = src_env.keys - tgt_env.keys
      extra     = tgt_env.keys - src_env.keys - managed - config[:skip_env_keys]

      if missing.empty? && extra.empty?
        Log.info "env is in sync"
        exit 0
      else
        missing.each { |k| puts "[missing] #{k}" }
        extra.each   { |k| puts "[extra] #{k}" }
        exit 1
      end
    end

    def cmd_fix(target_path, source_root, config)
      env_filename = config[:env_filename]
      tgt_env_path = target_path / env_filename
      Log.die "no #{env_filename} found at #{tgt_env_path}" unless tgt_env_path.file?
      src_env_path = source_root / env_filename
      Log.die "no #{env_filename} found in source repo at #{src_env_path}" unless src_env_path.file?

      tgt_env = EnvFile.parse(tgt_env_path.to_s)
      src_env = EnvFile.parse(src_env_path.to_s)

      managed        = ctree_managed_keys(config)
      effective_skip = (config[:skip_env_keys] + managed).uniq
      missing        = src_env.keys - tgt_env.keys - managed
      orphaned       = tgt_env.keys - src_env.keys - effective_skip

      if missing.empty? && orphaned.empty?
        Log.info "env is in sync; nothing to fix"
        exit 0
      end

      missing.each do |key|
        new_value = Prompt.for_env_var_change(key, src_env[key])
        EnvFile.upsert(tgt_env_path.to_s, key, new_value)
      end

      orphaned.each do |key|
        raw = Prompt.read_line("[#{PROG}] #{key}=#{tgt_env[key]} (not in source #{env_filename}, delete? [y/N]): ")
        answer = raw.to_s.gsub(/[\x00-\x1f\x7f]/, "").strip.downcase
        EnvFile.delete(tgt_env_path.to_s, key) if answer == "y" || answer == "yes"
      end

      Log.info "updated #{env_filename}"
      exit 0
    end

    private_class_method :resolve_worktree!, :missing_keys, :ctree_managed_keys,
                         :cmd_list, :cmd_check, :cmd_fix
  end
end
