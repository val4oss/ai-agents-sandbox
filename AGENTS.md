# Project: ai-agents-sandbox

Shell project to:

1. build pre-configured container image based on openSUSE Tumbleweed
2. Run a secure, isolated environment for running AI coding agents
   (GitHub Copilot, Gemini CLI, Claude Code, opencode, hermes-agent), using rootless container with
   **podman** and microvm with **krun**.
3. Provide a simple interface to use the environment, with a focus on security
   and ease of use for non-technical users.

## Coding Style

* scripts adhere to the POSIX standard, using `shellcheck` to verify.
* Maximum of 80 chars per lines.
* shell function described by one comment line on top.
* function name in **snake_case**.
* internal functions/variables begins by "_".
  * `_local_var=value`, `_internal_function() {}`.
* No tabs, 4 spaces.

## commands

* `shellcheck -x <file.sh>`: verify shell scripts
* `sh ai-agents-sandbox build <agent_name>`: Build the image
* `sh ai-agents-sandbox run <agent_name>`: Run the agent environment
* `sh ai-agents-sandbox clean`: Clean container state

## Architecture

* `image/`: Root of file used to create the container image with `podman build`.
* `image/agents/<agent_name>/`: Store sub-agents configuration in markdown.
* `image/scripts/`: Regroup scripts to use during the image build.
* `image/skel/`: Files copied in the container rootfs.
* `image/.krun_vm.json`: Configuration file for the microvm.
* `image/Containerfile`: Containerfile used to build the image.
* `sandbox/`: Volume mounted in the HOME directory of the container. Used to 
    store authentication tokens, sources code for development.
* `ai-agents-sandbox.sh`: Main script to build and run the container.
* `printer.sh`: Utility script to print colored messages in the terminal.

## Important Notes

* Read the @README.md for details, especially the "Security" section.
* Always focus on these goals at this order:

  1. Generate a full securized, isolated environment, foolproof against all
      host data exploits.
  2. Be easy to use, should be adapted for no-technical person.
  3. Should not slowdown developer productivity.
