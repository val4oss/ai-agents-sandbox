# CHANGELOG

> All notable changes to this project will be documented in this file.

## [1.0.0-rc1] - 2026-07-06

* Added
  * macOS VPN enforcement daemon and route discovery library
  * macOS sandbox integration via `scripts/macos-sandbox.sh`
  * `--no-microvm` argument to skip microVM and run as a standard container
  * `hermes-agent` support (Nous Research, flagged as untrusted)
  * `antigravity-cli` (`agy`) agent support
  * `opencode` Vertex AI runtime configuration
  * `antigravity-cli` agent to the supported list
  * Trusted vs untrusted agent distinction with disclaimer gate
  * Dedicated per-agent authentication directory
  * Build and run hook customisation (`--build-hook`, `--run-hook`)
  * Config file support (`ai-agents-sandbox.conf`) for image customisation
  * Multiple simultaneous microVM sessions support
  * Workspace argument (`-w`) to bind a custom host directory
  * Extra core utilities for AI agent sandbox image
  * `gemini`: helper alias to prefer `~/.gemini/.env` over shell environment
  * Packager agents and skills for Claude Code config
* Changed
  * Refactored `build`: disabled layer cache, removed intermediate artifacts
  * Refactored architecture: consolidated Containerfile scripts
  * Refactored arguments grouping
  * Increased RAM and CPU allocated to krun VM
  * Banner redesign
  * CI: stopped main CI workflow; added workflows for `develop` branch
  * CI: upgraded `actions/checkout` from v4 to v6
  * CI: added `pull_request_target` and write permissions to PR validation
* Fixed
  * Authentication reporting: more accurately reflects Google Vertex AI ADC
  * Host UID/GID mapping to `userai` inside container
  * `krun_vm.json` no longer baked into the image

## [0.9.0] - 2026-05-18

* Added
  * Build a container image per agent or an all-in-one
  * Create a secure and isolated environment for running agents
  * Clean containers running
  * Get the status and version
* Changed
  * None
* Fixed
  * None
