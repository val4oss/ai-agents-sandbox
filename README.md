# GLAIPNIR Project (AI Agents Sandbox)

<div align="center">
  <img src="docs/banner.png" alt="Glaipnir project banner">
</div>

> The silken ribbon that binds the wolf - now it binds the AI agents.

A secure, isolated environment for running AI coding agents on
**openSUSE Tumbleweed** using rootless container with **Podman** and microvm 
with **libkrun**.

* supported agents:
  * **trusted** (comply with internal best practices):
    * `copilot` - GitHub Copilot CLI
    * `gemini` - Google Gemini CLI
    * `claude` - Anthropic Claude Code
    * `opencode` - Google OpenCode
    * `antigravity` - Google Antigravity-cli: `agy`
  * **untrusted** (does not comply with SUSE internal best practices):
    * `hermes-agent` - Nous Research Hermes Agent

> Credentials are **never baked into the image**.
> Authentication is performed at runtime and persisted via a mounted
> volume on the host.

> **Naming** — `glaipnir` is the tool you run. The images and containers it
> builds and manages keep the name `ai-agents-sandbox`, so that is what you
> will see in `podman images` and `podman ps`.

---

## Table of Contents

- [Requirements](#requirements)
- [Usage](#usage)
- [Runtime Example](#runtime-example)
- [Customisation](#customisation)
- [Additional docs](#additional-docs)

---

## Requirements

### Dependency installation

```bash
sudo zypper install podman passt crun libkrun1 libkrunfw5
```

* Minimum required versions: `crun ≥ 1.22`, `libkrun ≥ 1.18`, `libkrunfw ≥ 5`.

> ⚠️ `libkrun ≥ 1.18` is required as it fixes some issues related to agent TUI.
> If you have an older version, `run` detects it and falls back to standard
> container mode with a warning.
> If you want microVM isolation, you can install the latest libkrun from the
> the devel **Virtualization:containers** repository which ships tested,
> compatible builds.
> ```bash
> sudo zypper addrepo \
>   https://download.opensuse.org/repositories/Virtualization:/containers/16.0/ \
>   Virtualization_containers
> sudo zypper addrepo \
>   https://download.opensuse.org/repositories/Virtualization/16.0/ \
>   Virtualization
> sudo zypper --gpg-auto-import-keys refresh Virtualization_containers \
>   Virtualization
> sudo zypper install --from Virtualization_containers crun
> sudo zypper install --from Virtualization libkrun1 libkrunfw5
> ```

> `run` will detect krun automatically and enable microVM mode. If krun is
> not installed or KVM is unavailable, the script prints what is missing and how
> to fix it. To skip microVM attempt, `run` with `no-microvm`.

> If your host is itself a VM, nested virtualisation must be enabled on the
> hypervisor (AMD: `kvm_amd.nested=1`, Intel: `kvm_intel.nested=1`).

### KVM permissions

```bash
sudo usermod -aG kvm $USER
```

> `run` checks the group and offers to add you (`[Y/n]`) when it is missing,
> then restarts itself with the group applied, so no re-login is needed.
> Declining falls back to the standard container mode.

> If the group cannot be applied to the running session, log out and log back
> in to apply it.

---

## Usage

### Install

#### From openSUSE distribution

* Add home repository

```bash
# For Leap 15.5/15.6/16.0
zypper ar https://download.opensuse.org/repositories/home:/vlefebvre/16.0/home:vlefebvre.repo
# For TW
zypper ar https://download.opensuse.org/repositories/home:/vlefebvre/openSUSE_Tumbleweed/home:vlefebvre.repo
```

* Add key

```bash
sudo rpm --import https://download.opensuse.org/repositories/home:/vlefebvre/16.0/repodata/repomd.xml.key
```

* Refresh and install

```bash
sudo zypper refresh
sudo zypper install glaipnir
```

#### Build from sources

```bash
# Clone this repository
git clone https://github.com/val4oss/ai-agents-sandbox.git
cd ai-agents-sandbox
```

Use the script `build.sh` to install the tool system-wide so it can be run from
any directory as `glaipnir` instead of `sh glaipnir.sh`.

```bash
# System install (needs sudo) — installs to /usr/local/bin and /usr/local/share
./build.sh
./build.sh install

# User-local install (no sudo) — ~/.local/bin must be on PATH
PREFIX="${HOME}/.local" ./build.sh install

# System install under /usr
PREFIX="/usr" ./build.sh install

# Packager / DESTDIR staging
PREFIX="/usr" DESTDIR="/tmp/pkg-root" ./build.sh install

# Controle the version
VERSION="1.2.3" ./build.sh install

# Uninstall set same PREFIX and DESTDIR as install
./build.sh uninstall
```

> After a system install, use `glaipnir` in place of
> `sh glaipnir.sh` in all commands below.
> The installed version uses the current working directory as the default
> workspace (equivalent to always passing `-w .`), and looks for the config
> file at `${XDG_CONFIG_HOME:-~/.config}/glaipnir/glaipnir.conf`.

> /!\ If you installed a pre-rename version, remove it first,
> `./build.sh uninstall> will not:
> `sudo rm -f /usr/local/bin/ai-agents-sandbox` and
> `sudo rm -rf /usr/local/share/ai-agents-sandbox`
> Same about the configuration file, you may want to mode:
> `~/.config/ai-agents-sandbox/ai-agents-sandbox.conf` to
> `~/.config/glaipnir/glaipnir.conf`

---

### Build the image

> Building is **optional**. `run` pulls a prebuilt image from the registry
> automatically (see [Run](#run-the-isolated-environment)). Build only when you
> need to customise the image — extra packages, build hooks — or work offline.

```bash
sh glaipnir.sh build           # Build the all-in-one image  (ai-agents-sandbox:latest)
sh glaipnir.sh build <agent>   # Build an agent image        (ai-agents-sandbox-<agent>:latest)
sh glaipnir.sh build <agent> --full  # Build fully from source, not from the registry base
```

By default `build` layers your customisations on top of the prebuilt image
pulled from the registry
(`registry.opensuse.org/home/vlefebvre/container-images/containers/opensuse/`),
which is fast and keeps images slim. Pass `--full` to build the whole image
from the `Containerfile` instead.

The script injects the version number, passes the `AGENT` build-arg to
`podman build`, and builds the image as `ai-agents-sandbox[-<agent>]:latest`.
Agent-specific builds only install the tools required by the selected agent,
resulting in smaller images.

```bash
# Verify the build
podman image inspect ai-agents-sandbox:latest | grep -E "User|Size"
```

### Run the isolated environment

> If no locally built image is present, `run` automatically pulls the prebuilt
> image from the registry, so you can start straight away without building.

```bash
# Start (or resume) the container (microVM if available)
sh glaipnir.sh run <?agent>
# Start without microVM isolation
sh glaipnir.sh run <?agent> no-microvm
# Define a custom workdir to mount as /home/aiuser/workspace.
sh glaipnir.sh run <?agent> -w <dir_path>
# Remove the cached agents configuration and copy your host HOME one again
sh glaipnir.sh run <?agent> --reset-agent-config
```

> `<?agent>` can be empty to use the all-in-one image.

#### Reuse of the agents configuration of your host

At first use of the sandbox, agents configuration are copied into the 
`agents-mount` mount point directory so a user already authenticated outside of
the sandbox stays authenticated inside it, and keeps the history.

Exeption for `~/.config/gcloud` that is never copied. Unlike an agent token, the
gcloud ADC are a cloud identity, and their reach goes far beyond coding.

Two rules keep the sandbox secure:

* **glaipnir only reads your host.** No action of the agent inside the sandbox
  can reach your host.
* **The copy only adds files, the sandbox always wins.** The host never
  overwrites a file that the cache already holds.

To start again from the current state of your host, use
`--reset-agent-config`. It is useful after you authenticate again on the host,
or after you change account on it. The option removes only `agents-mount`, and
glaipnir refuses it while the container still runs.

> The first copy takes all the listed directories. If your `~/.claude/projects`
> is large, the first `run` takes more time and the cache grows.

### Clean the environment

```bash
sh glaipnir.sh clean     # Remove the container (auth and workspace preserved)
sh glaipnir.sh clean all # Remove a specific agent container + its auth tokens
```

### Use a config file to customized your image

The project will look at ${ROOT_D}/glaipnir.conf for a config file.
You can use it to customize the image build, for example to add extra
packages or change the base image.

```conf
USE_MICROVM=0
AGENT=claude
WORKSPACE=/home/valentin/workspace
#IMG_TAG=1.0.0
PACKAGES=(
    osc
    quilt
)
```

---

## Runtime Example

Complete walkthrough: authenticate GitHub Copilot, clone a repository,
and use Copilot on the code.

### Step 1 - Build the image

```bash
sh glaipnir.sh build copilot
[INFO] Building container image ai-agents-sandbox:0.9.0 ...
...
Successfully tagged localhost/ai-agents-sandbox:latest
Successfully tagged localhost/ai-agents-sandbox:0.9.0
ed31835286b3b911ad1bd8ccd6f0f104aee6044e7e5d283111344fee27ac2812
[INFO] Image built successfully.
[INFO] [✓] Done.
```

### Step 2 — Start the container

```bash
sh glaipnir.sh run -w ~/workspace/

[INFO] Running sandbox with microVM isolation for agent 'copilot claude gemini opencode'...
[INFO] Binding outbound network to interface: wlan0
[INFO] Starting isolated container...
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│░█▀█░▀█▀░░░█▀█░█▀▀░█▀▀░█▀█░▀█▀░█▀▀░░░█▀▀░█▀█░█▀█░█▀▄░█▀▄░█▀█░█░█░░░░░░░░░▄▀▄░░░░▄▀▄░░░░▄▀▄│
│░█▀█░░█░░░░█▀█░█░█░█▀▀░█░█░░█░░▀▀█░░░▀▀█░█▀█░█░█░█░█░█▀▄░█░█░▄▀▄░░░▄▄▄░░░█/█░░░░░▀█░░░░█/█│
│░▀░▀░▀▀▀░░░▀░▀░▀▀▀░▀▀▀░▀░▀░░▀░░▀▀▀░░░▀▀▀░▀░▀░▀░▀░▀▀░░▀▀░░▀▀▀░▀░▀░░░░░░░░░░▀░░▀░░▀▀░░▀░░░▀░│
└──────────────────────────────────────────────────────────────────────────────────────────┘
 ⡷⢾ ⡇ ⡎⠑ ⣏⡱ ⡎⢱ ⡇⢸ ⡷⢾   ⡇ ⢎⡑ ⡎⢱ ⡇  ⣎⣱ ⢹⠁ ⡇ ⡎⢱ ⡷⣸
 ⠇⠸ ⠇ ⠣⠔ ⠇⠱ ⠣⠜ ⠸⠃ ⠇⠸   ⠇ ⠢⠜ ⠣⠜ ⠧⠤ ⠇⠸ ⠸  ⠇ ⠣⠜ ⠇⠹
        • Agent: GitHub Copilot CLI
                 ⚠️ not authenticated — run : gh auth login --scopes 'copilot'
        • Agent: Gemini CLI
                 ⚠️ not authenticated — run : gemini auth login
          Notes:
                 If you used a company plan linked to a google project, you would
                 need to edit the file: ~/.gemini/.env and set:
                 GOOGLE_CLOUD_PROJECT=company-gemini-code-assist
        • Agent: Claude Code
                 ✅ authenticated
          Notes:
                 To install though Vertex Ai, connect to Google Cloud with:
                 gcloud auth application-default login
        • Agent: Open Code
                 ⚠️ not authenticated — run : gcloud auth application-default login
          Notes:
                 Required environment variables:
                 GOOGLE_CLOUD_PROJECT=<project ID>
                 VERTEX_LOCATION=<vertex location>
                 Keep GOOGLE_APPLICATION_CREDENTIALS unset for ADC default path.
                 Set GOOGLE_CLOUD_PROJECT to enable Vertex AI provider.
```

> When running an agent-specific container, only that agent's line appears in
> the banner and only its auth check is shown.

### Step 3 — Use agent in the sandbox

* Run the agent TUI
  * `claude`
  * `gh auth login` & `copilot`
  * `gemini`

### Step 4 — Clone a repository

```bash
# Inside the container — workspace is ready at ~/workspace
cd ~/workspace
git clone <repo>

cd <repo>

# Ask Copilot to suggest a command
copilot -i "write a bash function to check if a podman container is running"
```

### Step 5 — Exit and verify persistence

```bash
# Exit the container
exit

# On the host — token is preserved
ls workspace/.config/gh/
# → hosts.yml  ← your token, stored on YOUR host filesystem

# Restart — authentication is immediately restored
sh glaipnir.sh run copilot
# → ✅ GitHub (gh) : authenticated
```

---

## Customisation

### Configuration file

Where configuration file can be used to export arguments into a file, it allows
you to add more packages to include in your image to build.

* Example of a config file used to create environment for C-C++ development

```conf
USE_MICROVM=1
AGENT=claude
WORKSPACE=/home/user/workspace
PACKAGES=(
    patterns-devel-C-C++-devel_C_C++
)
DNS=x.x.x.x
```

The project is looking for the config file in `${ROOT_D}/glaipnir.conf`
or the patch specified with `--conf` argument.

### hooks

Hooks are scripts that can be used to customize the image build or the container
runtime. There are twho types of hooks: **build hooks** and **run hooks**.

#### build hooks

* Script given through `--build-hook` argument
* Run as root during the image build (one-time)
* Usefull to configure the image or add custom config for agents in the image

#### run hooks

* Script given through `--run-hook` argument
  * passed during the `run` command; mounted into the container at runtime
    (not baked into the image).
* Run as userai during the container runtime (every time)
* Usefull for customizing the container runtime.

---

## Troubleshooting

### OCI permissions denied

```bash
[INFO] Starting isolated container...
Error: krun: open `/home/user/.local/share/containers/storage/overlay/0e8145fb1488986827f9e57dda305062fe06f2b1c8f25d441c0b0a5a693ba1be/merged`: Permission denied: OCI permission denied
```

OR

```bash
DEBU[0000] Unmounted container "c83638e08d75442a5c383ed3790d0fed6c0778c7faaf953e5560ab570f3983b3"
DEBU[0000] ExitCode msg: "container create failed (no logs from conmon): conmon bytes \"\": readobjectstart: expect { or n, but found \x00, error found in #0 byte of ...||..., bigger context ...||..."
Error: container create failed (no logs from conmon): conmon bytes "": readObjectStart: expect { or n, but found , error found in #0 byte of ...||..., bigger context ...||...
```

#### Why ?

The sandbox runs with `--userns keep-id`, so that the files you create in the
workspace still belong to you on the host. The counterpart is that **container
root is mapped to one of your subordinate IDs** (`/etc/subuid`, usually
`100000`), and this is the ID opening the container storage.

It has to cross every directory from `/` down to
`~/.local/share/containers/storage`, and down to the mounted volumes. A
directory blocks it as soon as **both** conditions are met:

1. it is not traversable by "other" (no `o+x`, so `0700` but not `0755`),
   **and**
2. its group is **not your primary group**.

Either condition alone is harmless, which is what makes it look random:
`/home` in `0555` is crossed thanks to its `o+x` bit whatever its group, and
a `0700` home is crossed as long as its group is your own. The kernel only
lets a subordinate ID cross a directory it has no right on when the owner and
the group of that directory are mapped in the user namespace, and only your
own UID/GID are mapped — a supplementary group never is, even after a
`usermod -aG`.

Typical case: `${HOME}` in `0700` group-owned by `users`, on accounts
inherited from the legacy openSUSE/SLE scheme where homes belong to
`<user>:users` while the account primary group is its own private group.

#### Diagnose

```bash
id
stat -c '%n %U:%G %a' / /home "$HOME" "$HOME/.local" "$HOME/.local/share" \
    "$HOME/.local/share/containers"
```

The culprit is any line whose mode does not end with an odd digit (no `x` for
"other") **and** whose group differs from the primary group reported by `id`.
A broken home of the user `devel`, whose primary group is `devel`:

```bash
/home/devel devel:users 700
```

#### Solution

Give the directory back to your primary group. You own it, so no privilege is
required, and the mode stays `0700`:

```bash
chgrp "$(id -gn)" ~
```

If that group ownership is required (shared home directory, corporate
policy...), grant the traversal instead. `0711` lets any local user cross the
directory — without listing it — to reach the paths they already know:

```bash
chmod o+x ~
```

The same applies to the workspace given with `-w` and to the cache directory
when they live outside of `${HOME}`. As a last resort, the container storage
can be moved out of `${HOME}` with `rootless_storage_path` in
`~/.config/containers/storage.conf`, to a path whose parents are traversable.

> Being a member of the `users` group is **not** a fix, only your *primary*
> group counts. Adding it only ever helped as a side effect of the re-login it
> requires, or of a YaST user edit resetting the home directory ownership.

If the problem persists, or on the second error above, the culprit is a stale
podman state — a leftover pause process still holding an old ID mapping. Be
sure to remove all artefacts previously created by podman, `podman system
prune` may help, then log out and log back in.

### opencode: OpenTUI render library fails to load

```bash
Failed to initialize OpenTUI render library: Failed to open library
"/tmp/.9adf7bf9fafaef9f-00000001.so": /tmp/.9adf7bf9fafaef9f-00000001.so:
failed to map segment from shared object
```

#### Why ?

opencode is a Bun single-file executable. At startup it unpacks its OpenTUI
native library into the Bun temporary directory and loads it with `dlopen()`,
which requires an executable mapping. The sandbox mounts `/tmp` with `noexec`,
so the kernel refuses that mapping and the TUI never comes up.

Upstream: <https://github.com/sst/opencode/issues/5175>

#### Solution

`run` mounts a dedicated executable tmpfs on `/run/agent-tmp` and points Bun at
it with `BUN_TMPDIR`, whenever the agent list contains `opencode`. `/tmp` keeps
its `noexec` for every other process.

Volumes are set when the container is **created**, so a container started
before this fix does not have the mount. Recreate it:

```bash
sh glaipnir.sh clean opencode
sh glaipnir.sh run opencode
```

Then, inside the sandbox:

```bash
echo "$BUN_TMPDIR"          # /run/agent-tmp
findmnt -no OPTIONS /tmp    # still lists noexec
ls /run/agent-tmp           # holds the unpacked libopentui.so
```

> Running the image directly with `podman run`, without `glaipnir`, is not
> affected: `/tmp` is executable there and Bun uses it by default.

---

## Additional docs

* [Overview](docs/overview.md) — architecture, volumes, image sizes, security measures
* [Contributing Guidelines](CONTRIBUTING.md) — coding style, commit message format

To use Google Vertex AI with OpenCode:

Ensure these environment variables are set before starting the sandbox:

```bash
export GOOGLE_CLOUD_PROJECT=<project ID>
export VERTEX_LOCATION=global
```

For normal in-container auth (`gcloud auth application-default login`), do not
set `GOOGLE_APPLICATION_CREDENTIALS`.

The launcher forwards `GOOGLE_CLOUD_PROJECT` and `VERTEX_LOCATION` into the
container.

`GOOGLE_APPLICATION_CREDENTIALS` should remain unset so ADC uses the default
credentials path created by `gcloud auth application-default login`.

If `GOOGLE_CLOUD_PROJECT` is unset, the entrypoint tries to read it from
`gcloud config get-value project`.

---

## License

aGPLv3 — See [LICENSE](LICENSE)
