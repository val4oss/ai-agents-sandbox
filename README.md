# GLAIPNIR Project (AI Agents Sandbox)

<div align="center">
  <img 
    src="docs/banner.png"
    alt="Glaipnir project banner"
    width="500" height="500"
  >
  <p align="center">
    The silken ribbon that binds the wolf - now it binds the AI agents.
    <br />
    <a href="https://github.com/val4oss/ai-agents-sandbox/issues/new?template=bug_report.yml">Report Bug</a>
    &middot;
    <a href="https://github.com/val4oss/ai-agents-sandbox/issues/new?template=feature_request.yml">Request Feature</a>
  </p>
</div>

A secure, isolated environment for running AI coding agents: 

* **Robust Isolation:** Aims to create a significantly more robust environment
  than typical sandboxes using only containers, pairing rootless Podman with
  microVM isolation via libkrun.
* **Human-Crafted Security:** The Linux foundation and security layers are
  architected, designed, and mainly developed by humans — security is not made
  by an AI.

* supported agents:
  * **trusted** (comply with internal best practices):
    * `copilot` - GitHub Copilot CLI
    * `gemini` - Google Gemini CLI
    * `claude` - Anthropic Claude Code
    * `opencode` - Google OpenCode
    * `antigravity` - Google Antigravity-cli: `agy`
  * **untrusted** (does not comply with SUSE internal best practices):
    * `hermes-agent` - Nous Research Hermes Agent

> **Naming** — `glaipnir` is the tool you run. The images and containers it
> builds and manages keep the name `ai-agents-sandbox`, so that is what you
> will see in `podman images` and `podman ps`.

---

## Table of Contents

