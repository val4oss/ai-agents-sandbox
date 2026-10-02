# Glaipnir Usage Guide

This guide covers the basic use cases and practical workflows for running AI
coding agents in an isolated sandbox with **Glaipnir**.

---

## Table of Contents

- [1. Create a simple environment with one agent](#1-create-a-simple-environment-with-one-agent)
- [2. Config the environment](#2-config-the-environment)
- [3. Use a multi-agents environment](#3-use-a-multi-agents-environment)
- [4. Dedicated environment with custom tools](#4-dedicated-environment-with-custom-tools)
- [5. Mount an additional directory into the environment](#5-mount-an-additional-directory-into-the-environment)
- [6. Inspect what has been built and is running](#6-inspect-what-has-been-built-and-is-running)
- [7. Clean up containers, images, and cache](#7-clean-up-containers-images-and-cache)
- [Additional Operations](#additional-operations)
  - [Reusing and Resetting Host Agent Authentication](#reusing-and-resetting-host-agent-authentication)
  - [Backup and Restore Agent Data](#backup-and-restore-agent-data)

---

## 1. Create a simple environment with one agent

You do not need to build anything before running your first agent. Glaipnir
automatically pulls the official slim prebuilt image from the openSUSE
container registry on first use.

### Choose where to run the agent

You can launch the sandbox from any directory. By default, Glaipnir uses your
current working directory as the workspace (mounted inside the sandbox at
`/home/aiuser/<same/path>`).

### Launch the agent with `--workspace`

You do not need to `cd` into your project directory before launching Glaipnir.
Use the `--workspace` (or `-w`) option to specify the project root directly:

```bash
glaipnir run claude --workspace ~/src/my-project
```

Or using the short option:

```bash
glaipnir run claude -w ~/src/my-project
```

Inside the sandbox, `/home/aiuser/src/my-project` directly points to your host
project directory, allowing the agent to inspect and edit files seamlessly.

---

## 2. Config the environment

Instead of passing command-line arguments repeatedly, the best practice is to
define your preferences in a configuration file.

### Configuration can be per project

Glaipnir supports per-project configuration as well as global user defaults:

* **Per-project config:** Place a `.glaipnir.conf` file in the root of your
  project workspace. When you run `glaipnir run -w <dir>`, Glaipnir
  automatically looks for `<dir>/.glaipnir.conf`.
* **Global config:** If no local project file exists, Glaipnir reads the global
  file at `${XDG_CONFIG_HOME:-~/.config}/glaipnir/glaipnir.conf` (or default
  `glaipnir.conf`).
* **Custom config path:** You can explicitly provide any configuration file
  using `--conf <path>`:
  ```bash
  glaipnir run claude --conf /path/to/custom.conf
  ```

### Example `.glaipnir.conf`

```conf
# Preferred agents (e.g. claude, gemini, copilot, opencode, antigravity, hermes)
AGENTs=claude

# Target workspace directory
WORKSPACE=/home/user/workspace/my-app

# Enable microVM isolation (1: microVM via libkrun, 0: standard container)
USE_MICROVM=1

# Custom package repositories to add during build (optional)
REPOS=(
    https://download.opensuse.org/repositories/home:/vlefebvre:/agent-skills/openSUSE_Tumbleweed/home:vlefebvre:agent-skills.repo
)

# Additional development packages to install during build
PACKAGES=(
    git
    ripgrep
    jq
    sindrai
)

# Additional host directories to bind mount read-only
RO_MOUNTS=(
    /opt/shared-libraries
    ${HOME}/reference-docs:/home/aiuser/reference-docs:ro
)

# Custom DNS servers when microVM is enabled
DNS="1.1.1.1 8.8.8.8"
```

---

## 3. Use a multi-agents environment

When your workflow requires more than one agent (for example, pairing Claude
with Gemini), follow the **configs -> build -> run** workflow.

### Step 1: Config

Declare the desired agents in your `.glaipnir.conf`:

```conf
AGENTs=(
    gemini
    claude
)
```

*(Alternatively, you can pass multiple agent names directly as command-line
arguments).*

### Step 2: Build

Build the composite image combining all selected agents:

```bash
glaipnir build gemini claude
```

Glaipnir normalizes and sorts the agent names, automatically building a
composite image tagged `ai-agents-sandbox-claude-gemini:latest`.

### Step 3: Run

Start the container with the combined agents:

```bash
glaipnir run gemini claude -w ~/src/my-project
```

Both agents are provisioned and authenticated inside the same sandbox.

---

## 4. Dedicated environment with custom tools

If your project requires specific compilers, system headers, or utilities
(such as C/C++ dev patterns, `quilt`, or `osc`), use the
**Config PKGS/REPOS -> build -> run** workflow.

### Step 1: Config PKGS / REPOS

In your project's `.glaipnir.conf`, specify the required packages:

```conf
AGENT=claude
WORKSPACE=/home/user/src/kernel-patching

PACKAGES=(
    patterns-devel-C-C++-devel_C_C++
    osc
    quilt
    cmake
    ninja
)
```

If you need custom package repositories or custom system setup steps during
image creation, configure a **build hook**:

```bash
# Executed as root during image build (one-time setup)
glaipnir build claude --build-hook ./scripts/setup-custom-repo.sh
```

### Step 2: Build

Trigger the image build to layer your packages onto the base container:

```bash
glaipnir build claude
```

Pass `--full` if you prefer building the entire base image from the root
`Containerfile` rather than layering on the prebuilt registry image:

```bash
glaipnir build claude --full
```

### Step 3: Run

Run your dedicated environment:

```bash
glaipnir run claude -w ~/src/kernel-patching
```

All configured tools, packages, and compilers are now available inside the
sandbox.

---

## 5. Mount an additional directory into the environment

When the agent needs access to external assets, documentation, or libraries
located outside the workspace, use `--ro-mount`.

### Use `--ro-mount` in run

Mount an extra directory from your host into the sandbox:

```bash
glaipnir run claude --ro-mount /path/to/host/dir
```

* **Default destination:** If no destination is specified, Glaipnir mounts the
  directory at `/home/aiuser/<basename of host dir>`:
  ```bash
  glaipnir run claude --ro-mount /opt/shared-libs
  # Accessible inside container at: /home/aiuser/shared-libs
  ```
* **Explicit destination:** Specify a custom destination path inside the
  sandbox:
  ```bash
  glaipnir run claude --ro-mount /opt/shared-libs:/home/aiuser/libs:ro
  ```
* **Multiple mounts:** You can repeat `--ro-mount` multiple times on the
  command line:
  ```bash
  glaipnir run claude \
    --ro-mount /opt/shared-libs \
    --ro-mount ~/docs/api-specs:/home/aiuser/api-specs:ro \
    -w ~/src/my-project
  ```

> **Security Guarantee:** Mounts specified with `--ro-mount` are strictly
> read-only. No action taken by the AI agent can modify or delete files in host
> paths mounted this way.

---

## 6. Inspect what has been built and is running

To inspect existing sandboxes, built images, and active containers:

```bash
glaipnir status
```

This command reports:
* Built sandbox images and their tags (e.g. `ai-agents-sandbox-claude:latest`)
* Created containers and their states (`running`, `exited`)
* Associated mount paths and cache information

---

## 7. Clean up containers, images, and cache

Glaipnir provides fine-grained commands to clean up containers, images, and
caches without accidentally losing your workspace or host credentials.

### Remove a specific container

Removes the container for the specified agent. Your workspace files and
authentication tokens are preserved:

```bash
glaipnir clean claude
```

### Remove built images for an agent

Removes the local image built for a given agent:

```bash
glaipnir clean --image claude
```

### Remove all containers and images

Removes all sandbox containers and locally built images:

```bash
glaipnir clean --all
# or
glaipnir clean -a
```

### Clean runtime cache and saved data

* Remove the entire credential cache directory:
  ```bash
  glaipnir clean-cache
  ```
* Remove saved backup archives:
  ```bash
  glaipnir clean-data
  ```

---

## Additional Operations

### Reusing and Resetting Host Agent Authentication

On first run, Glaipnir securely copies agent credentials (e.g. `~/.config/gh`,
`~/.claude`, `~/.gemini`) into an isolated cache mount so that existing logins
work inside the sandbox without prompting.

* **Re-sync host credentials:** To refresh the sandbox cache from your current
  host credentials (for instance, after switching accounts or re-authenticating
  on the host):
  ```bash
  glaipnir run claude --reset-agent-config
  ```
* *Note:* Cloud master credentials like `~/.config/gcloud` are intentionally
  never copied to preserve host security.

### Backup and Restore Agent Data

To safely preserve or migrate your agent configurations and session histories:

```bash
# Archive agent configuration cache to ~/.local/share/glaipnir/
glaipnir save-data

# Restore the most recent backup into the cache
glaipnir restore-data

# Overwrite existing cache on restore
glaipnir restore-data --force

# Use a custom archive path
glaipnir save-data --data-dir /path/to/backup
glaipnir restore-data --data-dir /path/to/backup --force
```
