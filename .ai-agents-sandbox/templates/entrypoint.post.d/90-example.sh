#!/bin/sh
# Example post-start hook: runs after normal provisioning.

set -eu

echo "[local-post-hook] Custom post-provision step completed" >&2
