# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

A secure, isolated container environment for running AI coding agents (GitHub Copilot, Gemini CLI, Claude Code) on openSUSE Tumbleweed using rootless Podman. Credentials are never baked into the image — authentication happens at runtime and persists via the `sandbox/` volume mount.

## Shell Scripts

All scripts (`scripts/*.sh`, `image/scripts/*.sh`) must be POSIX-compliant. Verify with:

```bash
shellcheck -x scripts/build.sh
shellcheck -x scripts/run.sh
shellcheck -x scripts/clean.sh
shellcheck -x image/scripts/entrypoint.sh
```

Each invocation must produce no output (zero errors, warnings, or infos).

## Key Commands

```bash
make build              # Build all-in-one image
make build <agent>      # Build single-agent image (agent: claude | copilot | gemini)
make run                # Create or resume all-in-one container (microVM if krun available)
make run <agent>        # Create or resume agent-specific container
make run no-microvm     # Skip microVM isolation (standard namespace mode)
make run <agent> no-microvm  # Agent-specific, without microVM
make clean              # Remove container (preserves auth tokens and workspace)
make clean-all          # Remove container and auth tokens (preserves workspace)
make help               # List all targets
```

Scripts can also be called directly: `sh scripts/build.sh [agent]`, `sh scripts/run.sh [agent]`, `sh scripts/clean.sh [--all] [agent]`.

## Architecture

### Directory Layout

```
Makefile                   # Entry point; supports make build|run|clean [agent]
scripts/
  build.sh                 # Copies image/ to build/, injects version, runs podman build
  run.sh                   # Creates/resumes container; runs microVM checks; loads security conf
  clean.sh                 # Stops/removes container; --all also wipes auth tokens
  containers.conf          # Podman security defaults for standard (namespace) mode
  containers-krun.conf     # Podman security defaults for microVM mode (no netns/userns)
image/
  Containerfile            # Selective installs via AGENT build-arg
  scripts/entrypoint.sh   # Provisions home dir and checks auth on startup
  agents/copilot/          # Copilot sub-agent definitions shipped in image
  skel/.gitconfig          # Provisioned to ~/.gitconfig on first run (cp -n)
sandbox/                   # Mounted as /home/aiuser at runtime (gitignored, persistent)
```

### Selective Image Builds

The Containerfile uses an `AGENT` build-arg (default: `"copilot gemini claude"`) with space-padded case matching to conditionally install tools:

- `copilot` → installs GitHub CLI only (~588 MB)
- `gemini` → installs Google Cloud SDK + gemini-cli (~1.76 GB)
- `claude` → installs Google Cloud SDK + claude-code (~1.92 GB)
- all three → all-in-one (~2.12 GB)

### Container Lifecycle

Stopped containers are **resumed** (not recreated) via `podman start -ai`, preserving auth state and shell history. `make clean` removes the container but leaves `sandbox/` intact — the next `make run` creates a fresh container that remounts the same home directory.

### Home Provisioning (entrypoint.sh)

On each container start, `entrypoint.sh` provisions the home directory:
- Creates `~/workspace/` and agent directories (`~/.copilot/agents/`, etc.)
- Copies skel files using `cp -n` (no-clobber) to preserve user customizations
- Copies agent definitions from `/etc/skel-agents/` to `~/.{agent}/agents/`
- Checks and displays auth status for enabled agents

### Security Model

- `--cap-drop=ALL`, `--security-opt=no-new-privileges`, rootless Podman (UID mapped to host user, never real root)
- `--network=slirp4netns`: user-space network stack, isolated from LAN/VPN
- `sandbox/` is the only mounted volume; real `$HOME`, SSH keys, and sockets are never exposed
- `/tmp` as `--tmpfs` with `noexec,nosuid` (1 GB RAM-backed)
- `pids_limit=100` prevents fork bombs

### Agent Definitions

Copilot agents in `image/agents/copilot/` are Markdown profiles provisioned to `~/.copilot/agents/` at startup:
- `go-cve-analyzer.agent.md` — read-only CVE impact analysis, outputs `cve-report-{CVE_ID}.md`
- `go-cve-fixer.agent.md` — applies fixes based on the analyzer's report

Claude and Gemini agent directories exist but are currently empty.
