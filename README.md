# AI Agents Sandbox

A secure, isolated container environment for running AI coding agents
(GitHub Copilot, Gemini CLI, Claude Code) on **openSUSE Tumbleweed**
using rootless Podman.

> Credentials are **never baked into the image**.
> Authentication is performed at runtime and persisted via a mounted
> volume on the host.

---

## Table of Contents

- [Project Structure](#project-structure)
- [Security Measures](#security-measures)
- [Requirements](#requirements)
- [Setup](#setup)
- [Build the Image](#build-the-image)
- [Usage](#usage)
- [Runtime Example](#runtime-example)
- [Persistence](#persistence)
- [Available Agents](#available-agents)
- [Per-Agent Builds](#per-agent-builds)

---

## Project Structure

```
ai-agents-sandbox/
├── Makefile                   # build / run / clean / help — supports per-agent targets
│
├── scripts/
│   ├── build.sh               # Build script — copies image/, injects version, runs podman build
│   ├── containers.conf        # Podman security defaults (caps, network, userns)
│   ├── run.sh                 # Run script — creates or resumes the container
│   └── clean.sh               # Clean script — removes container and optionally auth tokens
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
└── sandbox/                   # ← Mounted as /home/aiuser (persistent, gitignored)
    └── .gitkeep               #   Keeps the directory tracked in git
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

### 📊 Resource limits

| Measure | Flag | Effect |
|---|---|---|
| Memory limit |  | Needs to use podman machine |
| CPU limit |  | Needs to use podman machine |
| Process limit | `pids_limit = 100` | Container cannot spawn more than 100 processes |

```bash
cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/cgroup.controllers
# expected: cpuset cpu io memory hugetlb pids rdma misc
```

---

## Requirements

```bash
# Podman with rootless support
sudo zypper install podman slirp4netns

# Verify rootless mode is active
podman info | grep rootless   # expected: rootless: true
```

---

## Setup

```bash
# Clone this repository
git clone https://github.com/val4oss/ai-sandbox.git
cd ai-sandbox
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
make build            # Build the all-in-one image  (ai-agents-sandbox:latest)
make build copilot    # Build a Copilot-only image   (ai-agents-sandbox-copilot:latest)
make build claude     # Build a Claude-only image    (ai-agents-sandbox-claude:latest)
make build gemini     # Build a Gemini-only image    (ai-agents-sandbox-gemini:latest)
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

```bash
make build            # Build the all-in-one image
make build <agent>    # Build an agent-specific image (claude | copilot | gemini)
make run              # Start (or resume) the all-in-one container
make run <agent>      # Start (or resume) an agent-specific container
make clean            # Remove the container (auth and workspace preserved)
make clean <agent>    # Remove a specific agent container
make clean-all        # Remove the container + all auth tokens (workspace preserved)
make clean-all <agent># Remove a specific agent container + its auth tokens
make help             # Show all available commands
```

Or directly with the scripts if `make` is not available:

```bash
sh scripts/build.sh [<agent>]
sh scripts/run.sh   [<agent>]
sh scripts/clean.sh [--all] [<agent>]
```

---

## Runtime Example

Complete walkthrough: authenticate GitHub Copilot, clone a repository,
and use Copilot on the code.

### Step 1 — Start the container

```bash
make run
```

Expected output:

```
╔══════════════════════════════════════════════════════════════╗
║         AI Agents Sandbox v0.1 — Secure Mode                 ║
╠══════════════════════════════════════════════════════════════╣
║  Available agents :                                          ║
║    • gh copilot   → GitHub Copilot CLI                       ║
║    • gemini       → Gemini CLI                               ║
║    • claude       → Claude Code                              ║
║                                                              ║
║  Directory :                                                 ║
║    ~           → Home, config                                ║
║    ~/workspace → all projects, git clones                    ║
╚══════════════════════════════════════════════════════════════╝

── Authentication status ───────────────────────────────
  ⚠️  GitHub Copilot : not authenticated — run : gh auth login --scopes 'copilot'
  ⚠️  Gemini CLI     : not authenticated — run : gemini auth login
  ⚠️  Claude Code    : not authenticated — run : claude auth login
────────────────────────────────────────────────────────

── Notes ───────────────────────────────────────────────
 To install though Vertex Ai, connect to Google Cloud with:
  gcloud auth application-default login
────────────────────────────────────────────────────────

[2026-04-24 10:00:00] Session started — UID=1000 | ai-agents-sandbox | agent(s)=claude copilot gemini
```

> When running an agent-specific container (e.g. `make run copilot`), only
> that agent's line appears in the banner and only its auth check is shown.

### Step 2 — Authenticate GitHub Copilot

```bash
# Inside the container
gh auth login
```

Follow the prompts:

```
? Where do you use GitHub?            → GitHub.com
? What is your preferred protocol?    → HTTPS
? How would you like to authenticate? → Login with a web browser

! First copy your one-time code: ABCD-1234
  Open https://github.com/login/device in your HOST browser
  and enter the code above.

✓ Authentication complete.
✓ Logged in as val4oss
```

```bash
# Confirm the Copilot extension is ready
gh copilot --version
```

### Step 3 — Clone a repository and use Copilot

```bash
# Inside the container — workspace is ready at ~/workspace
cd ~/workspace
gh repo clone val4oss/ai-sandbox

cd ai-sandbox

# Ask Copilot to suggest a command
gh copilot suggest "write a bash function to check if a podman container is running"

# Ask Copilot to explain a security flag
gh copilot explain "podman run --cap-drop=ALL --userns=keep-id"
```

### Step 4 — Exit and verify persistence

```bash
# Exit the container
exit

# On the host — token is preserved
ls sandbox/.config/gh/
# → hosts.yml  ← your token, stored on YOUR host filesystem

# Restart — authentication is immediately restored
make run
# → ✅ GitHub (gh) : authenticated
```

---

## Persistence

Auth tokens **survive container restarts and removals** because they live
on the host filesystem under `sandbox/`:

```
make clean          # container deleted
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
make run            # new container, everything intact ✅
```

> `make clean-all` removes auth token directories but preserves `workspace/`.
> Defaults (`.gitconfig`, `.copilot/agents/`) are re-provisioned from the
> image on the next `make run`.

---

## Available Agents

| Agent | Command | First-time auth |
|---|---|---|
| GitHub Copilot | `gh copilot suggest` / `gh copilot explain` | `gh auth login --scopes 'copilot'` |
| Gemini CLI | `gemini` | `gemini auth login` |
| Claude Code | `claude` | `claude auth login` or `export ANTHROPIC_API_KEY=sk-...` |

---

## Per-Agent Builds

By default `make build` (and `make run`) targets an all-in-one image that
includes every agent. Use an agent name as an extra argument to produce a
**slim, single-agent image** that only installs what is needed:

| Command | Image name | Installed tools |
|---|---|---|
| `make build` | `ai-agents-sandbox:latest` | gh CLI + gemini-cli + claude-code |
| `make build copilot` | `ai-agents-sandbox-copilot:latest` | gh CLI only |
| `make build gemini` | `ai-agents-sandbox-gemini:latest` | Google Cloud SDK + gemini-cli |
| `make build claude` | `ai-agents-sandbox-claude:latest` | Google Cloud SDK + claude-code |

The corresponding `make run <agent>` and `make clean[-all] <agent>` commands
automatically target the matching image and container name
(`ai-agents-sandbox-<agent>`).

---

## License

MIT — See [LICENSE](LICENSE)
