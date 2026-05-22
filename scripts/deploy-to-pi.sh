#!/usr/bin/env bash
# Provision a Raspberry Pi from your laptop.
#
# Runs on your Mac/Linux host, SSHes into the Pi, mounts the SSD (optional),
# clones home-arr, generates .env, and runs the bootstrap script.
#
# Usage:
#   ./scripts/deploy-to-pi.sh [options] <ssh-target>
#
# Examples:
#   ./scripts/deploy-to-pi.sh pi@home-arr.local
#   ./scripts/deploy-to-pi.sh --ssd-device /dev/sda1 pi@home-arr.local
#   ./scripts/deploy-to-pi.sh --ssd-device /dev/sda1 --format pi@home-arr.local
#
# Options:
#   --ssd-device DEV   Mount DEV at /mnt/media on the Pi (e.g. /dev/sda1)
#   --format           Format DEV as ext4 first (DESTRUCTIVE, wipes the disk)
#   --branch BRANCH    Clone a specific branch (default: main)
#   --repo URL         Override the repo URL (default: this fork)
#   -h, --help         Show this help

set -euo pipefail

REPO_URL="https://github.com/ninjawerk/home-arr.git"
BRANCH="main"
SSD_DEVICE=""
FORMAT_SSD="false"
TARGET=""

usage() { sed -n '2,21p' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --ssd-device) SSD_DEVICE="$2"; shift 2 ;;
    --format)     FORMAT_SSD="true"; shift ;;
    --branch)     BRANCH="$2"; shift 2 ;;
    --repo)       REPO_URL="$2"; shift 2 ;;
    -h|--help)    usage 0 ;;
    -*)           echo "Unknown option: $1" >&2; usage 1 ;;
    *)            TARGET="$1"; shift ;;
  esac
done

[ -n "$TARGET" ] || { echo "Missing <ssh-target>" >&2; usage 1; }

echo "==> Testing SSH connection to $TARGET"
ssh -o BatchMode=yes -o ConnectTimeout=5 "$TARGET" 'echo connected' >/dev/null || {
  echo "Couldn't SSH to $TARGET — make sure key-based auth works." >&2
  exit 1
}

# ---- Confirmation -----------------------------------------------------------

cat <<EOF

About to provision: $TARGET
  Repo:        $REPO_URL ($BRANCH)
  SSD device:  ${SSD_DEVICE:-<none — assumes /mnt/media is already mounted>}
  Format SSD:  $FORMAT_SSD

EOF
read -rp "Proceed? [y/N] " ans
[[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ---- Remote provisioning ----------------------------------------------------

# Pass variables to the remote shell via env vars so we don't have to escape
# anything inside the heredoc.
ssh "$TARGET" \
  REPO_URL="$REPO_URL" \
  BRANCH="$BRANCH" \
  SSD_DEVICE="$SSD_DEVICE" \
  FORMAT_SSD="$FORMAT_SSD" \
  'bash -s' <<'REMOTE'
set -euo pipefail

echo "==> Updating apt + installing prerequisites"
sudo apt-get update -qq
sudo apt-get install -y -qq git curl ca-certificates

# ---- SSD mount ------------------------------------------------------------

if [ -n "$SSD_DEVICE" ]; then
  if [ ! -b "$SSD_DEVICE" ]; then
    echo "Device $SSD_DEVICE not found on Pi. Available:"
    lsblk
    exit 1
  fi

  if [ "$FORMAT_SSD" = "true" ]; then
    echo "==> Formatting $SSD_DEVICE as ext4 (this wipes it)"
    sudo umount "$SSD_DEVICE" 2>/dev/null || true
    sudo mkfs.ext4 -F "$SSD_DEVICE"
  fi

  uuid=$(sudo blkid -s UUID -o value "$SSD_DEVICE")
  [ -n "$uuid" ] || { echo "Couldn't read UUID of $SSD_DEVICE"; exit 1; }
  fstype=$(sudo blkid -s TYPE -o value "$SSD_DEVICE")

  sudo mkdir -p /mnt/media
  if ! grep -q "UUID=$uuid" /etc/fstab; then
    echo "==> Adding /mnt/media to /etc/fstab"
    echo "UUID=$uuid /mnt/media $fstype defaults,nofail 0 2" | sudo tee -a /etc/fstab >/dev/null
  fi

  if ! mountpoint -q /mnt/media; then
    sudo mount /mnt/media
  fi
  echo "==> /mnt/media is mounted: $(df -h /mnt/media | tail -1)"
fi

if ! mountpoint -q /mnt/media; then
  echo "ERROR: /mnt/media is not a mount point. Pass --ssd-device or mount manually." >&2
  exit 1
fi

# ---- Clone repo -----------------------------------------------------------

REPO_DIR="$HOME/home-arr"
if [ -d "$REPO_DIR/.git" ]; then
  echo "==> Updating existing clone at $REPO_DIR"
  git -C "$REPO_DIR" fetch --quiet origin
  git -C "$REPO_DIR" checkout "$BRANCH"
  git -C "$REPO_DIR" pull --ff-only --quiet
else
  echo "==> Cloning $REPO_URL ($BRANCH) → $REPO_DIR"
  git clone --branch "$BRANCH" --quiet "$REPO_URL" "$REPO_DIR"
fi

cd "$REPO_DIR"

# ---- Auto-generate .env ----------------------------------------------------

if [ ! -f .env ]; then
  ./scripts/setup-env.sh
fi

# ---- Hand off to bootstrap-pi --------------------------------------------

./scripts/bootstrap-pi.sh
REMOTE

echo
echo "Provisioning finished. Open Homarr at:  http://$TARGET:7575"
echo "(Replace the user@ part of the hostname above if needed.)"
