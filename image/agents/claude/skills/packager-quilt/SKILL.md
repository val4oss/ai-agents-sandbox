---
name: Quilt tool for packager
description: Use the tool `quilt` to manage patches in a packaging source tree.
when_to_use: if working with patches in a packaging source tree.
allowed-tools: Bash(quilt *), Bash(cd *), Bash(cp *), Read, Write
model: sonnet
---

## Setting up patches

1. Need to be in a packaging RPM source tree with a tarball and a spec file.
2. run `quilt setup <spec file>` to initialize the quilt environment.

  * If the command fails, you may need to edit the specfile. Always store a
    backup of the specfile before with a cp. For example, for specfile with
    older RPM versions, patches are applied in the %prep section with `%patchX`
    instead of `%patch X`. Or if an unknown `%macro` is used, you may need to
    comment.
  * If the specfile has been adapted to setup, you have to revert the changes to
    not have a modified specfile after the setup. Restore it with the 
    backuped file created.

3. Go to the `quilt` directory created by the setup command. This is where the
   project sources, and the patches will be managed. 

## Managing patches

* To list the patches, run `quilt series`.
* To apply patches, run `quilt push` to apply the next patch in the series or
  `quilt push -a` to apply all patches.
* To unapply patches, run `quilt pop` to unapply the last applied patch or
  `quilt pop -a` to unapply all patches.

## Adding new patches

1. To add a new patch, run `quilt new <patch name>` to create a new patch file.
2. To add files to the patch, run `quilt add <file>` for each file you want to
   include in the patch.
3. Make the necessary changes to the files.
4. To refresh the patch with the changes, run `quilt refresh`.

## Fix a conflicted patch

At `quilt push`, a patch may fail to apply due to conflicts. In this case, you
need to resolve the conflicts manually.

1. Backup the patch file that failed to apply. By creating a copy of the patch
    file wsuffixed with '.bac', in the packaging source tree.
2. Run `quilt push -f` to force the application of the patch, where good hunks
   will applied. For conflicted hunks, the original file will remains without
   changes, and a `.rej` file will be created for each conflicted file. The
   `.rej` file contains the rejected hunks of the patch.
3. Edit the original file to resolve the conflicts by checking what was not
   applied from the `.rej`, and remove the `.rej` file.
   If new files are changed, use `quilt add <file>` to add them to the patch.
4. Run `quilt refresh` to update the patch with the resolved changes.
   CAREFUL: after the refresh, the original patch file will be overwritten.

## Cleaning up

1. Run `quilt pop -a` to unapply all patches.
2. Go back to the packaging source tree and delete the `quilt` directory created
   by the setup command.
3. Delete nested files like the backuped specfile or any files remaining in the
   editing state (ending by ~).

