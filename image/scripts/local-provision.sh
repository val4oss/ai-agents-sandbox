#!/bin/sh
# local-provision.sh - Local overlay provisioning helpers for entrypoint.sh.
#
# Sourced by entrypoint.sh. Provides functions to provision agent config files
# from the base skel directory and from any local overlay directories
# (image-baked or host-mounted).
#
# Requires the following variables to be set by the caller:
#   SKEL_D         - Path to /usr/share/ai-sandbox
#   LOCAL_IMAGE_D  - Path to image-baked local overlay root
#   LOCAL_HOST_D   - Path to host-mounted local overlay root

# Copy base agent files (non-destructive: skips existing files).
provision_agents() {
    _agent_name="$1"
    _target_dir="$2"
    _src_dir="${SKEL_D}/agents/${_agent_name}"
    if [ -d "$_src_dir" ]; then
        mkdir -p "$_target_dir"
        for f in "$_src_dir"/*; do
            [ -f "$f" ] || continue
            cp -n "$f" "$_target_dir/" 2>/dev/null || true
        done
    fi
}

# Copy overlay agent files from a given overlay root (additive, overwrites).
provision_overlay_agents() {
    _overlay_root="$1"
    _agent_name="$2"
    _target_dir="$3"
    _src_dir="${_overlay_root}/agents/${_agent_name}"
    if [ -d "$_src_dir" ]; then
        mkdir -p "$_target_dir"
        cp -R "$_src_dir"/. "$_target_dir"/ 2>/dev/null || true
    fi
}

# Apply local overrides from both image-baked and host-mounted overlay roots.
provision_local_agents() {
    _agent_name="$1"
    _target_dir="$2"
    provision_overlay_agents "$LOCAL_IMAGE_D" "$_agent_name" "$_target_dir"
    provision_overlay_agents "$LOCAL_HOST_D" "$_agent_name" "$_target_dir"
}

# Execute every executable file in a hook directory, in lexical order.
# Stops on first non-zero exit.
run_hook_dir() {
    _hook_dir="$1"
    [ -d "$_hook_dir" ] || return 0

    for _hook in "$_hook_dir"/*; do
        [ -f "$_hook" ] || continue
        [ -x "$_hook" ] || continue
        "$_hook"
    done
}
