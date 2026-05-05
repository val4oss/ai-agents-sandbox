# AI Agents Sandbox

A secure, isolated environment for running AI coding agents (GitHub Copilot,
Gemini CLI, Claude Code) on **openSUSE Tumbleweed** using rootless container
(Podman) and microvm (libkrun).

> Credentials are **never baked into the image**.
> Authentication is performed at runtime and persisted via a mounted
> volume on the host.

---

## Table of Contents

- [Requirements](#requirements)
- [Setup](#setup)
- [Build the Image](#build-the-image)
- [Usage](#usage)
- [Runtime Example](#runtime-example)
- [Project Structure](#project-structure)
- [Security Measures](#security-measures)
- [Persistence](#persistence)
- [Available Agents](#available-agents)
- [Per-Agent Builds](#per-agent-builds)

---

## Requirements

```bash
# Podman with rootless support
sudo zypper install podman slirp4netns

# Verify rootless mode is active
podman info | grep rootless   # expected: rootless: true
```

### Optional: krun for microVM isolation (recommended)

MicroVM mode requires `krun` (crun with libkrun support) and matching runtime
libraries. The versions bundled with the base OS are often too old — use the
**Virtualization:containers** repository which ships tested, compatible builds.

#### openSUSE Tumbleweed

```bash
sudo zypper install crun libkrun1 libkrunfw5
sudo usermod -aG kvm "$USER"   # log out and back in afterwards
```

#### openSUSE Leap 16.0

The base Leap repo ships outdated libkrun builds (1.x from 2023) that are
incompatible with the current crun. Add the Virtualization:containers repo
first:

```bash
sudo zypper addrepo \
  https://download.opensuse.org/repositories/Virtualization:/containers/16.0/ \
  Virtualization_containers
sudo zypper addrepo \
  https://download.opensuse.org/repositories/Virtualization/16.0/ \
  Virtualization
sudo zypper --gpg-auto-import-keys refresh Virtualization_containers \
  Virtualization
sudo zypper install --from Virtualization_containers crun
sudo zypper install --from Virtualization libkrun1 libkrunfw5
sudo usermod -aG kvm "$USER"   # log out and back in afterwards
```

Minimum required versions: `crun ≥ 1.22`, `libkrun ≥ 1.17`, `libkrunfw ≥ 5`.

> `run` will detect krun automatically and enable microVM mode. If krun is
> not installed or KVM is unavailable, the script prints what is missing and how
> to fix it. To skip microVM attempt, `run` with `no-microvm`.

> If your host is itself a VM, nested virtualisation must be enabled on the
> hypervisor (AMD: `kvm_amd.nested=1`, Intel: `kvm_intel.nested=1`).

---

## Setup

```bash
# Clone this repository
git clone https://github.com/val4oss/ai-agents-sandbox.git
cd ai-agents-sandbox
```

The `sandbox/` directory is mounted as `/home/aiuser` at runtime. On first
start, the entrypoint automatically provisions:

- `~/.gitconfig` — default git configuration
- `~/.copilot/agents/` — Copilot agent definitions
- `~/workspace/` — your projects directory

Auth token directories (`.config/gh/`, `.gemini/`, `.claude/`) are created
automatically on first login. All runtime content is excluded from git via
`.gitignore`.

---

## Build the Image

```bash
sh ai-agents-sandbox.sh build           # Build the all-in-one image  (ai-agents-sandbox:latest)
sh ai-agents-sandbox.sh build copilot   # Build a Copilot-only image   (ai-agents-sandbox-copilot:latest)
sh ai-agents-sandbox.sh build claude    # Build a Claude-only image    (ai-agents-sandbox-claude:latest)
sh ai-agents-sandbox.sh build gemini    # Build a Claude-only image    (ai-agents-sandbox-claude:latest)
```

The script copies `image/` into a temporary `build/` directory, injects
the version number, passes the `AGENT` build-arg to `podman build`, builds
the image as `ai-agents-sandbox[-<agent>]:latest`, then removes the
temporary directory. Agent-specific builds only install the tools required
by the selected agent, resulting in smaller images.

```bash
# Verify the build
podman image inspect ai-agents-sandbox:latest | grep -E "User|Size"
```

### Image sizes

> Fetched 26-04-27

| Image | Size | Note |
|---|---|---|
| ai-agents-sandbox-gemini | 1.76 GB | |
| ai-agents-sandbox-claude | 1.92 GB | |
| ai-agents-sandbox-copilot | 588 MB | ⚠️copilot not installed, installed in runtime after auth. |
| ai-agents-sandbox | 2.12 GB | |

---

## Usage

### Run the isolated environment

```bash
sh ai-agents-sandbox.sh run <?agent>            # Start (or resume) the container (microVM if available)
sh ai-agents-sandbox.sh run <?agent> no-microvm # Start without microVM isolation
```

> `<?agent>` can be empty to use the all-in-one image.

### Clean the environment

```bash
sh ai-agents-sandbox.sh clean     # Remove the container (auth and workspace preserved)
sh ai-agents-sandbox.sh clean all # Remove a specific agent container + its auth tokens
```

---

## Runtime Example

Complete walkthrough: authenticate GitHub Copilot, clone a repository,
and use Copilot on the code.

### Step 1 - Build the image

```bash
sh ai-agents-sandbox.sh build copilot
```

Expected output:

```
[INFO] Building container image ai-agents-sandbox-copilot:0.1.0 ...
...
Successfully tagged localhost/ai-agents-sandbox-copilot:latest
Successfully tagged localhost/ai-agents-sandbox-copilot:0.1.0
b61090dd633ea5b371390111892a172f5b8f1a47926919c7518674d893cdbf41
[INFO] Image built successfully.
[INFO] [✓] Done.
```

### Step 2 — Start the container

```bash
sh ai-agents-sandbox.sh run copilot
```

Expected output:

```
sh ai-agents-sandbox.sh run copilot
[INFO] Running sandbox with microVM isolation for agent 'copilot'...
[INFO] Starting isolated container...

         JJJJJJJJ                            aiuser@ai-sandbox
      JJJJJJJJJJJJJJ                         -----------------
    JJJJJJ   =JJJJJJJ                        OS: openSUSE Tumbleweed x86_64
   JJJJ      =JJJ JJJJ                       Kernel: 6.12.68
   JJJ       =JJJ   JJJ                      Uptime: 0 secs
  JJJJ       =JJJ   JJJ                      Packages: 198 (rpm)
  JJJJJJJJJJJJJJJ   JJJJ                     Shell: bash 5.3.9
   JJJJJJJJJJJJJJ   JJJJ                     Terminal: init.krun
   JJJJ             JJJJ                     CPU: 2x (1)
    JJJJJ=          JJJJ                     Memory: 0.15 GiB / 3.85 GiB (4%)
      JJJJJJJJJJJJJJJJJJJJJJJJJJJJJ=
        =JJJJJJJJJJJJJJJJJJJJJJJJJJJJJ
                    JJJJ         =JJJJJJ
                    JJJJ            =JJJJ
                    JJJJ   JJJJJJJJJJJJJJ
                    JJJJ   JJJJJJJJJJJJJJJ
                    JJJJ   JJJJ       JJJJ
                     JJJ   JJJJ       JJJ
                     JJJJJ JJJJ      JJJJ
                      =JJJJJJJJ   JJJJJJ
                        JJJJJJJJJJJJJJ
                           JJJJJJJ=

╔══════════════════════════════════════════════════════════════╗
║         AI Agents Sandbox v0.1.0 — Secure Mode               ║
╠══════════════════════════════════════════════════════════════╣
║  Available agents :                                          ║
║    • gh copilot   → GitHub Copilot CLI                       ║
║                                                              ║
║  Directory :                                                 ║
║    ~           → Home, config                                ║
║    ~/workspace → all projects, git clones                    ║
╚══════════════════════════════════════════════════════════════╝

── Authentication status ───────────────────────────────
  ⚠️  GitHub (gh) : not authenticated — run : gh auth login --scopes 'copilot'
  ✅ GitHub Copilot : built-in (gh copilot suggest / explain)
────────────────────────────────────────────────────────

[2026-05-05 12:54:19] Session started — UID=1000 | ai-sandbox | agent(s)=copilot

[12:54:19] aiuser @ ai-sandbox : ~
$
```

> When running an agent-specific container, only that agent's line appears in
> the banner and only its auth check is shown.

### Step 3 — Authenticate GitHub Copilot

```bash
# Inside the container
gh auth login
```

Follow the prompts:

```
? Where do you use GitHub?            → GitHub.com
? What is your preferred protocol?    → HTTPS
? Authenticate Git with your GitHub credentials? (Y/n) -> Y
? How would you like to authenticate? → Login with a web browser

! First copy your one-time code: ABCD-1234
  Open https://github.com/login/device in your HOST browser
  and enter the code above.

✓ Authentication complete.
✓ Logged in as val4oss
```

### Step 4 - Install copilot

```bash
gh copilot
? Would you like to install it? -> Y
```

```
# Confirm the Copilot extension is ready
$ gh copilot --version
GitHub Copilot CLI 1.0.40.
Run 'copilot update' to check for updates.
```

### Step 5 — Clone a repository and use Copilot

```bash
# Inside the container — workspace is ready at ~/workspace
cd ~/workspace
git clone val4oss/ai-agents-sandbox

cd ai-agents-sandbox

# Ask Copilot to suggest a command
gh copilot suggest "write a bash function to check if a podman container is running"

# Ask Copilot to explain a security flag
gh copilot explain "podman run --cap-drop=ALL --userns=keep-id"
```

### Step 6 — Exit and verify persistence

```bash
# Exit the container
exit

# On the host — token is preserved
ls sandbox/.config/gh/
# → hosts.yml  ← your token, stored on YOUR host filesystem

# Restart — authentication is immediately restored
sh ai-agents-sandbox.sh run copilot
# → ✅ GitHub (gh) : authenticated
```

---

## Project Structure

```
ai-agents-sandbox/
│
├── image/
│   ├── Containerfile          # Image definition — no secrets; AGENT build-arg for slim builds
│   ├── agents/
│   │   ├── claude/            # Claude sub-agent definitions (provisioned to ~/.claude/agents/)
│   │   ├── copilot/           # Copilot agent definitions (provisioned to ~/.copilot/agents/)
│   │   └── gemini/            # Gemini sub-agent definitions (provisioned to ~/.gemini/agents/)
│   ├── skel/
│   │   └── .gitconfig         # Default git config (provisioned to ~/.gitconfig on first run)
│   └── scripts/
│       ├── entrypoint.sh      # Startup script — home provisioning + auth status check
│       └── healthcheck.sh     # Container health verification
│
├── sandbox/                   # ← Mounted as /home/aiuser (persistent, gitignored)
│   └── .gitkeep               #   Keeps the directory tracked in git
│
└── ai-agents-sandbox.sh       # build / run / clean / help — supports per-agent targets
```

---

## Security Measures

### 🔒 Process isolation

| Measure | Flag | Effect |
|---|---|---|
| No privilege escalation | `--security-opt=no-new-privileges` | Prevents any `setuid` / capability gain |
| All capabilities dropped | `--cap-drop=ALL` | No raw socket, no mount, no `chown`, etc. |
| Default seccomp profile | built-in Podman default | Blocks ~300 dangerous syscalls |
| Rootless user | rootless Podman | Container processes owned by your UID, never real root |

### 🌐 Network isolation

| Measure | Effect |
|---|---|
| `--network=slirp4netns` | User-space network stack, fully isolated from the host |
| No LAN / VPN access | Company interfaces (`tun0`, `wg0`...) are invisible |
| Internet access preserved | OAuth flows, API calls, package downloads work normally |

### 📁 Filesystem isolation

| Measure | Effect |
|---|---|
| Dedicated home volume | The real `$HOME` is never mounted |
| Explicit volume whitelist | Only `sandbox/` is mounted as `/home/aiuser` |
| `--tmpfs /tmp:noexec,nosuid` | `/tmp` is in RAM, non-executable, non-setuid |
| No Docker / Podman socket | Container cannot spawn other containers |

### 🔑 Credentials

| Principle | Implementation |
|---|---|
| Zero secrets in the image | `Containerfile` contains no tokens, passwords or API keys |
| Runtime-only authentication | `gh auth login`, `gemini auth login`, `claude auth login` |
| Persistence via host volume | Tokens stored in `sandbox/` under your control |
| Isolated from real `~/.config` | Container never sees your SSH keys, GPG keys or `.netrc` |

### 🧊 MicroVM isolation (krun)

When `krun` is installed and KVM is available, `run` automatically starts
each container inside a dedicated **microVM** backed by KVM rather than sharing
the host kernel. The attack path becomes:

```
container process
  → escape namespaces    (caps / seccomp / rootless — existing defence)
  → exploit microVM kernel  (separate minimal kernel, tiny attack surface)
  → escape KVM hypervisor   (hardware boundary: Intel VT-x / AMD-V)
  → reach host kernel
```

| Gain | Detail |
|---|---|
| Separate kernel | A container kernel exploit stays inside the microVM |
| Hardware boundary | Two extra escape layers vs. namespace-only isolation |
| Network | TSI (Transparent Socket Impersonation) replaces slirp4netns — internet access is preserved |

Use `run no-microvm` (or `run <agent> no-microvm`) to opt out when
KVM is not available or not desired.

#### macOS

KVM is not available on macOS, so krun does not apply. `run` detects
macOS automatically, prints a notice, and falls back to standard mode without
requiring `no-microvm`.

Podman on macOS runs every container inside a Linux VM managed by
`podman machine` and backed by **Apple Hypervisor.framework**. That VM is
itself a hardware-level boundary between the container and the macOS host,
providing isolation comparable to what krun adds on Linux — with no extra
configuration needed.

```
container process
  → escape namespaces    (caps / seccomp / rootless — existing defence)
  → reach podman machine VM kernel   (hardware boundary via Hypervisor.framework)
  → reach macOS host
```

---

### 📊 Resource limits

| Measure | Flag | Effect |
|---|---|---|
| Memory limit | `krun.ram_mib=4096` | **microvm** only. Set in krun_vm.json OR annotations |
| CPU limit | `krun.cpus=2` | **microvm** only. Set in krun_vm.json OR annotations |
| Process limit | `pids_limit = 100` | Container cannot spawn more than 100 processes |

> cpu and memory limits for microVMs can be set via `krun_vm.json` (for
> `crun --version` < `1.27`) or directly as container annotations
> (`--annotation "krun.cpus=2" --annotation "krun.ram_mib=4096"`). The defaults
> are 2 CPUs and 4 GB RAM, which are sufficient for typical agent workloads
> while keeping the attack surface minimal.

```bash
cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/cgroup.controllers
# expected: cpuset cpu io memory hugetlb pids rdma misc
```

---

## Persistence

Auth tokens **survive container restarts and removals** because they live
on the host filesystem under `sandbox/`:

```
clean          # container deleted
        │
        │  Lost  : container internal filesystem
        │
        │  Preserved in sandbox/ :
        ▼
┌──────────────────────────────────────────────────┐
│  .gitconfig          ← git config   [gitignored] │
│  workspace/          ← your work    [gitignored] │
│  .config/gh/         ← gh token     [gitignored] │
│  .gemini/            ← Gemini token [gitignored] │
│  .claude/            ← Claude token [gitignored] │
└──────────────────────────────────────────────────┘
        │
run            # new container, everything intact ✅
```

> `clean all` removes auth token directories but preserves `workspace/`.
> Defaults (`.gitconfig`, `.copilot/agents/`) are re-provisioned from the
> image on the next `run`.

---

## Available Agents

| Agent | Command | First-time auth |
|---|---|---|
| GitHub Copilot | `gh copilot suggest` / `gh copilot explain` | `gh auth login --scopes 'copilot'` |
| Gemini CLI | `gemini` | `gemini auth login` |
| Claude Code | `claude` | `claude auth login` or `export ANTHROPIC_API_KEY=sk-...` |

---

## Per-Agent Builds

By default `build` (and `run`) targets an all-in-one image that
includes every agent. Use an agent name as an extra argument to produce a
**slim, single-agent image** that only installs what is needed:

| Command | Image name | Installed tools |
|---|---|---|
| `build` | `ai-agents-sandbox:latest` | gh CLI + gemini-cli + claude-code |
| `build copilot` | `ai-agents-sandbox-copilot:latest` | gh CLI only |
| `build gemini` | `ai-agents-sandbox-gemini:latest` | Google Cloud SDK + gemini-cli |
| `build claude` | `ai-agents-sandbox-claude:latest` | Google Cloud SDK + claude-code |

The corresponding `run <?agent>` and `clean <?agent> [all]` commands
automatically target the matching image and container name
(`ai-agents-sandbox<?-agent>`).

---

## License

aGPLv3 — See [LICENSE](LICENSE)
