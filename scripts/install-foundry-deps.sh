#!/usr/bin/env bash
set -euo pipefail

# Native, deterministic dependency installation. Existing dependencies are checked,
# never overwritten or deleted.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
deps_root="$repo_root/lib"

install_exact() {
  local name="$1" remote="$2" revision="$3" target="$deps_root/$name"
  if [[ -d "$target/.git" ]]; then
    [[ "$(git -C "$target" rev-parse HEAD)" == "$revision" ]] || {
      echo "Refusing to replace $target: unexpected revision" >&2
      exit 1
    }
    return
  fi
  [[ ! -e "$target" ]] || { echo "Refusing to overwrite $target" >&2; exit 1; }
  git clone --filter=blob:none "$remote" "$target"
  git -C "$target" checkout --detach "$revision"
}

mkdir -p "$deps_root"
install_exact "openzeppelin-contracts" "https://github.com/OpenZeppelin/openzeppelin-contracts.git" "5fd1781b1454fd1ef8e722282f86f9293cacf256"
install_exact "forge-std" "https://github.com/foundry-rs/forge-std.git" "77041d2ce690e692d6e03cc812b57d1ddaa4d505"
echo "Foundry dependencies are installed at the pinned Solidity 0.8.36/OZ 5.6.1 revisions."
