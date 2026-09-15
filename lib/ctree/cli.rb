# frozen_string_literal: true

module Ctree
  module CLI
    module_function

    COMMANDS = [
      ["create", "<worktree_name> <branch_name>", "create a sibling worktree on a branch"],
      ["delete", "<worktree_name>", "remove a worktree and its Docker resources"],
      ["list", "[all | free | used]", "list worktrees for the current source repo"],
      ["switch", "<worktree_name>", "change directory into a worktree"],
      ["rebase", "", "rebase the worktree onto the source repo's master"],
      ["update", "", "sync images, volumes, and files from source"],
      ["free", "", "reset the worktree to a free placeholder branch"],
      ["env", "[list | check | fix]", "manage the worktree's .env against the source"],
      ["version", "", "print the installed ctree version"],
      ["domain", "[list | [add | delete] <tld>]", "configure local DNS resolution for a TLD (macOS only)"],
      ["config", "[list | add | delete]", "manage the per-repo .ctree/config.yml"],
      ["compose-config", "[list | check | fix]", "manage shared-volume references in the compose override"],
      ["sync", "", "sync the worktree by rebasing and updating"],
      ["help", "[command]", "show detailed help for a command"]
    ].freeze

    COMMAND_SIGNATURES = COMMANDS.map { |name, args, _| args.empty? ? name : "#{name} #{args}" }.freeze

    COMMAND_SIGNATURE_WIDTH = COMMAND_SIGNATURES.map(&:length).max + 2

    COMMANDS_TABLE = COMMAND_SIGNATURES.zip(COMMANDS).map { |sig, (_, _, desc)|
      "  #{sig.ljust(COMMAND_SIGNATURE_WIDTH)}#{desc}"
    }.join("\n").freeze

    USAGE = <<~USAGE
      Replicate a Docker Compose dev tree as a sibling git worktree with its own branch, volumes, and .env.

      Usage:
        ctree [command]

      Available Commands:
      #{COMMANDS_TABLE}

      Most commands run from the top of the source repository.
      `update`, `rebase`, `free`, `env`, and `compose-config` run from inside a worktree.

      Pass --force with create, delete, free, rebase, update, env fix or config
      add/delete to skip confirmation prompts and assume their default answer.

      Pass --log-file <path> with create, delete, rebase, or update to write
      command output to <path> instead of the console. It also implies --force.

      Use "ctree help <command>" for more information about a command.
    USAGE

    HELP = {
      "create" => <<~HELP,
        Usage:
          ctree create <worktree_name> <branch_name>

        Creates a sibling worktree at ../<worktree_name> on <branch_name>. The entire
        source directory is cloned using copy-on-write (clonefile on macOS, cp --reflink
        on Linux). Docker volumes are replicated under the new compose project name and
        a tailored .env is written — prompting you to accept or change each value.

        --config <path> replaces the repo's .ctree/config.yml with a custom config file
        for this worktree. The custom file is merged over the shipped defaults and
        persisted into the worktree's .ctree/config.yml so that later commands
        (update, rebase, etc.) continue to use it.

         --force skips all confirmation prompts (assuming the bracket default, or
         the shown value for per-var .env prompts) so create runs non-interactively.

         --log-file <path> writes full output to <path> instead of the console.
         Implies --force (prompts are skipped; defaults are assumed).
      HELP
      "delete" => <<~HELP,
        Usage:
          ctree delete <worktree_name>

        Removes a worktree: lists everything to be deleted, requires explicit "yes"
        confirmation, then tears down the directory, git worktree registration,
        per-project Docker volumes, and any running compose stack. Branches are
        always preserved.

         --force skips the confirmation prompt and proceeds with deletion.

         --log-file <path> writes full output to <path> instead of the console.
         Implies --force (prompts are skipped; defaults are assumed).
      HELP
      "switch" => <<~HELP,
        Usage:
          ctree switch <worktree_name>

        Changes your shell's working directory to the chosen worktree. Requires the
        ctree shell function (see: ctree help shell-init). Without it, spawns a child
        shell at the target path instead.
      HELP
      "list" => <<~HELP,
        Usage:
          ctree list [all | free | used]

        Lists all worktrees for the current source repo. "free" shows only worktrees
        on a placeholder branch (prefix configured via free_branch_prefix in
        .ctree/config.yml, default "FREE-"); "used" shows only worktrees on a
        non-free branch. Omitting the filter (or passing "all") lists everything.

         --no-current   suppresses the 'current' tag in the list output
      HELP
      "update" => <<~HELP,
        Usage:
          ctree update

        Run from inside a worktree. Re-tags source images to the worktree's project
        name, rsyncs allowlisted volumes (update_volumes), and copies paths listed
        in the update config key. Warns and prompts before running if the source repo
        is on a non-default branch.

         --force assumes the shown defaults for the prompts: the branch-mismatch
         prompt defaults to *not* proceeding — so --force with a non-default source
         branch will abort the update rather than forcing it through.

         --log-file <path> writes full output to <path> instead of the console.
         Implies --force (prompts are skipped; defaults are assumed).
      HELP
      "rebase" => <<~HELP,
        Usage:
          ctree rebase

        Run from inside a worktree. Does two things in order:
        1. Rebases the worktree's current branch onto the source repo's master.
           Skips if master is already an ancestor. Aborts if there are conflicts.
        2. Rebases each embedded git repo (directories listed under `rebase` in
           .ctree/config.yml, e.g. gems/plugins) from its source counterpart.

        All operations are local — no network calls. Update the source repo first,
        then run `ctree rebase` from the worktree to catch it up.

         --force assumes the shown default for the uncommitted-changes prompt,
         which defaults to *not* proceeding — so --force will abort a rebase run
         against a dirty worktree rather than forcing it through.

         --log-file <path> writes full output to <path> instead of the console.
         Implies --force (prompts are skipped; defaults are assumed).
      HELP
      "free" => <<~HELP,
        Usage:
          ctree free

        Run from inside a worktree. Resets the worktree to a free placeholder branch
        so it can be reused. Checks out the first available branch not currently
        checked out in any worktree whose name starts with free_branch_prefix (default
        "FREE-"). If all are occupied, creates the next sequential one, filling gaps
        (FREE-001 + FREE-003 occupied → creates FREE-002). The prefix is configurable
        via free_branch_prefix in .ctree/config.yml.

        --force skips the confirmation prompt and frees the worktree.
      HELP
      "env" => <<~HELP,
        Usage:
          ctree env [list | check | fix]

        Run from inside a worktree. Manages the worktree's .env relative to the
        source repo's .env.

        "list"  Prints all key=value pairs from the worktree .env.

        "check" Reports discrepancies between source and worktree .env:
                  [missing] KEY  — in source but absent from worktree
                  [extra]   KEY  — in worktree but absent from source
                Exits 1 if any issues found. ctree-managed keys
                (COMPOSE_PROJECT_NAME, HOST_NAME, etc.) and keys in
                skip_env_keys (.ctree/config.yml) are never reported as extra.

        "fix"   Resolves discrepancies interactively:
                  Missing keys  — prompted with source value as default
                  Extra keys    — offered for deletion (y/N)
                Keys already present in both are left untouched. ctree-managed
                keys and skip_env_keys are never offered for deletion.

                --force keeps source values for missing keys (no prompt) and
                assumes the deletion default ("no") for extra keys.
      HELP
      "compose-config" => <<~HELP,
        Usage:
          ctree compose-config [list | check | fix]

        Run from inside a worktree. Manages shared-volume external references in the
        compose override file. "list" shows current state; "check" reports missing or
        incorrect entries; "fix" writes the corrections automatically.
      HELP
      "config" => <<~HELP,
        Usage:
          ctree config [list | add | delete]

        Manages the per-repo .ctree/config.yml. "list" prints the resolved config
        (defaults merged with repo overrides); "add" scaffolds a new config file with
        annotated defaults; "delete" removes the file and its directory.

        --force skips confirmation: "add" resets an existing config file (default
        no, so it won't under --force) and "delete" proceeds with removal (default
        yes for explicit-typing prompts).
      HELP
      "domain" => <<~HELP,
        Usage:
          ctree domain [list | [add | delete] <tld>]

        macOS only. Configures local DNS resolution for a TLD. "add <tld>" adds a
        wildcard dnsmasq rule resolving *.tld to 127.0.0.1 and writes a macOS
        resolver file at /etc/resolver/<tld> (requires sudo). "delete <tld>" removes
        both. "list" shows TLDs currently configured in dnsmasq and whether their
        resolver files are present.
      HELP
      "shell-init" => <<~HELP,
        Usage:
          ctree shell-init

        Prints the ctree shell function. Eval its output in your shell profile so
        that "ctree switch" changes the directory of your current shell rather than
        spawning a child shell. Add to ~/.zshrc: eval "$(ctree shell-init)"
      HELP
      "version" => <<~HELP,
        Usage:
          ctree version

        Prints the installed ctree version.
      HELP
      "sync" => <<~HELP,
        Usage:
          ctree sync

        Run from inside a worktree. Does two things in order:
        1. Rebases the worktree's current branch onto the source repo's master.
           Skips if master is already an ancestor. Aborts if there are conflicts.
        2. Rebases each embedded git repo (directories listed under `rebase` in
           .ctree/config.yml, e.g. gems/plugins) from its source counterpart.

        All operations are local — no network calls. Update the source repo first,
        then run `ctree sync` from the worktree to catch it up.

         --force assumes the shown default for the uncommitted-changes prompt,
         which defaults to *not* proceeding — so --force will abort a rebase run
         against a dirty worktree rather than forcing it through.

         --log-file <path> writes full output to <path> instead of the console.
         Implies --force (prompts are skipped; defaults are assumed).
      HELP
    }.freeze

    def usage_and_exit
      puts USAGE
      exit 1
    end

    # Worktree names double as Docker Compose project names, which Docker
    # requires to be lowercase letters/digits/'-'/'_' and to start with a
    # letter or digit. If the user passed something close (e.g. an
    # uppercase or dotted variant), suggest the sanitized form.
    def invalid_name_message(name)
      base = "invalid name '#{name}'; must be lowercase letters, digits, '-', or '_', " \
             "starting with a letter or digit (Docker Compose project name constraint)"
      suggestion = Naming.sanitize_compose_project_name(name)
      return base if suggestion.empty? || suggestion == name || suggestion !~ NAME_PATTERN
      "#{base} — try '#{suggestion}'"
    end

    LOG_FILE_COMMANDS = %w[create delete rebase update sync].freeze

    # Wraps a create/delete/rebase/update invocation when --log-file was
    # given: redirects Log/Prompt/Spinner output to the file and shows a
    # single status line + spinner on the console, replaced on success by
    # `done_message` + elapsed time — same present/past-tense swap pattern
    # `Spinner.with_spinner` uses for individual steps. On failure, stays
    # silent (matches the no-log-file behavior, where these paths signal
    # failure only via already-streamed Log.warn_/Log.die lines and the
    # exit code). A no-op passthrough when log_file is nil.
    def with_logging(log_file, progress_message, done_message)
      return yield unless log_file

      LogFile.configure(log_file)
      Scroller.start(progress_message)
      begin
        yield
      ensure
        status = $!.is_a?(SystemExit) ? $!.status : ($! ? 1 : 0)
        Scroller.stop(status.zero? ? done_message : nil)
      end
    end

    def run(argv)
      usage_and_exit if argv.empty?

      force = argv.include?("--force")
      argv = argv.reject { |a| a == "--force" }

      log_file = nil
      argv = argv.reject do |a|
        if a.start_with?("--log-file=")
          log_file = a.sub("--log-file=", "")
          true
        elsif a == "--log-file" && argv.index(a) + 1 < argv.length && !argv[argv.index(a) + 1].start_with?("-")
          # Extract the next element as the path and remove both --log-file and the path from argv
          log_file = argv[argv.index(a) + 1]
          argv.delete_at(argv.index(a) + 1)
          true
        end
      end

      # --log-file implies non-interactive: with no console visible while logging
      # there's nowhere to show a live prompt, so it always runs like --force.
      force = true if log_file

      verb = argv[0]

      if log_file
        Log.die "--log-file requires a path, e.g. --log-file /tmp/ctree.log" if log_file.empty?
        unless LOG_FILE_COMMANDS.include?(verb)
          Log.die "--log-file is only supported for #{LOG_FILE_COMMANDS.join(", ")}"
        end
        parent = File.dirname(File.expand_path(log_file))
        unless File.directory?(parent) && File.writable?(parent)
          Log.die "--log-file parent directory does not exist or is not writable: #{parent}"
        end
      end

      case verb
      when "version"
        puts "ctree #{VERSION}"
      when "create"
        if argv.length == 3
          config_path = nil
        elsif (idx = argv.index("--config="))
          config_path = argv[idx].sub("--config=", "")
          argv.delete_at(idx) # Clean up argv
        elsif argv.length == 5 && argv[3] == "--config"
          config_path = argv[4]
        else
          usage_and_exit
        end
        name = argv[1]
        branch_arg = argv[2]
        Log.die invalid_name_message(name) unless name =~ NAME_PATTERN
        if branch_arg !~ BRANCH_NAME_PATTERN
          Log.die "invalid branch name '#{branch_arg}'; must match #{BRANCH_NAME_PATTERN.inspect}"
        end
        with_logging(log_file, "creating worktree #{name}", "created worktree #{name}") do
          Create.run(name: name, branch: branch_arg, config_path: config_path, force: force)
        end
      when "delete"
        usage_and_exit if argv.length != 2
        name = argv[1]
        Log.die invalid_name_message(name) unless name =~ NAME_PATTERN
        with_logging(log_file, "deleting worktree #{name}", "deleted worktree #{name}") do
          Delete.run(name: name, force: force)
        end
      when "switch"
        usage_and_exit if argv.length != 2
        name = argv[1]
        Log.die invalid_name_message(name) unless name =~ NAME_PATTERN
        Switch.run(name: name)
      when "update"
        usage_and_exit unless argv.length == 1
        with_logging(log_file, "updating worktree", "updated worktree") do
          Update.run(force: force)
        end
      when "free"
        usage_and_exit unless argv.length == 1
        Free.run(force: force)
      when "env"
        subcommand = argv[1]
        usage_and_exit unless %w[list check fix].include?(subcommand)
        usage_and_exit unless argv.length == 2
        EnvCmd.run(subcommand, force: force)
      when "compose-config"
        subcommand = argv[1]
        usage_and_exit unless %w[list check fix].include?(subcommand)
        usage_and_exit unless argv.length == 2
        ComposeConfigCmd.run(subcommand)
      when "rebase"
        usage_and_exit unless argv.length == 1
        with_logging(log_file, "rebasing worktree", "rebased worktree") do
          Rebase.run(force: force)
        end
      when "sync"
        usage_and_exit unless argv.length == 1
        with_logging(log_file, "syncing worktree", "synced worktree") do
          Sync.run(force: force)
        end
      when "shell-init"
        usage_and_exit unless argv.length == 1
        ShellInit.run
      when "list"
        show_current = !argv.include?("--no-current")
        argv.delete("--no-current") # Remove flag from argv to clean up parsing
        case argv[1..]
        when [], ["all"]
          List.run(show_current: show_current)
        when ["free"]
          List.run(filter: :free, show_current: show_current)
        when ["used"]
          List.run(filter: :used, show_current: show_current)
        else
          usage_and_exit
        end
      when "domain"
        subcommand = argv[1]
        case subcommand
        when "add"
          usage_and_exit unless argv.length == 3
          Domain.add(tld: argv[2])
        when "delete"
          usage_and_exit unless argv.length == 3
          Domain.remove(tld: argv[2])
        when "list"
          usage_and_exit unless argv.length == 2
          Domain.list
        else
          usage_and_exit
        end
      when "config"
        case argv[1..]
        when []
          usage_and_exit
        when ["list"]
          Config.print_resolved!
        when ["add"]
          Config.add_local!(force: force)
        when ["delete"]
          Config.remove_local!(force: force)
        else
          usage_and_exit
        end
      when "help"
        if argv.length == 1
          puts USAGE
        elsif (text = HELP[argv[1]])
          print "\n#{text}\n"
        else
          Log.die "unknown command '#{argv[1]}'; available: #{HELP.keys.sort.join(", ")}"
        end
      else
        usage_and_exit
      end
    end
  end
end
