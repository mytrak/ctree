# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "pathname"
require "yaml"

begin
  require "readline"
  HAS_READLINE = true
rescue LoadError
  HAS_READLINE = false
end

module Ctree
  PROG = "ctree"
  NAME_PATTERN = /\A[a-z0-9][a-z0-9_-]*\z/.freeze
  # Branch names are more permissive than the worktree/compose name (which
  # doubles as a Docker compose project prefix). Allow letters, digits, ., _,
  # -, and /.
  BRANCH_NAME_PATTERN = %r{\A[A-Za-z0-9][A-Za-z0-9._/-]*\z}.freeze

  SPINNER_FRAMES = %w[| / - \\].freeze

  module Log
    @debug = false
    @log_prefix = true

    module_function

    def debug_mode=(val)
      @debug = val
    end

    def debug?
      @debug
    end

    def log_prefix=(val)
      @log_prefix = val
    end

    # Test-only: specs run in one process, so state must be reset between
    # examples.
    def reset!
      @debug = false
      @log_prefix = true
    end

    def log_prefix?
      @log_prefix
    end

    def prefix
      log_prefix? ? "[#{PROG}] " : ""
    end

    def debug(msg)
      return unless @debug
      if LogFile.enabled?
        LogFile.write("DEBUG: #{msg}")
      else
        puts "#{prefix}#{msg}"
      end
    end

    def info(msg)
      if LogFile.enabled?
        LogFile.write(msg)
      else
        puts "#{prefix}#{msg}"
      end
    end

    def warn_(msg)
      if LogFile.enabled?
        LogFile.write("WARNING: #{msg}")
      else
        warn "#{prefix}WARNING: #{msg}"
      end
    end

    def die(msg, code = 1)
      if LogFile.enabled?
        LogFile.write("ERROR: #{msg}")
        Scroller.stop
        warn "#{prefix}ERROR: #{msg} (see #{LogFile.path} for details)"
      else
        warn "#{prefix}ERROR: #{msg}"
      end
      exit code
    end

    # `interactive: true` marks content that exists only to precede a
    # confirmation prompt (e.g. delete's listing) — skipped from the log
    # file entirely once forced, since it's never shown and is redundant.
    def section(text, interactive: false, force: false)
      if LogFile.enabled?
        LogFile.write_block(text) unless interactive && force
        if interactive && !force
          Scroller.pause
          puts text
        end
      else
        puts text
      end
    end
  end

  module LogFile
    module_function

    def configure(path)
      @path = path
      File.write(@path, "")
    end

    def enabled?
      !@path.nil?
    end

    def path
      @path
    end

    def write(msg)
      return unless enabled?
      ts = Time.now.strftime("%Y-%m-%d %H:%M:%S")
      File.open(@path, "a") { |f| f.puts("[#{ts}] #{msg}") }
    end

    # For one multi-line announcement (e.g. a static listing) that belongs to
    # a single moment in time: timestamps only the first non-blank line and
    # writes the rest as-is, instead of repeating a near-identical timestamp
    # on every line.
    def write_block(text)
      return unless enabled?
      lines = text.each_line(chomp: true).to_a
      lines.shift while lines.first == ""
      return if lines.empty?
      ts = Time.now.strftime("%Y-%m-%d %H:%M:%S")
      File.open(@path, "a") do |f|
        f.puts("[#{ts}] #{lines.shift}")
        lines.each { |line| f.puts(line) }
      end
    end

    # Test-only: specs run in one process, so state must be reset between
    # examples.
    def reset!
      @path = nil
    end
  end

  module Scroller
    module_function

    def start(msg)
      @prefix = "#{Ctree::Log.prefix}#{msg}"
      @start_time = Time.now
      @mutex = Mutex.new
      @paused = false
      @stopped = false
      if $stdout.tty?
        @thread = Thread.new { render_loop }
      else
        @thread = nil
        puts @prefix
      end
    end

    def pause
      return unless @thread
      @mutex.synchronize { @paused = true }
      print "\r\e[K"
      $stdout.flush
    end

    def resume
      return unless @thread
      @mutex.synchronize { @paused = false }
    end

    # Ends the scroller. With no args, just clears the animated line (or is
    # a no-op if nothing was ever started). With `final_message`, replaces
    # that line — same in-place-overwrite trick `Spinner.with_spinner`'s
    # callers use — with a past-tense completion line and elapsed time.
    def stop(final_message = nil)
      elapsed = @start_time && (Time.now - @start_time).to_i
      if @thread
        @mutex.synchronize { @stopped = true }
        @thread.join
        @thread = nil
        print "\r\e[K"
      end
      if final_message
        suffix = elapsed ? " (#{elapsed}s)" : ""
        puts "[#{PROG}] #{final_message}#{suffix}"
      end
      $stdout.flush
    end

    def render_loop
      idx = 0
      until @mutex.synchronize { @stopped }
        unless @mutex.synchronize { @paused }
          elapsed = (Time.now - @start_time).to_i
          line = format("%s (%s) %ds", @prefix,
                        SPINNER_FRAMES[idx % SPINNER_FRAMES.length], elapsed)
          print "\r\e[K#{line}"
          $stdout.flush
          idx += 1
        end
        sleep 0.1
      end
    end

    private_class_method :render_loop
  end

  # Single seam for shelling out. Integration tests stub these.
  module Sh
    module_function

    def capture3(*cmd, **opts)
      Open3.capture3(*cmd, **opts)
    end

    def popen3(*cmd, &blk)
      Open3.popen3(*cmd, &blk)
    end

    def system(*cmd, **kw)
      Kernel.system(*cmd, **kw)
    end

    def spawn(*cmd, **kw)
      Process.spawn(*cmd, **kw)
    end

    def detach(pid)
      Process.detach(pid)
    end
  end

  module EnvFile
    module_function

    def parse(path)
      return {} unless File.file?(path)
      result = {}
      File.foreach(path) do |raw|
        line = raw.strip
        next if line.empty? || line.start_with?("#")
        next unless line.include?("=")
        key, value = line.split("=", 2)
        key = key.strip.sub(/\Aexport\s+/, "")
        value = value.strip
        if (value.start_with?('"') && value.end_with?('"')) ||
           (value.start_with?("'") && value.end_with?("'"))
          value = value[1..-2]
        end
        result[key] = value
      end
      result
    end

    def delete(path, key)
      return unless File.file?(path)
      pattern = /\A\s*#{Regexp.escape(key)}\s*=/
      lines = File.readlines(path).reject { |l| l =~ pattern }
      File.write(path, lines.join)
    end

    def upsert(path, key, value)
      new_line = "#{key}=#{value}"
      unless File.file?(path)
        File.write(path, new_line + "\n")
        return :created
      end

      lines = File.readlines(path)
      matched = false
      pattern = /\A\s*#{Regexp.escape(key)}\s*=/
      lines.map! do |line|
        if line =~ pattern
          matched = true
          keep_newline = line.end_with?("\n") ? "\n" : ""
          new_line + keep_newline
        else
          line
        end
      end

      unless matched
        if lines.any? && !lines.last.end_with?("\n")
          lines[-1] = lines.last + "\n"
        end
        lines << new_line + "\n"
      end

      File.write(path, lines.join)
      matched ? :replaced : :appended
    end
  end

  module Naming
    module_function

    def sanitize_compose_project_name(str)
      out = str.downcase.gsub(/[^a-z0-9_-]/, "_")
      out.sub(/\A[^a-z0-9]+/, "")
    end
  end

  module Sizes
    module_function

    def human(bytes)
      return "0B" unless bytes && bytes > 0
      units = %w[B KB MB GB TB]
      i = 0
      size = bytes.to_f
      while size >= 1024 && i < units.length - 1
        size /= 1024
        i += 1
      end
      format("%.1f%s", size, units[i])
    end
  end

  module Spinner
    module_function

    def with_spinner(msg)
      # msg is a present-tense progress label; skip it under --log-file so
      # the file only ever gets each call site's past-tense completion line.
      return yield if LogFile.enabled?

      unless $stdout.tty?
        puts "#{Ctree::Log.prefix}#{msg}"
        return yield
      end

      start_time = Time.now
      state_mutex = Mutex.new
      done = false
      result = nil

      spinner_thread = Thread.new do
        spinner_idx = 0
        until state_mutex.synchronize { done }
          elapsed = (Time.now - start_time).to_i
          line = format("%s (%s) %ds",
                        Ctree::Log.prefix,
                        SPINNER_FRAMES[spinner_idx % SPINNER_FRAMES.length],
                        elapsed)
          print "\r\e[K#{line}"
          $stdout.flush
          spinner_idx += 1
          sleep 0.1
        end
      end

      begin
        result = yield
      ensure
        state_mutex.synchronize { done = true }
        spinner_thread.join
        print "\r\e[K"
        $stdout.flush
      end

      result
    end

    def render_progress(current, total, start_time, spinner)
      return if LogFile.enabled?
      return unless $stdout.tty?
      elapsed = (Time.now - start_time).to_i
      if total && total > 0
        pct = [(current.to_f / total * 100).round, 100].min
        bar_width = 24
        filled = [[bar_width * pct / 100, 1].max, bar_width].min
        bar = ("=" * filled).ljust(bar_width)
        msg = format("[%s] (%s) %3d%%  %s/%s  %ds",
                     bar, spinner, pct,
                     Sizes.human(current), Sizes.human(total), elapsed)
      else
        msg = format("%s  (%s)  %ds", Sizes.human(current), spinner, elapsed)
      end
      print "\r\e[K#{msg}"
      $stdout.flush
    end
  end

  module Prompt
    module_function

    def read_line(prompt)
      if HAS_READLINE
        Readline.readline(prompt, false)
      else
        print prompt
        $stdout.flush
        line = $stdin.gets
        line&.chomp
      end
    end

    # Centralized yes/no confirmation. `default` is :yes, :no, or nil (no
    # bracketed default — the prompt text must ask the user to type "yes").
    # Under force: true, skips stdin and returns the assumed answer silently.
    def confirm(message, default:, force: false)
      return default == :yes || default.nil? if force

      logging = LogFile.enabled?
      if logging
        Scroller.pause
        LogFile.write("PROMPT: #{message}")
      end

      raw = read_line("#{Ctree::Log.prefix}#{message}")
      result = if default.nil?
        raw.to_s.gsub(/[\x00-\x1f\x7f]/, "").strip == "yes"
      else
        answer = raw.to_s.gsub(/[\x00-\x1f\x7f]/, "").strip.downcase
        if default == :yes
          answer.empty? || answer == "y" || answer == "yes"
        else
          answer == "y" || answer == "yes"
        end
      end

      if logging
        answer_note = raw.to_s.empty? ? "(empty, default)" : raw
        LogFile.write("ANSWER: #{answer_note} -> #{result ? "yes" : "no"}")
        Scroller.resume
      end

      result
    end

    # Generic prompt for any .env variable. Prints key=value as a log line
    # then prompts on a short second line — avoids Readline redraw artifacts
    # caused by prompts longer than the terminal width.
    def for_env_var_change(key, current_value, worktree_values: {}, force: false)
      console_header = ["#{Ctree::Log.prefix}#{key}=#{current_value}"]
      if worktree_values.any?
        pad = worktree_values.keys.map(&:length).max
        worktree_values.each { |wt, val| console_header << "  #{wt.ljust(pad)}: #{val}" }
      end

      logging = LogFile.enabled?
      if logging
        return current_value if force
        sibling_note = worktree_values.any? ? " (worktree values: #{worktree_values.map { |wt, val| "#{wt}=#{val}" }.join(", ")})" : ""
        Scroller.pause
        puts console_header.join("\n")
        LogFile.write("PROMPT: #{key}=#{current_value}#{sibling_note} (enter to keep, or type a new value):")
      else
        puts console_header.join("\n")
        return current_value if force
      end

      raw = read_line("  (enter to keep, or type a new value): ")
      result = if raw.nil?
        current_value
      else
        answer = raw.gsub(/[\x00-\x1f\x7f]/, "").strip
        answer.empty? ? current_value : answer
      end

      if logging
        answer_note = raw.to_s.empty? ? "(empty, kept #{result})" : result
        LogFile.write("ANSWER: #{answer_note}")
        Scroller.resume
      end

      result
    end
  end

  module Volume
    RSYNC_IMAGE = "ctree-rsync:1"

    module_function

    def ensure_rsync_image!
      _, _, st = Sh.capture3("docker", "image", "inspect", RSYNC_IMAGE)
      return if st.success?

      _, err, build_st = Spinner.with_spinner("building ctree-rsync image") do
        Sh.capture3(
          "docker", "build", "-t", RSYNC_IMAGE, "-",
          stdin_data: "FROM alpine:3\nRUN apk add --no-cache rsync\n"
        )
      end
      Log.die "failed to build ctree-rsync image: #{err.strip}" unless build_st.success?
      Log.info "built ctree-rsync image"
    end

    def copy_with_progress(src_vol, tgt_vol)
      # The same container that runs cp -a also samples /to size every 1s
      # and emits a PROGRESS line, so we get real byte-level progress
      # without spawning extra docker invocations.
      script = <<~SH
        total=$(du -sb /from 2>/dev/null | awk '{print $1}')
        echo "TOTAL:$total"
        ( cd /from && cp -a . /to/ ) &
        cp_pid=$!
        while kill -0 "$cp_pid" 2>/dev/null; do
          sleep 1
          current=$(du -sb /to 2>/dev/null | awk '{print $1}')
          echo "PROGRESS:$current"
        done
        wait "$cp_pid"
      SH

      cmd = [
        "docker", "run", "--rm",
        "-v", "#{src_vol}:/from:ro",
        "-v", "#{tgt_vol}:/to",
        "alpine", "sh", "-c", script
      ]

      start_time = Time.now
      total_bytes = nil
      current_bytes = 0
      err_buf = +""
      exit_status = nil
      state_mutex = Mutex.new
      done = false

      live_progress = $stdout.tty? && !LogFile.enabled?
      Log.debug "copying #{src_vol} -> #{tgt_vol}" unless live_progress

      Sh.popen3(*cmd) do |_stdin, stdout, stderr, wait_thr|
        err_thread = Thread.new { err_buf << stderr.read.to_s }

        render_thread = Thread.new do
          spinner_idx = 0
          until state_mutex.synchronize { done }
            cur, tot = state_mutex.synchronize { [current_bytes, total_bytes] }
            elapsed = (Time.now - start_time).to_i
            pct = (tot && tot > 0) ? [(cur.to_f / tot * 100).round, 100].min : 0
            if live_progress
              print format("\r\e[K#{Ctree::Log.prefix}copying %s -> %s %d%% (%s) %ds",
                           src_vol, tgt_vol, pct,
                           SPINNER_FRAMES[spinner_idx % SPINNER_FRAMES.length], elapsed)
              $stdout.flush
            end
            spinner_idx += 1
            sleep 0.1
          end
        end

        stdout.each_line do |raw|
          line = raw.strip
          if line.start_with?("TOTAL:")
            state_mutex.synchronize { total_bytes = line.sub("TOTAL:", "").to_i }
          elsif line.start_with?("PROGRESS:")
            state_mutex.synchronize { current_bytes = line.sub("PROGRESS:", "").to_i }
          end
        end

        state_mutex.synchronize { done = true }
        render_thread.join
        err_thread.join
        exit_status = wait_thr.value
      end

      if live_progress
        print "\r\e[K"
        $stdout.flush
      end

      elapsed = (Time.now - start_time).to_i
      if exit_status.success?
        size_part = total_bytes && total_bytes > 0 ? "#{Sizes.human(total_bytes)} in " : ""
        Log.debug "copied #{src_vol} -> #{tgt_vol} (#{size_part}#{elapsed}s)"
      end

      [exit_status, err_buf, total_bytes]
    end

    def rsync_with_progress(src_vol, tgt_vol)
      cmd = [
        "docker", "run", "--rm",
        "-v", "#{src_vol}:/from:ro",
        "-v", "#{tgt_vol}:/to",
        RSYNC_IMAGE, "sh", "-c", "rsync -a --delete --stats /from/ /to/"
      ]

      out, err, st = Spinner.with_spinner("updating #{src_vol} -> #{tgt_vol}") do
        Sh.capture3(*cmd)
      end

      transferred_bytes = 0
      out.each_line do |line|
        if line =~ /Total transferred file size:\s+([\d,]+)\s+bytes/
          transferred_bytes = $1.tr(",", "").to_i
          break
        end
      end

      [st, err, transferred_bytes]
    end
  end

  module Images
    module_function

    # Tags every source-project image (<source_project>-<service>) to the
    # corresponding <target_project>-<service> name. Docker tags are metadata
    # pointers, so this is instant and lets the worktree's `docker compose up`
    # skip rebuilding identical images. Re-running picks up freshly built
    # source layers (e.g. after rebuilding source images). Returns the list of
    # [src_img, tgt_img] pairs that were tagged.
    def tag_to_target(source_project, target_project)
      images_out, _, _ = Sh.capture3("docker", "images",
                                     "--format", "{{.Repository}}",
                                     "--filter", "label=com.docker.compose.project=#{source_project}",
                                     "--filter", "reference=#{source_project}-*")
      tagged = []
      images_out.lines.map(&:strip).reject(&:empty?).each do |src_img|
        suffix = src_img.sub("#{source_project}-", "")
        tgt_img = "#{target_project}-#{suffix}"
        _, _, st = Sh.capture3("docker", "tag", src_img, tgt_img)
        if st.success?
          Log.debug "tagged #{src_img} -> #{tgt_img}"
          tagged << [src_img, tgt_img]
        end
      end
      tagged
    end

    # Maps service suffix -> image ID for a project. Source images are matched
    # by both the compose-project label AND the name prefix (the label excludes
    # other worktrees' tags that share the prefix). Worktree-tagged images are
    # matched by name prefix ONLY: `docker tag` copies the image — including the
    # source's com.docker.compose.project label — so the label cannot identify
    # them; the <target>-* name is the only discriminator.
    def ids_by_service(project, by_label:)
      filters = ["--filter", "reference=#{project}-*"]
      filters += ["--filter", "label=com.docker.compose.project=#{project}"] if by_label
      out, _, st = Sh.capture3("docker", "images", "--no-trunc",
                               "--format", "{{.Repository}}\t{{.ID}}", *filters)
      return {} unless st.success?
      out.lines.each_with_object({}) do |line, h|
        repo, id = line.strip.split("\t", 2)
        next if repo.nil? || id.nil?
        h[repo.sub("#{project}-", "")] = id
      end
    end

    # Returns service suffixes whose source image ID differs from (or is
    # missing on) the worktree's tagged image — i.e. a sync would update them.
    def stale_services(source_project, target_project)
      source_ids = ids_by_service(source_project, by_label: true)
      target_ids = ids_by_service(target_project, by_label: false)
      source_ids.filter_map { |svc, src_id| svc if target_ids[svc] != src_id }
    end
  end

  # Wraps the darwin clonefile(2) syscall via FFI so ctree can clone an
  # entire directory tree with a single syscall — dramatically faster than
  # `cp -c -R`, which calls clonefile per file. On non-darwin platforms
  # (or if libSystem can't be loaded), `available?` returns false and
  # callers fall back to the next strategy.
  module Clonefile
    module_function

    begin
      if RUBY_PLATFORM =~ /darwin/
        require "fiddle"
        require "fiddle/import"

        module Lib
          extend Fiddle::Importer
          dlload "libSystem.dylib"
          extern "int clonefile(const char *src, const char *dst, unsigned int flags)"
        end

        AVAILABLE = true
      else
        AVAILABLE = false
      end
    rescue LoadError, Fiddle::DLError, NameError
      AVAILABLE = false
    end

    def available?
      AVAILABLE
    end

    # Single-syscall whole-tree clone. Returns true on success, false
    # otherwise. Target must NOT exist (clonefile fails with EEXIST if it
    # does); caller is responsible for that precondition.
    # Note: clonefile follows symlinks in src regardless of flag 0x0002 on
    # some macOS versions. Callers should handle symlinks via File.symlink?
    # before calling clone() to avoid dereferencing.
    def clone(src, tgt)
      return false unless AVAILABLE
      Lib.clonefile(src.to_s, tgt.to_s, 0) == 0
    end
  end

  module ComposeOverride
    module_function

    # Pure check. Returns {ok: [...], fixable: [...], unfixable: [...]}.
    # ok        = suffixes with correct external reference already present
    # fixable   = suffixes missing from override but source volume exists in Docker
    # unfixable = suffixes missing from override and source volume not in Docker
    def audit(target_path:, override_rel:, share_volumes:, source_project:, source_volumes:)
      override_path = Pathname.new(target_path) / override_rel
      unless override_path.file?
        return { ok: [], fixable: [], unfixable: share_volumes.dup }
      end

      begin
        raw = File.read(override_path.to_s)
        stream = Psych.parse_stream(raw)
        doc_node = stream.children.first
        return { ok: [], fixable: [], unfixable: share_volumes.dup } unless doc_node
        root = doc_node.children.first
        return { ok: [], fixable: [], unfixable: share_volumes.dup } unless root.is_a?(Psych::Nodes::Mapping)

        existing = extract_existing_volumes(root, source_project)

        ok = []
        missing = []
        share_volumes.each do |suffix|
          e = existing[suffix]
          if e && e[:external] && e[:name] == "#{source_project}_#{suffix}"
            ok << suffix
          else
            missing << suffix
          end
        end

        fixable, unfixable = missing.partition { |s| source_volumes.include?("#{source_project}_#{s}") }
        { ok: ok, fixable: fixable, unfixable: unfixable }
      rescue Psych::SyntaxError => e
        Log.warn_ "could not parse #{override_rel}: #{e.message}; skipping shared volume validation"
        { ok: [], fixable: [], unfixable: share_volumes.dup }
      end
    end

    # Returns true when all share_volumes have correct external refs (no Docker call).
    def valid?(target_path:, override_rel:, share_volumes:, source_project:)
      return true if override_rel.empty? || share_volumes.empty?
      all_expected = share_volumes.map { |s| "#{source_project}_#{s}" }
      result = audit(
        target_path: target_path, override_rel: override_rel,
        share_volumes: share_volumes, source_project: source_project,
        source_volumes: all_expected
      )
      result[:fixable].empty? && result[:unfixable].empty?
    end

    # Warn-only, no prompts, no file writes. Called by ctree create.
    def check(target_path:, override_rel:, share_volumes:, source_project:, source_volumes:)
      return if override_rel.empty? || share_volumes.empty?

      result = audit(
        target_path: target_path, override_rel: override_rel,
        share_volumes: share_volumes, source_project: source_project,
        source_volumes: source_volumes
      )

      result[:unfixable].each do |suffix|
        Log.warn_ "share volume '#{suffix}' missing from #{override_rel} " \
                  "and source volume #{source_project}_#{suffix} not found in Docker"
      end

      if result[:fixable].any?
        n = result[:fixable].size
        Log.warn_ "#{n} share volume#{n == 1 ? "" : "s"} missing external reference " \
                  "in #{override_rel}: #{result[:fixable].join(", ")}"
        Log.warn_ "run `ctree compose-config fix` to fix"
      end
    end

    # Fix without prompts. Called by ctree compose-config fix.
    # Returns true if any fixes were applied, false otherwise.
    def fix(target_path:, override_rel:, share_volumes:, source_project:, source_volumes:)
      override_path = Pathname.new(target_path) / override_rel
      unless override_path.file?
        Log.warn_ "#{override_rel} not found; nothing to fix"
        return false
      end

      result = audit(
        target_path: target_path, override_rel: override_rel,
        share_volumes: share_volumes, source_project: source_project,
        source_volumes: source_volumes
      )

      result[:unfixable].each do |suffix|
        src_name = "#{source_project}_#{suffix}"
        Log.warn_ "source volume #{src_name} not found in Docker; skipping #{suffix}"
      end

      return false if result[:fixable].empty?

      begin
        raw = File.read(override_path.to_s)
        stream = Psych.parse_stream(raw)
        doc_node = stream.children.first
        return false unless doc_node
        root = doc_node.children.first
        return false unless root.is_a?(Psych::Nodes::Mapping)

        volumes_node = find_or_create_volumes_node(root)
        unless volumes_node.is_a?(Psych::Nodes::Mapping)
          Log.warn_ "#{override_rel}: 'volumes' is not a mapping; cannot fix"
          return false
        end

        result[:fixable].each do |suffix|
          src_name = "#{source_project}_#{suffix}"
          entry = Psych::Nodes::Mapping.new
          entry.children << Psych::Nodes::Scalar.new("external")
          entry.children << Psych::Nodes::Scalar.new("true", nil, nil, true, false)
          entry.children << Psych::Nodes::Scalar.new("name")
          entry.children << Psych::Nodes::Scalar.new(src_name)
          volumes_node.children << Psych::Nodes::Scalar.new(suffix)
          volumes_node.children << entry
          Log.debug "fixed #{suffix} -> #{src_name} in #{override_rel}"
        end

        File.write(override_path.to_s, stream.to_yaml)
        n = result[:fixable].size
        Log.info "fixed #{n} share volume#{n == 1 ? "" : "s"} in #{override_rel}: #{result[:fixable].join(", ")}"
        true
      rescue Psych::SyntaxError => e
        Log.warn_ "could not parse #{override_rel}: #{e.message}; fix aborted"
        false
      end
    end

    # Internal: extract volume entries from a root mapping node.
    # Returns a hash of suffix => {external:, name:}.
    def extract_existing_volumes(root, _source_project = nil)
      vol_key_idx = find_volumes_key_idx(root)
      existing = {}
      if vol_key_idx
        volumes_node = root.children[vol_key_idx + 1]
        if volumes_node.is_a?(Psych::Nodes::Mapping)
          volumes_node.children.each_slice(2) do |key_node, val_node|
            next unless key_node.is_a?(Psych::Nodes::Scalar)
            suffix = key_node.value
            next unless val_node.is_a?(Psych::Nodes::Mapping)
            ext = false
            name = nil
            val_node.children.each_slice(2) do |k, v|
              next unless k.is_a?(Psych::Nodes::Scalar) && v.is_a?(Psych::Nodes::Scalar)
              ext = true if k.value == "external" && v.value == "true"
              name = v.value if k.value == "name"
            end
            existing[suffix] = { external: ext, name: name }
          end
        end
      end
      existing
    end

    # Internal: find the index of the "volumes" key in a root mapping node.
    def find_volumes_key_idx(root)
      vol_key_idx = nil
      root.children.each_with_index do |child, i|
        if i.even? && child.is_a?(Psych::Nodes::Scalar) && child.value == "volumes"
          vol_key_idx = i
          break
        end
      end
      vol_key_idx
    end

    # Internal: find or create the volumes mapping node under root.
    def find_or_create_volumes_node(root)
      vol_key_idx = find_volumes_key_idx(root)
      if vol_key_idx
        root.children[vol_key_idx + 1]
      else
        m = Psych::Nodes::Mapping.new
        root.children << Psych::Nodes::Scalar.new("volumes")
        root.children << m
        m
      end
    end

    private_class_method :extract_existing_volumes, :find_volumes_key_idx, :find_or_create_volumes_node
  end

end

require_relative "ctree/version"
require_relative "ctree/config"
require_relative "ctree/cli"
require_relative "ctree/create"
require_relative "ctree/rebase"
require_relative "ctree/delete"
require_relative "ctree/domain"
require_relative "ctree/list"
require_relative "ctree/switch"
require_relative "ctree/update"
require_relative "ctree/free"
require_relative "ctree/env_cmd"
require_relative "ctree/compose_config_cmd"
require_relative "ctree/shell_init"
require_relative "ctree/sync"
