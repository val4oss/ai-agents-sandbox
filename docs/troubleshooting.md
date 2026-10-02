# Troubleshooting

This guide covers common issues, root causes, diagnosis steps, and
solutions when using **Glaipnir**.

---

## Table of Contents

- [OCI permissions denied](#oci-permissions-denied)
  - [Symptoms](#symptoms)
  - [Why does this happen?](#why-does-this-happen)
  - [Diagnose](#diagnose)
  - [Solutions](#solutions)
- [OpenCode: OpenTUI render library fails to load](#opencode-opentui-render-library-fails-to-load)
  - [Symptoms](#symptoms-1)
  - [Why does this happen?](#why-does-this-happen-1)
  - [Solution](#solution)

---

## OCI permissions denied

### Symptoms

When launching a container, you may encounter one of the following errors:

```text
[INFO] Starting isolated container...
Error: krun: open `/home/user/.local/share/containers/storage/overlay/0e8145fb1488986827f9e57dda305062fe06f2b1c8f25d441c0b0a5a693ba1be/merged`: Permission denied: OCI permission denied
```

or:

```text
DEBU[0000] Unmounted container "c83638e08d75442a5c383ed3790d0fed6c0778c7faaf953e5560ab570f3983b3"
DEBU[0000] ExitCode msg: "container create failed (no logs from conmon): conmon bytes \"\": readobjectstart: expect { or n, but found \x00, error found in #0 byte of ...||..., bigger context ...||..."
Error: container create failed (no logs from conmon): conmon bytes "": readObjectStart: expect { or n, but found , error found in #0 byte of ...||..., bigger context ...||...
```

### Why does this happen?

Glaipnir runs with `--userns keep-id` so that files created in the workspace
continue to belong to your host user. As a consequence, **the container root
user is mapped to one of your subordinate IDs** (defined in `/etc/subuid`,
typically starting at `100000`), and this subordinate ID must traverse host
directories to open container storage.

The subordinate ID must be able to traverse every directory from `/` down to
`~/.local/share/containers/storage`, as well as mounted volume paths. Access is
blocked when **both** of the following conditions are met:

1. The directory is not traversable by others (lacks the `o+x` execution bit,
   e.g. `0700` instead of `0755` or `0711`), **and**
2. The directory's group ownership does **not** match your primary group.

The Linux kernel only permits a subordinate ID to traverse a directory without
"other" execution rights if the directory's owner and group are mapped into
the user namespace. Because only your own UID and primary GID are mapped,
supplementary groups (even after running `usermod -aG`) are not mapped.

**Typical scenario:** A user home directory created with `0700` permissions and
group-owned by `users`, common on systems inherited from openSUSE/SLE legacy
user schemes where homes belong to `<user>:users` while the user's primary
group is a private group (`<user>:<user>`).

### Diagnose

Run the following commands on your host to inspect your user IDs and directory
permissions:

```bash
id
stat -c '%n %U:%G %a' / /home "$HOME" "$HOME/.local" "$HOME/.local/share" \
    "$HOME/.local/share/containers"
```

Look for any directory in the path whose mode does not end in an odd digit
(lacks `x` for "other") **and** whose group differs from your primary group
reported by `id`.

For example, a problematic home directory for user `devel` whose primary group
is `devel`:

```text
/home/devel devel:users 700
```

### Solutions

Choose the solution best suited to your system setup:

#### 1. Align home directory group with your primary group (Recommended)

Since you own your home directory, no elevated privileges are required, and
permissions remain private (`0700`):

```bash
chgrp "$(id -gn)" ~
```

#### 2. Grant traversal permissions

If group ownership must remain untouched (e.g. corporate policy, shared setup),
allow traversal. Using `0711` lets local processes cross the directory to reach
known subordinate paths without granting listing (`r`) rights:

```bash
chmod o+x ~
```

The same rule applies to any custom workspace passed with `-w` or cache paths
when they reside outside `$HOME`.

#### 3. Relocate container storage path

As a fallback, you can configure Podman to store container layers in a directory
with traversable parents by setting `rootless_storage_path` in
`~/.config/containers/storage.conf`.

#### 4. Clear stale Podman runtime states

If the second error variant occurs or issues persist, a stale Podman pause
process may be holding an outdated ID mapping. Remove old artifacts and reset
the session:

```bash
podman system prune
```

Then log out and log back in to apply clean user namespace mappings.

---

## OpenCode: OpenTUI render library fails to load

### Symptoms

When starting `opencode` inside the sandbox, startup fails with:

```text
Failed to initialize OpenTUI render library: Failed to open library
"/tmp/.9adf7bf9fafaef9f-00000001.so": /tmp/.9adf7bf9fafaef9f-00000001.so:
failed to map segment from shared object
```

### Why does this happen?

OpenCode is packaged as a Bun single-file executable. During startup, it
extracts its native OpenTUI shared library into the Bun temporary directory
and loads it using `dlopen()`.

For security, Glaipnir mounts `/tmp` inside the sandbox with `noexec`
(preventing code execution from temporary directories). Because the shared
object is in `/tmp`, the kernel denies memory execution mapping (`PROT_EXEC`),
preventing OpenTUI from loading.

### Solution

Glaipnir automatically mounts a dedicated executable `tmpfs` on `/run/agent-tmp`
and directs Bun to it via `BUN_TMPDIR=/run/agent-tmp` whenever `opencode` is
included in the agent list. The rest of `/tmp` retains its strict `noexec`
security protection.

Because volume configurations are bound at container **creation** time, an
existing container created before this configuration needs to be recreated:

```bash
glaipnir clean opencode
glaipnir run opencode
```

You can confirm the fix inside the sandbox:

```bash
echo "$BUN_TMPDIR"          # Outputs: /run/agent-tmp
findmnt -no OPTIONS /tmp    # Still lists: noexec
ls /run/agent-tmp           # Contains: libopentui.so
```
