# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- Added sync command and post-rebase hooks
- Added CTREE_LOG_PREFIX env var
- Added log prefix config option

## [0.3.0] - 2026-09-10

- Added support for equals syntax for --config and --log-file
- Added an option to redirect command output to a log file
- Removed interactive prompts from log in non-interactive mode
- Added an option to run commands non-interactively

## [0.2.0] - 2026-08-20

- Prevented creation of duplicate volumes for shared volumes
- Changed how .ctree is created in the worktree (it is no longer copied from the source repo)
- Added an option to use a custom config file during worktree creation

## [0.1.0] - 2026-07-11

Initial commit.
