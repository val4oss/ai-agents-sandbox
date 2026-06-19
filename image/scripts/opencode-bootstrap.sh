#!/bin/sh
# opencode-bootstrap.sh - render OpenCode config from base and local overlays.

set -eu

LOCAL_IMAGE_D="/usr/share/ai-sandbox/local"
LOCAL_HOST_D="/usr/share/ai-sandbox/local-host"

expand_file_env_refs() {
    _src="$1"
    _dst="$2"

    awk '
        {
            out = $0
            while (match(out, /\$\{[A-Za-z_][A-Za-z0-9_]*\}/)) {
                key = substr(out, RSTART + 2, RLENGTH - 3)
                rep = ENVIRON[key]
                out = substr(out, 1, RSTART - 1) \
                    rep substr(out, RSTART + RLENGTH)
            }
            print out
        }
    ' "$_src" > "$_dst"
}

pick_override_file() {
    _opencode_dir="$1"

    if [ -n "${OPENCODE_CONFIG_OVERRIDE_FILE:-}" ]; then
        printf "%s" "$OPENCODE_CONFIG_OVERRIDE_FILE"
        return 0
    fi

    for _candidate in \
        "${LOCAL_HOST_D}/agents/opencode/config.local.override.json" \
        "${LOCAL_IMAGE_D}/agents/opencode/config.local.override.json" \
        "${_opencode_dir}/config.local.override.json"; do
        if [ -f "$_candidate" ]; then
            printf "%s" "$_candidate"
            return 0
        fi
    done

    return 1
}

apply_local_override() {
    _base_cfg="$1"
    _override_cfg="$2"

    [ -f "$_override_cfg" ] || return 0

    _mode="$(stat -c '%a' "$_override_cfg" 2>/dev/null || true)"
    case "$_mode" in
        600|0600) ;;
        *)
            echo "[opencode-bootstrap] Ignoring override with insecure permissions: $_override_cfg" >&2
            return 0
            ;;
    esac

    if ! jq -e 'type == "object"' "$_override_cfg" >/dev/null 2>&1; then
        echo "[opencode-bootstrap] Ignoring invalid override file: $_override_cfg" >&2
        echo "[opencode-bootstrap] Override must be a JSON object." >&2
        return 0
    fi

    _merged_cfg="${_base_cfg}.merged"
    jq -s '.[0] * .[1]' "$_base_cfg" "$_override_cfg" > "$_merged_cfg"
    mv "$_merged_cfg" "$_base_cfg"
}

normalize_ollama_base_url() {
    if [ -n "${OPENCODE_OLLAMA_BASE_URL:-}" ]; then
        _oc_ollama="$OPENCODE_OLLAMA_BASE_URL"
        _oc_ollama_src="base_url"
    elif [ -n "${OLLAMA_HOST:-}" ]; then
        _oc_ollama="$OLLAMA_HOST"
        _oc_ollama_src="ollama_host"
    else
        _oc_ollama="http://127.0.0.1:11434/v1"
        _oc_ollama_src="default"
    fi

    case "$_oc_ollama" in
        http://*|https://*) ;;
        *) _oc_ollama="http://${_oc_ollama}" ;;
    esac

    case "$_oc_ollama_src" in
        ollama_host|default)
            _oc_ollama="${_oc_ollama%/}/v1"
            ;;
    esac

    export OPENCODE_OLLAMA_BASE_URL="$_oc_ollama"
}

_opencode_dir="${HOME}/.config/opencode"
_template="/usr/share/ai-sandbox/skel/opencode/config.template.json"
_cfg="${_opencode_dir}/config.json"
_legacy_cfg="${_opencode_dir}/opencode.json"

mkdir -p "$_opencode_dir"

normalize_ollama_base_url
export VERTEX_LOCATION="${VERTEX_LOCATION:-global}"

if [ -f "$_template" ]; then
    expand_file_env_refs "$_template" "$_cfg"
    if _override_cfg="$(pick_override_file "$_opencode_dir")"; then
        apply_local_override "$_cfg" "$_override_cfg"
    fi
    cp "$_cfg" "$_legacy_cfg" 2>/dev/null || true
fi