- [Source Tree](#source-tree)
- [Official Installation via Packaging](#official-installation-via-packaging)
- [Building, Installing, and Checking with build.sh](#building-installing-and-checking-with-buildsh)
- [Requirements & System Setup](#requirements--system-setup)
- [Documentation](#documentation)
- [License](#license)

---

## Source Tree

Overview of the repository structure:

```text
ai-agents-sandbox/
├── build.sh          # Project builder: check (ShellCheck), build, install, uninstall
├── src/              # Source scripts and modular shell libraries
│   ├── glaipnir.sh   # Main script (can be run directly from sources)
│   ├── printer.sh    # Terminal formatting and output library
│   └── macos-*.sh    # macOS sandbox, network policy, and VPN helpers
├── image/            # Container definitions (Containerfiles, entrypoint, agent configs)
└── docs/             # Extended guides (usage, troubleshooting, architecture overview)
```

* **`build.sh`**: The build and packaging script. Verifies shell sources with
  ShellCheck, consolidates modular scripts into a single standalone executable,
  and manages system/local installations.
* **`src/glaipnir.sh`**: The main command-line script. You can execute it
  directly from the sources (`sh src/glaipnir.sh`) without needing any prior
  build or installation.
* **`src/*.sh`**: Shell libraries sourced by the main script (e.g., `printer.sh`
  for colored status messages and terminal banners, and macOS
  sandboxing/networking helpers).
* **`image/`**: Container image assets, including root `Containerfile`, slim
  `Containerfile.agent`, runtime entrypoint scripts, default configurations, and
  per-agent profiles and skills.
* **`docs/`**: Detailed project documentation, including the
  [Usage Guide](docs/usage.md),
  [Troubleshooting Guide](docs/troubleshooting.md), and
  [Architecture Overview](docs/overview.md).

---

## Official Installation via Packaging

For openSUSE distributions, official packages are maintained in the Open Build
Service (OBS) repository `home:vlefebvre`.

### 1. Add the repository

* **For openSUSE Tumbleweed:**
  ```bash
  sudo zypper ar https://download.opensuse.org/repositories/home:/vlefebvre/openSUSE_Tumbleweed/home:vlefebvre.repo
  ```

* **For openSUSE Leap 15.5 / 15.6 / 16.0:**
  ```bash
  sudo zypper ar https://download.opensuse.org/repositories/home:/vlefebvre/16.0/home:vlefebvre.repo
  ```

### 2. Import the GPG signing key

```bash
sudo rpm --import https://download.opensuse.org/repositories/home:/vlefebvre/16.0/repodata/repomd.xml.key
```

### 3. Refresh and install

```bash
sudo zypper refresh
sudo zypper install glaipnir
```

---

## Building, Installing, and Checking with build.sh

Glaipnir provides a dedicated POSIX builder script, `build.sh`, to inspect
sources, build the standalone binary, and handle installation and
uninstallation.

### 1. Verify sources with ShellCheck

Ensure code quality and POSIX compliance before building:

```bash
./build.sh check
```

This verifies all source scripts (`src/glaipnir.sh`, `src/printer.sh`,
`src/macos-sandbox.sh`, `src/macos-network-policy.sh`).

### 2. Build the project

```bash
./build.sh
```

The build process:
* Cleans previous build artifacts in `build/`.
* Runs `build_check` with ShellCheck.
* Inlines internal source dependencies into a unified executable.
* Prepares staged assets under `build/`.

### 3. Install Glaipnir

* **System-wide install** (installs to `/usr/local/bin` and
  `/usr/local/share/glaipnir`, requires sudo):
  ```bash
  sudo ./build.sh install
  ```

* **User-local install** (no sudo needed; ensure `~/.local/bin` is on your
  `PATH`):
  ```bash
  PREFIX="${HOME}/.local" ./build.sh install
  ```

* **System install under `/usr`**:
  ```bash
  PREFIX="/usr" sudo ./build.sh install
  ```

* **Staging for packaging (`DESTDIR`)**:
  ```bash
  PREFIX="/usr" DESTDIR="/tmp/pkg-root" ./build.sh install
  ```

* **Specify a custom version**:
  ```bash
  VERSION="1.2.3" ./build.sh install
  ```

### 4. Uninstall

Remove installed binaries and data assets (pass the same `PREFIX` and `DESTDIR`
used during install):

```bash
sudo ./build.sh uninstall
# Or for a user-local install:
PREFIX="${HOME}/.local" ./build.sh uninstall
```

### 5. Clean build directory

```bash
./build.sh clean
```

> **Usage Note:** After installing, you can run `glaipnir` directly from any
> directory. The installed binary uses your current working directory as the
> default workspace and looks for its configuration file at
> `${XDG_CONFIG_HOME:-~/.config}/glaipnir/glaipnir.conf`.
>
> If upgrading from a pre-rename release (`ai-agents-sandbox`), remove legacy
> files:
> `sudo rm -f /usr/local/bin/ai-agents-sandbox` and
> `sudo rm -rf /usr/local/share/ai-agents-sandbox`, then migrate 
> `~/.config/ai-agents-sandbox/ai-agents-sandbox.conf` to 
> `~/.config/glaipnir/glaipnir.conf`.

---

## Requirements & System Setup

### Base dependencies installation

Install the required packages using zypper:

```bash
sudo zypper install podman passt crun libkrun1 libkrunfw5 ShellCheck
```

### Component version requirements

* `crun ≥ 1.22`
* `libkrun ≥ 1.18` (fixes agent TUI rendering and keyboard interaction; older
  versions cause fallback to container mode)
* `libkrunfw ≥ 5`

### Installing latest libkrun and crun

If your distribution ships older versions of `libkrun` or `crun`, you can
install compatible, tested builds from the openSUSE Virtualization repositories:

```bash
sudo zypper addrepo \
  https://download.opensuse.org/repositories/Virtualization:/containers/16.0/ \
  Virtualization_containers
sudo zypper addrepo \
  https://download.opensuse.org/repositories/Virtualization/16.0/ \
  Virtualization
sudo zypper --gpg-auto-import-keys refresh Virtualization_containers Virtualization
sudo zypper install --from Virtualization_containers crun
sudo zypper install --from Virtualization libkrun1 libkrunfw5
```

### MicroVM isolation & virtualization

* Glaipnir automatically detects `krun` on startup and enables microVM
  isolation.
* If `krun` is missing or KVM is unavailable, the script reports what is missing
  and falls back to standard rootless container mode.
* To explicitly run without microVM isolation, pass `--no-microvm`.
* If your host system is running inside a virtual machine, nested virtualization
  must be enabled on the hypervisor (e.g. AMD: `kvm_amd.nested=1`, Intel:
  `kvm_intel.nested=1`).

### KVM user permissions

* Your user account must belong to the `kvm` group:
  ```bash
  sudo usermod -aG kvm $USER
  ```
* Glaipnir verifies this group on startup. If the group is missing, it offers to
  add you (`[Y/n]`) and restarts the session with the group applied, without
  requiring a system reboot.
* If the group cannot be dynamically applied to your current shell session, log
  out and log back in.

---

## Documentation

* **[Usage Guide](docs/usage.md)** — Step-by-step practical workflows,
  single/multi-agent setups, custom tools, read-only bind mounts, status
  inspection, and cleaning.
* **[Troubleshooting](docs/troubleshooting.md)** — Diagnosing and fixing OCI
  permission issues, user namespace mappings, and OpenCode TUI loading errors.
* **[Overview & Architecture](docs/overview.md)** — Detailed view of sandbox
  architecture, volume mappings, security isolation models, and image
  footprints.
* **[Contributing Guidelines](CONTRIBUTING.md)** — Project coding style,
  testing practices, and pull request commit standards.

---

## License

aGPLv3 — See [LICENSE](LICENSE)
