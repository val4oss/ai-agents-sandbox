# AI Agents Sandbox

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

---

## Project activity

![Alt](https://repobeats.axiom.co/api/embed/4fa979a5fa985819cac3447152b2dfa6c697fafd.svg "Repobeats analytics image")

---

## Table of Contents

- [Requirements](#requirements)
- [Usage](#usage)
- [Runtime Example](#runtime-example)
- [Additional docs](#additional-docs)

---

## Requirements


### Dependency installation

```bash
sudo zypper install podman slirp4netns crun libkrun1 libkrunfw5
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

> After running the above command, log out and log back in to apply the group

---

## Usage

### Get the tool

```bash
# Clone this repository
git clone https://github.com/val4oss/ai-agents-sandbox.git
cd ai-agents-sandbox
```

### Build the image

```bash
sh ai-agents-sandbox.sh build           # Build the all-in-one image  (ai-agents-sandbox:latest)
sh ai-agents-sandbox.sh build <agent>   # Build an agent image        (ai-agents-sandbox-<agent>:latest)
```


The script copies injects the version number, passes the `AGENT` build-arg to
`podman build`, builds the image as `ai-agents-sandbox[-<agent>]:latest`.
Agent-specific builds only install the tools required by the selected agent,
resulting in smaller images.

```bash
# Verify the build
podman image inspect ai-agents-sandbox:latest | grep -E "User|Size"
```

### Run the isolated environment

```bash
# Start (or resume) the container (microVM if available)
sh ai-agents-sandbox.sh run <?agent>
# Start without microVM isolation
sh ai-agents-sandbox.sh run <?agent> no-microvm
# Define a custome workdir to mount as /home/aiuser/workspace.
sh ai-agents-sandbox.sh run <?agent> -w <dir_path>
```

> `<?agent>` can be empty to use the all-in-one image.

### Clean the environment

```bash
sh ai-agents-sandbox.sh clean     # Remove the container (auth and workspace preserved)
sh ai-agents-sandbox.sh clean all # Remove a specific agent container + its auth tokens
```

### Use a config file to customized your image

The project will look at ${ROOT_D}/ai-agents-sandbox.conf for a config file.
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
sh ai-agents-sandbox.sh build copilot
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
sh ai-agents-sandbox.sh run -w ~/workspace/

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
sh ai-agents-sandbox.sh run copilot
# → ✅ GitHub (gh) : authenticated
```

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
