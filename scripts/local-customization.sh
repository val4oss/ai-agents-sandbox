#!/bin/sh
# local-customization.sh - Local user overlay helpers for ai-agents-sandbox.
#
# Sourced by ai-agents-sandbox.sh. Provides validation, detection and build
# functions for the .ai-agents-sandbox/ repo-local customization directory.
#
# Requires the following variables to be set by the caller:
#   USER_CFG_D         - Path to the local customization directory.
#   LOCAL_CONTAINERFILE - Path to the local Containerfile.
#   IMG_NAME           - Base container image name.
#   IMG_TAG            - Container image tag.
#   ACTION             - Current launcher action (build|run|...).
#   SUCCESS / FAILURE  - Return code constants.

# Return the file permission bits (octal) for a path, portably across Linux
# (stat -c) and macOS/BSD (stat -f).
_file_mode() {
    _path="$1"
    if stat -c '%a' "$_path" > /dev/null 2>&1; then
        stat -c '%a' "$_path"
        return 0
    fi
    if stat -f '%OLp' "$_path" > /dev/null 2>&1; then
        stat -f '%OLp' "$_path"
        return 0
    fi
    return 1
}

# Emit a warning for every non-executable file found in a hook directory.
_warn_non_executable_hooks() {
    _hook_dir="$1"
    [ -d "$_hook_dir" ] || return 0
    for _hook in "$_hook_dir"/*; do
        [ -f "$_hook" ] || continue
        [ -x "$_hook" ] && continue
        print_warning "Hook script is not executable: $_hook"
        print_warning "     -> Run 'chmod +x $_hook' to enable it."
    done
}

# Warn when the OpenCode local override file has insecure permissions.
_warn_insecure_opencode_override() {
    _override="${USER_CFG_D}/agents/opencode/config.local.override.json"
    [ -f "$_override" ] || return 0
    _mode="$(_file_mode "$_override" 2>/dev/null || true)"
    case "$_mode" in
        600|0600) ;;
        *)
            print_warning "Insecure OpenCode local override permissions: $_override"
            print_warning "     -> Use 'chmod 600 $_override'."
            ;;
    esac
}

# Run all local customization pre-flight checks. Called before run/build.
_validate_local_customization() {
    [ -d "$USER_CFG_D" ] || return 0

    _warn_non_executable_hooks "${USER_CFG_D}/entrypoint.pre.d"
    _warn_non_executable_hooks "${USER_CFG_D}/entrypoint.post.d"
    _warn_insecure_opencode_override

    if _local_overlay_enabled && ! _local_image_exists; then
        print_warning "Containerfile.local exists but local image is missing."
        if [ "$ACTION" = "build" ]; then
            print_warning "     -> Build will create '${IMG_NAME}-local:latest'."
        else
            print_warning \
                "     -> Run 'sh ai-agents-sandbox.sh build ${AGENT}'."
        fi
    fi
}

# Return 0 when a local Containerfile overlay is present.
_local_overlay_enabled() {
    [ -f "$LOCAL_CONTAINERFILE" ]
}

# Print the name of the local overlay image.
_local_image_name() {
    printf "%s-local" "$IMG_NAME"
}

# Return 0 when the local overlay image exists in the local podman store.
_local_image_exists() {
    podman image exists "$(_local_image_name):latest"
}

# Build the local overlay image on top of the base image.
_build_local_overlay() {
    _local_img_name="$(_local_image_name)"
    print_info \
        "Building local overlay image ${_local_img_name}:${IMG_TAG} ..."
    if ! podman build \
        --build-arg "BASE_IMAGE=${IMG_NAME}:${IMG_TAG}" \
        --tag "${_local_img_name}:${IMG_TAG}" \
        --tag "${_local_img_name}:latest" \
        --file "$LOCAL_CONTAINERFILE" \
        "$USER_CFG_D"; then
        print_error "Local overlay build failed."
        return "$FAILURE"
    fi
    print_info "Local overlay image built successfully."
    return "$SUCCESS"
}
