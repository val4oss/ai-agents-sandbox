# Overview

Overview of the glaipnir project architecture, design decisions, and security
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
      - [macOS](#macos)
    - [🧊 MicroVM isolation (krun)](#-microvm-isolation-krun)
    - [📊 Resource limits](#-resource-limits)
  - [Persistence](#persistence)
  - [Image source: registry vs local build](#image-source-registry-vs-local-build)
  - [Per-Agent Builds](#per-agent-builds)
  - [Configuration Examples](#configuration-examples)

---

## Project structure

```
ai-agents-sandbox/
│
├── image/
│   ├── Containerfile          # Full image definition — no secrets; used with `--full`
│   ├── Containerfile.agent    # Slim per-agent image layered on the registry base (default build)
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
└── glaipnir.sh                # build / run / clean / help — supports per-agent targets
```

---

## Volumes used

1. To keep authentication across container restarts, cache directory is used.

  ```
  $CACHE_D/
    agents-mount/
      .config/
        gh/        copilot
        gcloud/    claude (Vertex) + opencode
        opencode/  opencode
      .claude/     claude
      .claude.json claude (file — pre-touched)
      .copilot/    copilot
      .gemini/     gemini + antigravity
      .hermes/     hermes-agent
  ```

  According the agent used, the cached auth will be mounted into the container.

2. The `${SANDBOX_D}` will be mounted into `/home/aiuser/workspace/`. A perfect
   place to store working project, it can be shared between different
   ai-agents-sandboxes.

3. At every start, the entrypoint automatically provisions:

  - `~/.gitconfig` — default git configuration
  - `<agents skills / others>` — agent specific configurations as skills, etc.

---

## Available Agents

| Agent | Command | First-time auth | Status |
|---|---|---|---|
| GitHub Copilot | `copilot` | `gh auth login` | Trusted |
| Gemini CLI | `gemini` | `gemini auth login` | Trusted |
| Claude Code | `claude` | `claude auth login` | Trusted |
| OpenCode | `opencode` | configure `opencode.json` | Trusted |
| antigravity | `agye` | run `agy` | Trusted |
| Hermes Agent | `hermes` | `hermes setup` | Untrusted |

---

## Images sizes

> Fetched 26-06-09

|           Image               |   Size  |               Note               |
|-------------------------------|---------|----------------------------------|
| ai-agents-sandbox-gemini      | 833 MB  |                                  | 
| ai-agents-sandbox-claude      | 1.8 GB  | storage used by `gcloud` utility |
| ai-agents-sandbox-copilot     | 901 MB  |                                  |
| ai-agents-sandbox-antigravity | 837 MB  |                                  |
| ai-agents-sandbox-hermes      | 1.88 GB |                                  |
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
| `--network=pasta` | User-space network stack, fully isolated from the host |
| `outbound_addr=${_iface}` | Outbound to a public interface prevents requests from passing through internal company VPN |
| Internet access preserved | OAuth flows, API calls, package downloads work normally |

#### macOS

On macOS, `pasta outbound_addr` is replaced by a **VPN enforcer** that
blocks corporate VPN routes at the Podman Machine VM kernel level using
`nftables`.

Before each container start, `run` inspects the macOS routing table and
handles three cases:

| VPN state | Detection | Behaviour |
|---|---|---|
| No VPN | No `utun`/`ppp` interface with an IPv4 address | Unrestricted egress |
| Split-tunnel | Specific host/network routes via `utun`/`ppp` | Discovered CIDRs blocked in VM |
| Full-tunnel | Default route (`0.0.0.0/0`) via VPN interface | Refused — user must reconfigure to split-tunnel |
| VPN active, no routes | `utun`/`ppp` present but no specific routes | User prompted: allow or block-all |

The **enforcer daemon** (`macos-vpn-enforcer.sh`) is installed as a
LaunchAgent (`~/Library/LaunchAgents/com.ai-agents-sandbox.macos-vpn-enforcer.plist`)
and runs for the lifetime of the container:

1. Connects to the Podman Machine VM via `podman machine ssh`.
2. Discovers the VM's external NIC and applies per-CIDR `nftables` DROP
   rules on new outbound connections to VPN-routed addresses.
3. Watches `route -n monitor` for routing changes and refreshes rules
   automatically — VPN connect/disconnect events are handled without user
   intervention.
4. Removes all rules and exits when the container stops.

```
container process
  → pasta (user-space NAT, no outbound_addr binding on macOS)
  → Podman Machine VM kernel
      nftables: DROP new connections to VPN CIDRs
      nftables: ACCEPT established/related + internet-bound traffic
  → Apple Hypervisor.framework boundary
  → macOS host
```

The relevant scripts are:

| Script | Role |
|---|---|
| `scripts/macos-sandbox.sh` | Enforcer lifecycle: install, start, stop, teardown |
| `scripts/macos-network-policy.sh` | VPN detection and route discovery (shared by daemon and main script) |
| `scripts/macos-vpn-enforcer.sh` | Daemon: applies/removes nftables rules inside Podman Machine VM |
| `launchd/com.ai-agents-sandbox.macos-vpn-enforcer.plist.template` | LaunchAgent plist template |


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
| Network | TSI (Transparent Socket Impersonation) replaces pasta — internet access is preserved |

Use `run no-microvm` (or `run <agent> no-microvm`) to opt out when
KVM is not available or not desired.

> On macOS, KVM is not available. `run` detects macOS automatically and
> skips microVM mode without requiring `no-microvm`. See the
> [macOS network isolation section](#macos) for the equivalent isolation
> boundary provided by Podman Machine.

### 📊 Resource limits

| Measure | Flag | Effect |
|---|---|---|
| Memory limit | `krun.ram_mib=4096` | **microvm** only. Set in krun_vm.json OR annotations |
| CPU limit | `krun.cpus=2` | **microvm** only. Set in krun_vm.json OR annotations |
| Process limit | `pids_limit = 1024` | Container cannot spawn more than 100 processes |

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

## Image source: registry vs local build

Prebuilt images are published to
`registry.opensuse.org/home/vlefebvre/container-images/containers/opensuse/`
and used automatically, so building is optional:

- **`run`** — if no local image exists (or the local image was itself pulled
  from that registry), `run` pulls the matching prebuilt image
  (`ai-agents-sandbox[-<agent>]`) and starts it. A locally built image always
  takes precedence.
- **`build`** — by default layers your customisations (packages, build hooks)
  on top of the registry base via `Containerfile.agent`, producing a slim
  image quickly. Pass **`--full`** to build the entire image from
  `Containerfile` instead of pulling the base.

This means the typical first run needs **no build step at all**.

---

## Per-Agent Builds

By default `build` (and `run`) targets an all-in-one image that
includes every agent. Use an agent name as an extra argument to produce a
**slim, single-agent image** that only installs what is needed:

| Command | Image name | Installed tools | Status |
|---|---|---|---|
| `build` | `ai-agents-sandbox` | gh CLI + gemini + claude | Trusted |
| `build copilot` | `ai-agents-sandbox-copilot` | gh CLI | Trusted |
| `build gemini` | `ai-agents-sandbox-gemini` | gemini-cli | Trusted |
| `build claude` | `ai-agents-sandbox-claude` | gcloud + claude | Trusted |
| `build opencode` | `ai-agents-sandbox-opencode` | opencode-ai | Trusted |
| `build hermes-agent` | `ai-agents-sandbox-hermes-agent` | hermes | Untrusted |

The corresponding `run <?agent>` and `clean <?agent> [all]` commands
automatically target the matching image and container name
(`ai-agents-sandbox<?-agent>`).

---

## Configuration Examples

The examples below can be combined freely. Place the config file with
`--conf` and pass `--build-hook` at **build** time; pass `--run-hook` at
**run** time.

### Adding extra packages

Use the `PACKAGES` array in the config file to install additional openSUSE
packages at image build time. No hook is needed for packages available in the
default Tumbleweed repositories.

```conf
# /tmp/glaipnir.conf
AGENT=claude
PACKAGES=(
    osc
    quilt
    patterns-devel-C-C++-devel_C_C++
)
```

```bash
sh glaipnir.sh build claude --conf /tmp/glaipnir.conf
```

### Adding packages from a custom repository (build hook)

When a package lives outside the default Tumbleweed repos, use a build hook
to add the repository and install the package during the image build. The hook
runs as root inside the build context.

```bash
sh glaipnir.sh build claude --build-hook path/to/build-hook.sh
```

```sh
#!/bin/sh
# build-hook.sh — install customize-ps1 from a custom OBS repo

echo "Installing custom package from a custom repo"
zypper --non-interactive addrepo \
    https://download.opensuse.org/repositories/home:/val4oss/openSUSE_Tumbleweed/ \
    home:val4oss
zypper --non-interactive --gpg-auto-import-keys refresh home:val4oss
zypper --non-interactive install --no-recommends customize-ps1
zypper clean --all
rm -rf /var/cache/zypp/*
```

### Configuring an agent at runtime (run hook)

Run hooks execute as `aiuser` every time the container starts — ideal for
provisioning agent configuration files that should not be baked into the image.

The hook is passed at run time and mounted into the container (not baked into
the image), so no rebuild is needed to change it:

```bash
sh glaipnir.sh run claude --run-hook path/to/run-hook.sh
```

The example below writes a Claude Code `settings.json` on first start,
configuring Vertex AI as the backend:

```sh
#!/bin/sh
# run-hook.sh — provision Claude Code settings

CLAUDE_SETTINGS="${HOME}/.claude/settings.json"
if [ ! -f "${CLAUDE_SETTINGS}" ]; then
    cat <<EOF > "${CLAUDE_SETTINGS}"
{
  "permissions": {
    "defaultMode": "default"
  },
  "env": {
    "CLAUDE_CODE_USE_VERTEX": "1",
    "CLOUD_ML_REGION": "global",
    "ANTHROPIC_VERTEX_PROJECT_ID": "xxxxxxx",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-4-6",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-4-8",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-haiku-4-5@20251001"
  },
  "model": "sonnet"
}
EOF
fi
```

