# Overview

Overview of the ai-agents-sandbox architecture, design decisions, and security
measures.

---

## Table of Contents

- [Overview](#overview)
  - [Table of Contents](#table-of-contents)
  - [Project structure](#project-structure)
  - [Volumes used](#volumes-used)
  - [Available Agents](#available-agents)
  - [Images sizes](#images-sizes)
  - [Security Measures](#security-measures)
    - [🔒 Process isolation](#-process-isolation)
    - [📁 Filesystem isolation](#-filesystem-isolation)
    - [🔑 Credentials](#-credentials)
    - [🌐 Network isolation](#-network-isolation)
    - [🧊 MicroVM isolation (krun)](#-microvm-isolation-krun)
      - [macOS](#macos)
    - [📊 Resource limits](#-resource-limits)
  - [Persistence](#persistence)
  - [Per-Agent Builds](#per-agent-builds)

---

## Project structure

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
├── workspace/                 # ← Mounted as /home/aiuser (persistent, gitignored)
│   └── .gitkeep               #   Keeps the directory tracked in git
│
└── ai-agents-sandbox.sh       # build / run / clean / help — supports per-agent targets
```

---

## Volumes used

A `podman volume` is used for the aiuser HOME directory `/home/aiuser`. It keeps
authentication status between runs. The `workspace/` will be mounted into
`/home/aiuser/workspace/`. A perfect place to store working project, it can be
shared between different ai-agents-sandboxes. At every start, the entrypoint
automatically provisions:

- `~/.gitconfig` — default git configuration
- `~/.copilot/agents/` — Copilot agent definitions
- `~/workspace/` — your projects directory

Auth token directories (`.config/gh/`, `.gemini/`, `.claude/`) are created
automatically on first login. All runtime content is excluded from git via
`.gitignore`.

---

## Available Agents

| Agent | Command | First-time auth |
|---|---|---|
| GitHub Copilot | `copilot` | `gh auth login --scopes 'copilot'` |
| Gemini CLI | `gemini` | `gemini auth login` |
| Claude Code | `claude` | `claude auth login` or `export ANTHROPIC_API_KEY=sk-...` or `gcloud ...` |
| OpenCode | `opencode` | configure `~/.config/opencode/opencode.json` and select a model |
| antigravity | `agye` | run `agy` and use `Google Oauth` , be carefull of spaces in the URL to copy-paste |
| Hermes Agent | `hermes` | `hermes setup` to configure keys/models |

---

## Images sizes

> Fetched 26-06-09

|           Image               |   Size  |               Note               |
|-------------------------------|---------|----------------------------------|
| ai-agents-sandbox-gemini      | 833 MB  |                                  | 
| ai-agents-sandbox-claude      | 1.8 GB  | storage used by `gcloud` utility |
| ai-agents-sandbox-copilot     | 901 MB  |                                  |
| ai-agents-sandbox-antigravity | 837 MB  |                                  |
| ai-agents-sandbox             | 2.93 GB |                                  |

---

## Security Measures

### 🔒 Process isolation

| Measure | Flag | Effect |
|---|---|---|
| No privilege escalation | `--security-opt=no-new-privileges` | Prevents any `setuid` / capability gain |
| All capabilities dropped | `--cap-drop=ALL` | No raw socket, no mount, no `chown`, etc. |
| Default seccomp profile | built-in Podman default | Blocks ~300 dangerous syscalls |
| Rootless user | rootless Podman | Container processes owned by your UID, never real root |

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

### 🌐 Network isolation

| Measure | Effect |
|---|---|
| `--network=slirp4netns` | User-space network stack, fully isolated from the host |
| `outbound_addr=${_iface}` | Outbound to a public interface prevents requests from passing through internal company VPN |
| Internet access preserved | OAuth flows, API calls, package downloads work normally |


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

### 📊 Resource limits

| Measure | Flag | Effect |
|---|---|---|
| Memory limit | `krun.ram_mib=4096` | **microvm** only. Set in krun_vm.json OR annotations |
| CPU limit | `krun.cpus=2` | **microvm** only. Set in krun_vm.json OR annotations |
| Process limit | `pids_limit = 100` | Container cannot spawn more than 100 processes |

> cpu and memory limits for microVMs can be set via `krun_vm.json` (for
> `crun --version` < `1.27`) or directly as container annotations
> (`--annotation "krun.cpus=2" --annotation "krun.ram_mib=4096"`). The defaults
> are 4 CPUs and 8 GB RAM, which are sufficient for typical agent workloads
> while keeping the attack surface minimal.
> If you build an image with `crun` < `1.27`, uncomment the line from 
> [Containerfile](../image/Containerfile) that copy the `.krun_vm.json` in the 
> env.

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

## Per-Agent Builds

By default `build` (and `run`) targets an all-in-one image that
includes every agent. Use an agent name as an extra argument to produce a
**slim, single-agent image** that only installs what is needed:

| Command | Image name | Installed tools |
|---|---|---|
| `build` | `ai-agents-sandbox:latest` | gh CLI + gemini-cli + claude-code |
| `build copilot` | `ai-agents-sandbox-copilot:latest` | gh CLI only |
| `build gemini` | `ai-agents-sandbox-gemini:latest` | gemini-cli |
| `build claude` | `ai-agents-sandbox-claude:latest` | Google Cloud SDK + claude-code |
| `build opencode` | `ai-agents-sandbox-opencode:latest` | OpenCode CLI |
| `build hermes-agent` | `ai-agents-sandbox-hermes-agent:latest` | Hermes Agent CLI |

The corresponding `run <?agent>` and `clean <?agent> [all]` commands
automatically target the matching image and container name
(`ai-agents-sandbox<?-agent>`).

