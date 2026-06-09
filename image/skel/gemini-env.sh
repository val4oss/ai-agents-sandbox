#!/bin/sh
# shellcheck shell=sh
# Prefer GOOGLE_CLOUD_PROJECT from ~/.gemini/.env when running gemini.

gemini_with_project_env() {
    _gemini_env_file="$HOME/.gemini/.env"
    _gemini_project="${GOOGLE_CLOUD_PROJECT:-}"

    if [ -f "$_gemini_env_file" ]; then
        _gemini_line=$(grep -E \
            '^[[:space:]]*GOOGLE_CLOUD_PROJECT[[:space:]]*=' \
            "$_gemini_env_file" | tail -n 1)
        if [ -n "$_gemini_line" ]; then
            _gemini_project=${_gemini_line#*=}
            _gemini_project=$(printf '%s' "$_gemini_project" | sed \
                's/^[[:space:]]*//; s/[[:space:]]*$//')
            _gemini_project=$(printf '%s' "$_gemini_project" | sed \
                "s/^[\"']*//; s/[\"']*$//")
        fi
    fi

    if [ -n "$_gemini_project" ]; then
        GOOGLE_CLOUD_PROJECT="$_gemini_project" command gemini "$@"
    else
        command gemini "$@"
    fi
}

alias gemini="gemini_with_project_env"
