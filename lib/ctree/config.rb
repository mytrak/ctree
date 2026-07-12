# frozen_string_literal: true

module Ctree
  # Configuration is layered (lowest → highest priority):
  #   1. lib/ctree/config.yml            — shipped defaults (always the base).
  #   2. <source_root>/.ctree/config.yml — per-repo override; created by
  #                                        `ctree config add`. Keys here win.
  #
  # Schema (all keys optional):
  #   update_volumes: [<string>, ...]
  #   share_volumes: [<string>, ...]
  #   skip_env_keys:        [<string>, ...]
  module Config
    module_function

    SHIPPED_CONFIG_PATH   = File.expand_path("config.yml", __dir__)
    REPO_CONFIG_REL       = File.join(".ctree", "config.yml")
    ARRAY_KEYS            = %w[update_volumes share_volumes skip_env_keys].freeze
    OPTIONAL_ARRAY_KEYS   = %w[rebase exclude update empty_volumes post_update_hooks].freeze
    STRING_KEYS           = %w[env_filename host_name].freeze
    OPTIONAL_STRING_KEYS  = %w[host_name_suffix compose_override_file host_domain_env_key free_branch_prefix].freeze
    VALID_LOG_LEVELS      = %w[info debug].freeze
    SUPPORTED_KEYS        = (ARRAY_KEYS + OPTIONAL_ARRAY_KEYS + STRING_KEYS + OPTIONAL_STRING_KEYS + %w[log_level]).freeze

    def load(source_root)
      # Layered lowest → highest priority. Shipped defaults are always the
      # base so a partial repo config only overrides the keys it sets;
      # unspecified keys fall through to the shipped values.
      #   1. shipped defaults
      #   2. per-repo (<source_root>/.ctree/config.yml)
      result = load_yaml(SHIPPED_CONFIG_PATH, must_exist: true)

      repo_path = File.join(source_root.to_s, REPO_CONFIG_REL)
      if File.file?(repo_path)
        result = result.merge(load_yaml(repo_path, must_exist: false)) { |_, _, v| v }
      end

      validate_and_normalize(result, repo_path)
    end

    # Returns the shipped defaults as a normalized, symbol-keyed hash.
    def defaults
      raw = load_yaml(SHIPPED_CONFIG_PATH, must_exist: true)
      validate_and_normalize(raw, SHIPPED_CONFIG_PATH)
    end

    # Scaffolds <repo_top>/.ctree/config.yml from the shipped template so the
    # repo has an annotated, committable per-repo config. Must be run inside a
    # git repository; refuses to clobber an existing file without confirmation.
    def add_local!
      top = repo_top_or_die
      dir = top / ".ctree"
      target = dir / "config.yml"
      if target.exist?
        raw = Prompt.read_line("[#{PROG}] Config file exists: #{target}. Reset it? [y/N]: ")
        answer = raw.to_s.gsub(/[\x00-\x1f\x7f]/, "").strip.downcase
        unless answer == "y" || answer == "yes"
          Log.info "keeping existing config"
          return
        end
      end

      already_existed = target.exist?
      FileUtils.mkdir_p(dir.to_s)
      FileUtils.cp(SHIPPED_CONFIG_PATH, target.to_s)
      Log.info "#{already_existed ? "reset" : "created"} #{target}"
      Log.info "edit it to set this repo's ctree config"
    end

    # Removes <repo_top>/.ctree/config.yml and the .ctree directory. Must be
    # run inside a git repository. If .ctree holds files other than config.yml,
    # the directory is kept (we don't delete content ctree didn't create).
    def remove_local!
      top = repo_top_or_die
      dir = top / ".ctree"
      target = dir / "config.yml"
      unless target.exist?
        Log.info "no local config file found at #{target}"
        return
      end
      puts
      puts "[#{PROG}] About to delete:"
      puts "  #{target}"
      puts "  #{dir}/  (if empty after removing the config)"
      puts
      raw = Prompt.read_line("[#{PROG}] Type 'yes' to confirm removal: ")
      answer = raw.to_s.gsub(/[\x00-\x1f\x7f]/, "").strip
      unless answer == "yes"
        Log.info "aborted — config file kept"
        return
      end
      File.delete(target.to_s)
      Log.info "deleted #{target}"

      remaining = dir.children
      if remaining.empty?
        Dir.rmdir(dir.to_s)
        Log.info "removed #{dir}"
      else
        Log.warn_ "kept #{dir} — it still contains: #{remaining.map(&:basename).join(", ")}"
      end
    end

    # Prints the repo's local config as YAML, or notes that none exists.
    def print_resolved!
      source_root = ensure_at_repo_top!
      repo_path = File.join(source_root.to_s, REPO_CONFIG_REL)
      unless File.file?(repo_path)
        Log.info "no local config file (#{REPO_CONFIG_REL}); run `#{PROG} config add` to create one"
        return
      end
      puts "# Local config: #{repo_path}"
      resolved = load(source_root)
      puts YAML.dump(resolved.transform_keys(&:to_s))
    end

    def ensure_at_repo_top!
      source_root = Pathname.pwd
      toplevel_out, _, status = Sh.capture3("git", "-C", source_root.to_s, "rev-parse", "--show-toplevel")
      Log.die "not inside a git repository" unless status.success?
      git_top = Pathname.new(toplevel_out.strip)
      unless source_root.realpath == git_top.realpath
        Log.die "must be invoked from project top-level (cwd=#{source_root}, top=#{git_top})"
      end
      source_root
    end

    # Returns the repository top-level for the current directory, or dies with
    # a warning. Unlike ensure_at_repo_top!, this works from any subdirectory
    # of the repo — config add/remove always operate on the repo top-level.
    def repo_top_or_die
      toplevel_out, _, status = Sh.capture3("git", "-C", Pathname.pwd.to_s, "rev-parse", "--show-toplevel")
      Log.die "ctree config must be run from within a git repository" unless status.success?
      Pathname.new(toplevel_out.strip)
    end

    def load_yaml(path, must_exist:)
      raw = nil
      begin
        raw = YAML.safe_load(File.read(path), aliases: true)
      rescue Errno::ENOENT
        Log.die "ctree defaults file missing: #{path}" if must_exist
        return {}
      rescue Psych::SyntaxError => e
        if must_exist
          Log.die "could not parse ctree defaults #{path}: #{e.message}"
        else
          Log.warn_ "could not parse #{path}: #{e.message}; ignoring overrides"
          return {}
        end
      end

      unless raw.is_a?(Hash)
        Log.die "#{path}: top-level must be a YAML mapping" if must_exist
        Log.warn_ "#{path}: top-level must be a YAML mapping; ignoring overrides"
        return {}
      end

      raw
    end

    def validate_and_normalize(merged, config_path)
      result = {}
      # Insertion order here is the order `ctree config` prints. Keep
      # host_name and host_name_suffix adjacent.
      ARRAY_KEYS.each do |key|
        val = merged[key]
        unless val.is_a?(Array) && val.all? { |x| x.is_a?(String) }
          Log.die "missing or invalid #{key.inspect} in ctree config (check config.yml or #{config_path})"
        end
        result[key.to_sym] = val.dup
      end
      OPTIONAL_ARRAY_KEYS.each do |key|
        val = merged[key]
        unless val.nil? || (val.is_a?(Array) && val.all? { |x| x.is_a?(String) })
          Log.die "missing or invalid #{key.inspect} in ctree config (check config.yml or #{config_path})"
        end
        result[key.to_sym] = (val || []).dup
      end
      STRING_KEYS.each do |key|
        val = merged[key]
        unless val.is_a?(String) && !val.strip.empty?
          Log.die "missing or invalid #{key.inspect} in ctree config (check config.yml or #{config_path})"
        end
        result[key.to_sym] = val.dup
      end
      OPTIONAL_STRING_KEYS.each do |key|
        val = merged[key]
        unless val.nil? || val.is_a?(String)
          Log.die "missing or invalid #{key.inspect} in ctree config (check config.yml or #{config_path})"
        end
        result[key.to_sym] = (val || "").dup
      end
      log_level_val = merged["log_level"]
      if log_level_val.nil?
        result[:log_level] = "info"
      elsif VALID_LOG_LEVELS.include?(log_level_val)
        result[:log_level] = log_level_val
      else
        Log.die "invalid log_level #{log_level_val.inspect} in ctree config; must be one of: #{VALID_LOG_LEVELS.join(", ")}"
      end
      result
    end
  end
end
