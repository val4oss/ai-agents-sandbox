#!/bin/sh
# Example pre-start hook: runs before normal provisioning.

set -eu

echo "[local-pre-hook] Running pre-provision checks" >&2
