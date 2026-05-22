#!/usr/bin/env bash
# Seed the qBittorrent config with no-seed defaults before the container's first start.
# Idempotent: does nothing if the live config file already exists.

set -euo pipefail

cd "$(dirname "$0")/.."

src="templates/qbittorrent/qBittorrent.conf"
target_dir="config/qbittorrent/qBittorrent"
target="$target_dir/qBittorrent.conf"

if [ -e "$target" ]; then
  echo "qBittorrent config already exists at $target"
  echo "Not overwriting. Stop the container and delete that file if you want a reset."
  exit 0
fi

mkdir -p "$target_dir"
cp "$src" "$target"
echo "Wrote $target with share-limit values set to 0 (torrent removed on completion, files preserved)."
echo "On first WebUI login, check the qbittorrent container logs for the temporary admin password."
