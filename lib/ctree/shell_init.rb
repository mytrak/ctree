# frozen_string_literal: true

module Ctree
  module ShellInit
    module_function

    # Emits a shell function that wraps the ctree binary so `switch`
    # can change the *caller's* working directory — something a child
    # process cannot do to its parent shell. The user adds a single line,
    # `eval "$(ctree shell-init)"`, to their shell rc instead of pasting the
    # whole function by hand.
    #
    # Meant to be consumed by a shell, not read by a human. When stdout is a
    # captured pipe (command substitution, as in the eval above) we emit the
    # function; when stdout is an interactive terminal a person ran it by hand,
    # so we print the install hint instead of dumping raw shell code.
    def run
      if $stdout.tty?
        warn "#{PROG} shell-init is meant to be evaluated by your shell, not run directly."
        warn "Add this line to your ~/.zshrc or ~/.bashrc:"
        warn %(  eval "$(#{PROG} shell-init)")
        exit 1
      end
      puts shell_function(PROG, binary_path)
    end

    def binary_path
      File.expand_path("../../bin/ctree", __dir__)
    end

    def shell_function(name, bin)
      <<~SH
        #{name}() {
          if [ "$1" = "switch" ] && [ -n "$2" ]; then
            local target
            target=$("#{bin}" list | awk -v n="$2" '$1 == n { print $2; exit }')
            if [ -z "$target" ]; then
              echo "#{name}: worktree '$2' not found" >&2
              return 1
            fi
            cd "$target"
          else
            "#{bin}" "$@"
          fi
        }
      SH
    end

    private_class_method :binary_path, :shell_function
  end
end
