#!/usr/bin/env bash
# Local setup for running home-arr on macOS (Docker Desktop or OrbStack).
#
# What it does:
#   1. Verifies Docker is available (offers to install Docker Desktop via brew)
#   2. Prompts for / validates MEDIA_ROOT (default: ~/Media)
#   3. Creates the movies/tv/music/books/downloads layout
#   4. Auto-generates .env
#   5. Seeds qBittorrent's no-seed config
#   6. docker compose pull + up -d
#   7. Optionally enables macOS native SMB sharing for the media folders
#
# Usage:
#   ./scripts/setup-macos.sh
#   ./scripts/setup-macos.sh --media-root /Volumes/MediaSSD
#   ./scripts/setup-macos.sh --media-root ~/Media --no-smb

set -euo pipefail

cd "$(dirname "$0")/.."

MEDIA_ROOT="$HOME/Media"
ENABLE_SMB=""
ASSUME_YES=""

usage() {
  cat <<USAGE
Usage: $0 [options]
  --media-root DIR   Where media lives (default: ~/Media)
  --smb              Set up native macOS SMB shares for the media folders
  --no-smb           Skip SMB setup entirely
  --yes, -y          Skip confirmation prompts
  -h, --help         This help
USAGE
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --media-root) MEDIA_ROOT="$2"; shift 2 ;;
    --smb)        ENABLE_SMB="true"; shift ;;
    --no-smb)     ENABLE_SMB="false"; shift ;;
    --yes|-y)     ASSUME_YES="true"; shift ;;
    -h|--help)    usage 0 ;;
    *)            echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

# Expand ~ in MEDIA_ROOT if passed via flag
MEDIA_ROOT="${MEDIA_ROOT/#\~/$HOME}"

# ---- macOS check -----------------------------------------------------------

if [ "$(uname)" != "Darwin" ]; then
  echo "This script is for macOS. On a Pi, use scripts/deploy-to-pi.sh." >&2
  exit 1
fi

# ---- Docker check ----------------------------------------------------------

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is not installed."
  if command -v brew >/dev/null 2>&1; then
    read -rp "Install Docker Desktop via Homebrew now? [Y/n] " ans
    ans=${ans:-y}
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      brew install --cask docker
      echo
      echo "Docker Desktop installed. Open it once from /Applications/Docker.app"
      echo "to finish setup, then re-run this script."
      exit 0
    fi
  else
    echo "Install Homebrew (https://brew.sh) then run: brew install --cask docker"
  fi
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Docker is installed but the daemon isn't running."
  echo "Open Docker Desktop (or run 'colima start' / 'orbctl start') and re-run."
  exit 1
fi

# ---- Confirm settings ------------------------------------------------------

cat <<EOF

home-arr macOS setup:
  Media root:   $MEDIA_ROOT
  SMB sharing:  ${ENABLE_SMB:-ask}

EOF

if [ -z "$ASSUME_YES" ]; then
  read -rp "Proceed? [Y/n] " ans
  ans=${ans:-y}
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# ---- Media directory layout -----------------------------------------------

echo "==> Creating media layout at $MEDIA_ROOT"
mkdir -p \
  "$MEDIA_ROOT/movies" \
  "$MEDIA_ROOT/tv" \
  "$MEDIA_ROOT/music" \
  "$MEDIA_ROOT/books" \
  "$MEDIA_ROOT/downloads/complete" \
  "$MEDIA_ROOT/downloads/incomplete"

# ---- .env ----------------------------------------------------------------

if [ ! -f .env ]; then
  echo "==> Generating .env"
  MEDIA_ROOT="$MEDIA_ROOT" ./scripts/setup-env.sh
else
  # Make sure MEDIA_ROOT in existing .env matches what user asked for
  if ! grep -q "^MEDIA_ROOT=$MEDIA_ROOT$" .env; then
    echo "==> Updating MEDIA_ROOT in existing .env"
    sed -i.bak "s|^MEDIA_ROOT=.*|MEDIA_ROOT=$MEDIA_ROOT|" .env && rm -f .env.bak
  fi
fi

# ---- qBittorrent template -------------------------------------------------

echo "==> Seeding qBittorrent config (no-seed defaults)"
./scripts/init-qbittorrent.sh

# ---- Bring up the stack ----------------------------------------------------

echo "==> Pulling images"
docker compose pull

echo "==> Starting containers"
docker compose up -d

# ---- macOS SMB sharing ----------------------------------------------------

setup_smb() {
  echo "==> Configuring macOS native SMB sharing (requires sudo)"
  # Enable smbd if it isn't already running
  if ! sudo launchctl list | grep -q com.apple.smbd; then
    sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.smbd.plist 2>/dev/null || true
  fi

  for sub in movies tv music books; do
    name="$sub"
    path="$MEDIA_ROOT/$sub"
    if sharing -l 2>/dev/null | grep -q "name:[[:space:]]*$name"; then
      echo "    SMB share '$name' already exists — skipping"
      continue
    fi
    sudo sharing -a "$path" -S "$name" -s 001 >/dev/null
    echo "    Added SMB share: smb://$(hostname -s).local/$name → $path"
  done

  echo
  echo "    SMB sharing is set up but the master toggle is in System Settings."
  echo "    If clients can't see the shares: System Settings → General →"
  echo "    Sharing → toggle 'File Sharing' on."
}

if [ -z "$ENABLE_SMB" ]; then
  echo
  read -rp "Set up native macOS SMB shares so Infuse can read $MEDIA_ROOT? [Y/n] " ans
  ans=${ans:-y}
  [[ "$ans" =~ ^[Yy]$ ]] && ENABLE_SMB="true" || ENABLE_SMB="false"
fi

if [ "$ENABLE_SMB" = "true" ]; then
  setup_smb
fi

# ---- Done -----------------------------------------------------------------

host=$(hostname -s).local
ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "<your-mac-ip>")

cat <<EOF

==========================================================================
home-arr is up on this Mac.

Services:
  Homarr (dashboard) http://localhost:7575
  Prowlarr           http://localhost:9696
  Sonarr             http://localhost:8989
  Radarr             http://localhost:7878
  Lidarr             http://localhost:8686
  Readarr            http://localhost:8787
  Bazarr             http://localhost:6767
  qBittorrent        http://localhost:8090
  FlareSolverr       http://localhost:8191

EOF

if [ "$ENABLE_SMB" = "true" ]; then
  cat <<EOF
SMB shares (point Infuse / VLC / Kodi here):
  smb://$host/movies   (or smb://$ip/movies)
  smb://$host/tv
  smb://$host/music
  smb://$host/books

EOF
fi

cat <<EOF
Inside each *arr app, root folders are:
  Radarr  → /movies
  Sonarr  → /tv
  Lidarr  → /music
  Readarr → /books
Downloads volume in qBittorrent: /downloads

qBittorrent first-login password: docker logs qbittorrent | grep -i password
==========================================================================
EOF
