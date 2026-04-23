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

---

## Project Structure

```
ai-sandbox/
├── Makefile                   # build / run / clean / help
│
├── scripts/
│   ├── build.sh               # Build script — copies image/, injects version, runs podman build
│   ├── containers.conf        # Podman security defaults (caps, network, userns)
│   ├── run.sh                 # Run script — creates or resumes the container
│   └── clean.sh               # Clean script — removes container and optionally auth tokens
│
├── image/
│   ├── Containerfile          # Image definition — no secrets
│   ├── agents/
│   │   └── copilot/           # Copilot agent definitions (provisioned to ~/.copilot/agents/)
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

Resource limits (`--memory`, `--cpus`, `--pids-limit`) require cgroup v2
delegation to be active for your user session. They are **not enabled by
default** to ensure compatibility with all rootless Podman setups.

To enable them, verify delegation is active:

```bash
cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/cgroup.controllers
# expected: cpuset cpu io memory hugetlb pids rdma misc
```

If `memory`, `cpu`, and `pids` are listed, add the following flags to the
`podman run` call in `run.sh`:

```
--memory=8g --cpus=4 --pids-limit=500
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
make build
```

The script copies `image/` into a temporary `build/` directory, injects
the version number, builds the image as `ai-agents-sandbox:latest`, then
removes the temporary directory.

```bash
# Verify the build
podman image inspect ai-agents-sandbox:latest | grep -E "User|Size"
```

---

## Usage

```bash
make build      # Build the container image
make run        # Start (or resume) the container
make clean      # Remove the container (auth preserved)
make clean-all  # Remove the container + all auth tokens
make help       # Show all available commands
```

Or directly with the scripts if `make` is not available:

```bash
sh scripts/build.sh
sh scripts/run.sh
sh scripts/clean.sh [--all]
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
║         AI Agents Sandbox v0.1 — Secure Mode                ║
╠══════════════════════════════════════════════════════════════╣
║  Available agents :                                          ║
║    • gh copilot   → GitHub Copilot CLI                       ║
║    • gemini       → Gemini CLI                               ║
║    • claude       → Claude Code                              ║
╚══════════════════════════════════════════════════════════════╝

── Authentication status ───────────────────────────────
  ⚠️  GitHub Copilot : not authenticated — run : gh auth login
  ⚠️  Gemini CLI     : not authenticated — run : gemini auth login
  ⚠️  Claude Code    : not authenticated — run : claude auth login
────────────────────────────────────────────────────────
```

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
| GitHub Copilot | `gh copilot suggest` / `gh copilot explain` | `gh auth login` |
| Gemini CLI | `gemini` | `gemini auth login` |
| Claude Code | `claude` | `claude auth login` or `export ANTHROPIC_API_KEY=sk-...` |

---

## License

MIT — See [LICENSE](LICENSE)
