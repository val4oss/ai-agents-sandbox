---
name: Quilt tool for packager
description: Use the tool `quilt` to manage patches in a packaging source tree.
when_to_use: if working with patches in a packaging source tree.
allowed-tools: Bash(quilt *), Bash(cd *), Read, Write
model: sonnet
---

## Directory layout — read this first

Working with quilt involves **two distinct directories**. Confusing them is the
most common source of errors.

| Location | What it is | When you are here |
|---|---|---|
| **Packaging source tree** | Contains the `.spec` file, source tarballs, and patch files | Before setup and after cleanup |
| **Quilt environment** | Created by `quilt setup`; named `<name>-<version>-build/<name>-<version>/`; contains the unpacked sources, a `patches/` symlink, and a `.pc/` directory | During all `quilt` operations |

**Rule:** run `quilt setup` from the packaging source tree. After that, `cd`
into the quilt environment **once** and stay there for all subsequent `quilt`
commands. Never `cd` again mid-workflow. When finished, `cd ../..` back to the
packaging source tree for cleanup.

---

## Full backport workflow

### 1. Setup — run from the packaging source tree

```bash
# Back up the spec file before any modifications
cp <name>.spec <name>.spec.bac

# Initialise the quilt environment
quilt setup <name>.spec
```

If `quilt setup` fails, you may need to temporarily edit the spec file:
- Replace `%patchX` with `%patch X` (older RPM macro syntax)
- Comment out unknown `%macros`

After setup succeeds, **restore the original spec** from the backup:
```bash
cp <name>.spec.bac <name>.spec
```

Then identify the quilt environment directory that was created:
```bash
ls -d */   # look for <name>-<version>/
```

### 2. Enter the quilt environment — do this exactly once

```bash
cd <name>-<version>-build/<name>-<version>
```

All commands from this point until cleanup run from inside this directory.

### 3. Check existing patches

```bash
quilt series          # list all patches in order
quilt applied         # list already-applied patches
```

### 4. Apply all existing patches

```bash
quilt push -a
```

If a patch conflicts, see **Fixing a conflicted patch** below before continuing.

### 5. Add the new patch

```bash
# Create a new patch slot at the top of the stack
quilt new <patch-filename>

# Register every file the patch will touch
quilt add <file1>
quilt add <file2>   # repeat for each file

# Edit the files to apply your changes, then record them
quilt refresh
```

### 6. Verify the patch content

```bash
quilt diff            # review what was recorded
```

Read each hunk carefully. Because the patch originates from a newer version,
symbols, functions, types, or include paths may not exist in this older version.
Adapt as needed and run `quilt refresh` again after each correction.

### 7. Finish and return to the packaging source tree

```bash
quilt pop -a          # unapply all patches cleanly
cd ../..              # back to the packaging source tree
```

### 8. Clean up the quilt environment

```bash
rm -rf <name>-<version>-buid     # remove the quilt environment
rm -f <name>.spec.bac            # remove the spec backup if no longer needed
find . -name "*~" -delete        # remove editor backup files
```

---

## Fixing a conflicted patch

When `quilt push` stops with a conflict:

1. Back up the failing patch before anything else:
   ```bash
   cp patches/<failing-patch> patches/<failing-patch>.bac
   ```

2. Force-apply to see what succeeded and what did not:
   ```bash
   quilt push -f
   ```
   Good hunks are applied. Each conflicting file gets a `.rej` file containing
   the rejected hunks.

3. For each `.rej` file:
   - Read the original source file and the `.rej` to understand the intended change.
   - Edit the source file to apply the change manually.
   - Remove the `.rej` file when done.
   - If the conflict introduced changes to files not yet tracked, add them:
     ```bash
     quilt add <newly-changed-file>
     ```

4. Record the resolved state:
   ```bash
   quilt refresh
   ```
   **Warning:** this overwrites the original patch file. The `.bac` backup is
   your only copy of the original.

5. Continue applying the remaining patches:
   ```bash
   quilt push -a
   ```

---

## Reference — common quilt commands

| Command | Effect |
|---|---|
| `quilt series` | List all patches in series order |
| `quilt applied` | List applied patches |
| `quilt push` | Apply next patch |
| `quilt push -a` | Apply all remaining patches |
| `quilt push -f` | Force-apply (leave `.rej` for conflicts) |
| `quilt pop` | Unapply top patch |
| `quilt pop -a` | Unapply all patches |
| `quilt new <name>` | Create a new patch slot |
| `quilt add <file>` | Track a file under the current patch |
| `quilt refresh` | Save current changes into the current patch |
| `quilt diff` | Show uncommitted changes vs current patch |
