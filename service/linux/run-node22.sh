#!/usr/bin/env bash
set -euo pipefail

node_binary="${NODE22_BINARY:-/opt/synergy/toolchains/node22/bin/node}"
if [[ ! -x "$node_binary" ]]; then
  printf 'Node 22 binary is not executable at %s\n' "$node_binary" >&2
  exit 64
fi

node_version="$($node_binary --version)"
case "$node_version" in
  v22.*) ;;
  *)
    printf 'sxcp-staking-integration requires Node 22; found %s\n' "$node_version" >&2
    exit 64
    ;;
esac

exec "$node_binary" "$@"
