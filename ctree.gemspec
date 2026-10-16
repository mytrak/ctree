# frozen_string_literal: true

require_relative "lib/ctree/version"

Gem::Specification.new do |spec|
  spec.name        = "ctree"
  spec.version     = Ctree::VERSION
  spec.authors     = ["mytrak"]
  spec.email       = ["mytraks@yahoo.com"]

  spec.summary     = "Run multiple branches of a Docker-compose repo side by side"
  spec.description = "ctree lets you run multiple branches of a Docker-compose " \
                     "project at once, each in its own sibling git worktree with " \
                     "replicated Docker volumes. Manage the full lifecycle with " \
                     "create, delete, list, rebase, and update commands."
  spec.homepage    = "https://github.com/mytrak/ctree"
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.metadata["github_repo"] = "https://github.com/mytrak/ctree"
  spec.metadata["changelog_uri"] = "https://github.com/mytrak/ctree/blob/main/CHANGELOG.md"

  spec.files = Dir[
    "lib/**/*.rb",
    "lib/**/*.yml",
    "bin/*",
    "README.md",
    "LICENSE",
    "CHANGELOG.md"
  ]
  spec.bindir        = "bin"
  spec.executables   = ["ctree"]
  spec.require_paths = ["lib"]

  spec.add_development_dependency "rspec", "~> 3.12"
  spec.add_dependency "reline"
  spec.add_dependency "fiddle"
end
