# CHANGELOG

> All notable changes to this project will be documented in this file.

## [1.0.0] - 2026-08-DD

* Added
  * **Path-Preserving Mounts**: The sandbox now mirrors the host's directory
    structure inside `/home/aiuser/` when the workspace is within the user's
    home. This prevents session conflicts for agents like Claude and Gemini.
  * Forward COLOR env var and remove metal aspect of the title banner
  * docs: Installation from RPM package.
  * repos configuration for adding custom packages into the building image.
* Changed
  * If worskpace even for the default points to HOME, the default become a
    directory into the cache.
  * Rewrite the Makefile with GNU convention
* Fixed
  * run: Add executable /run/agent-tmp tmpfs, opencode failed to start on the
    noexec /tmp tmpfs (openTUI render library).
  * Moves tools checking after checking arguments, to be able to run the helper
    and version action anytime

## [1.0.0-rc2] - 2026-08-14

* Added
  * Prebuilt images: `run` pulls the registry image when no local one exists
  * `build --full` to build entirely from source instead of the registry base
  * `Containerfile.agent` to produce slim per-agent images
  * `clean --image` to remove the generated images
  * Configurable microVM DNS servers (argument or config file)
  * `-vv` to enable podman debug output; build output hidden when quiet
  * `Makefile` (`build`, `install`, `uninstall`, `clean`, `check`) for a
    system-wide install; the installed binary defaults the workspace to `PWD`
  * `run`: offers to add the user to the `kvm` group when it is missing, and
    applies it to the running session without a re-login
  * Troubleshooting note about the user namespace mapping and the traversal
    of the container storage path
  * `claude`: `go-cve-investigator` sub-agent
  * `claude`: `golang-modules` and `shell-scripting` skills
* Changed
  * Renamed the tool to `glaipnir` (`ai-agents-sandbox.sh` → `glaipnir.sh`,
    config in `${XDG_CONFIG_HOME}/glaipnir/glaipnir.conf`); images and
    containers keep the `ai-agents-sandbox` name
  * Run hooks are mounted at run time instead of being baked into the image;
    dropped `image/hooks/run/` and the related build args
  * Agent files (auth, config, skills) are seeded from `image/agents/<agent>`
    into the `agents-mount` cache with `cp -n`, preserving user edits;
    the entrypoint no longer provisions them
  * Network backend switched from `slirp4netns` to `pasta` (`passt`)
  * `clean` and `status` reworked around `_podman_list_img()` /
    `_podman_list_ctn()`
  * Argument and file checks moved into their own action functions
  * `claude` skills no longer pin a model
  * Improved the `backport-patch-packager` agent and skill descriptions
* Fixed
  * `entrypoint`: capabilities leak through `setpriv`
  * `entrypoint`: `setpriv` no longer clears supplementary groups with init
  * `run`: missing `noexec` on tmpfs mounts
  * `run`: user namespace mapping uses `keep-id` only
  * VPN enforcer now covers all common interfaces
  * Updated the Google CLI GPG key in the `Containerfile`
  * `build`: quoting for multiple agents, misplaced braces in the build dir,
    and full build for all agents
  * `backport-patch-packager`: duplicated `cd` during the process
  * Nicer log colors management 

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
