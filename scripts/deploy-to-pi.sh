#!/usr/bin/env bash
# Provision a Raspberry Pi from your laptop.
#
# Runs on your Mac/Linux host, SSHes into the Pi, optionally mounts the SSD,
# clones home-arr, generates .env, and runs the bootstrap script.
#
# Usage:
#   ./scripts/deploy-to-pi.sh                       # fully interactive
#   ./scripts/deploy-to-pi.sh <ssh-target>          # interactive disk picker
#   ./scripts/deploy-to-pi.sh --ssd-device /dev/sda1 --format <ssh-target>
#
# Options (skip the prompt for each one you pass):
#   --ssd-device DEV   Mount DEV at /mnt/media on the Pi
#   --format           Format DEV as ext4 first (DESTRUCTIVE)
#   --no-ssd           Don't mount an SSD (assume /mnt/media is already mounted)
#   --branch BRANCH    Clone a specific branch (default: main)
#   --repo URL         Override the repo URL (default: this fork)
#   --yes              Skip the final confirmation
#   -h, --help         Show this help

set -euo pipefail

REPO_URL="https://github.com/ninjawerk/home-arr.git"
BRANCH="main"
SSD_DEVICE=""
FORMAT_SSD=""
NO_SSD=""
TARGET=""
ASSUME_YES=""

usage() { sed -n '2,22p' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --ssd-device) SSD_DEVICE="$2"; shift 2 ;;
    --format)     FORMAT_SSD="true"; shift ;;
    --no-ssd)     NO_SSD="true"; shift ;;
    --branch)     BRANCH="$2"; shift 2 ;;
    --repo)       REPO_URL="$2"; shift 2 ;;
    --yes|-y)     ASSUME_YES="true"; shift ;;
    -h|--help)    usage 0 ;;
    -*)           echo "Unknown option: $1" >&2; usage 1 ;;
    *)            TARGET="$1"; shift ;;
  esac
done

# ---- Prompt: SSH target ----------------------------------------------------

if [ -z "$TARGET" ]; then
  read -rp "SSH target (e.g. pi@home-arr.local): " TARGET
  [ -n "$TARGET" ] || { echo "Target required." >&2; exit 1; }
fi

echo "==> Testing SSH connection to $TARGET"
ssh -o BatchMode=yes -o ConnectTimeout=5 "$TARGET" 'echo connected' >/dev/null || {
  echo "Couldn't SSH to $TARGET — make sure key-based auth works." >&2
  exit 1
}

# ---- Interactive disk picker -----------------------------------------------

pick_ssd_device() {
  echo
  echo "==> Block devices on $TARGET:"
  echo
  ssh "$TARGET" 'lsblk -p -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL' || true
  echo

  # Parse with lsblk -P (key=value pairs — safe with spaces, empty fields)
  local candidates=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    unset NAME SIZE TYPE FSTYPE MOUNTPOINT MODEL
    eval "$line"
    case "${MOUNTPOINT:-}" in
      /|/boot|/boot/firmware|[SWAP]) continue ;;
    esac
    case "${TYPE:-}" in
      disk|part) ;;
      *) continue ;;
    esac
    candidates+=("${NAME}|${SIZE}|${TYPE}|${FSTYPE:-—}|${MOUNTPOINT:-—}|${MODEL:-—}")
  done < <(ssh "$TARGET" 'lsblk -P -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL')

  if [ "${#candidates[@]}" -eq 0 ]; then
    echo "No candidate devices found. Plug in your SSD and re-run, or use --no-ssd."
    return 1
  fi

  echo "Candidates to mount at /mnt/media:"
  echo
  printf "  %3s  %-18s  %-7s  %-5s  %-7s  %-18s  %s\n" \
    "#" "DEVICE" "SIZE" "TYPE" "FS" "MOUNTED" "MODEL"
  local i=0
  for cand in "${candidates[@]}"; do
    i=$((i+1))
    IFS='|' read -r n s t f m mo <<<"$cand"
    printf "  %3d  %-18s  %-7s  %-5s  %-7s  %-18s  %s\n" "$i" "$n" "$s" "$t" "$f" "$m" "$mo"
  done
  printf "  %3d  %s\n" 0 "Skip — already mounted, or I'll handle it manually"
  echo

  local choice
  read -rp "Pick a device [0-$i]: " choice
  choice=${choice:-0}
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -gt "$i" ]; then
    echo "Invalid choice." >&2
    exit 1
  fi
  if [ "$choice" -eq 0 ]; then
    NO_SSD="true"
    return 0
  fi
  SSD_DEVICE=$(awk -F'|' '{print $1}' <<<"${candidates[$((choice-1))]}")
  local current_fs
  current_fs=$(awk -F'|' '{print $4}' <<<"${candidates[$((choice-1))]}")
  echo "Selected: $SSD_DEVICE (current FS: $current_fs)"

  local yn
  if [ "$current_fs" = "—" ]; then
    echo "$SSD_DEVICE has no filesystem — it must be formatted before mounting."
    read -rp "Format $SSD_DEVICE as ext4 now? [Y/n]: " yn
    yn=${yn:-y}
  else
    read -rp "Format $SSD_DEVICE as ext4? This ERASES all data on it. [y/N]: " yn
    yn=${yn:-n}
  fi
  [[ "$yn" =~ ^[Yy]$ ]] && FORMAT_SSD="true" || FORMAT_SSD="false"
}

if [ -z "$SSD_DEVICE" ] && [ -z "$NO_SSD" ]; then
  pick_ssd_device
fi

# If --ssd-device was passed without --format, ask
if [ -n "$SSD_DEVICE" ] && [ -z "$FORMAT_SSD" ]; then
  read -rp "Format $SSD_DEVICE as ext4? This ERASES all data on it. [y/N]: " yn
  [[ "${yn:-n}" =~ ^[Yy]$ ]] && FORMAT_SSD="true" || FORMAT_SSD="false"
fi

# ---- Confirmation -----------------------------------------------------------

cat <<EOF

About to provision:
  Target:       $TARGET
  Repo:         $REPO_URL ($BRANCH)
  SSD device:   ${SSD_DEVICE:-<none — /mnt/media must already be mounted>}
  Format SSD:   ${FORMAT_SSD:-false}

EOF

if [ -z "$ASSUME_YES" ]; then
  read -rp "Proceed? [y/N] " ans
  [[ "${ans:-n}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# ---- Remote provisioning ----------------------------------------------------

ssh "$TARGET" \
  REPO_URL="$REPO_URL" \
  BRANCH="$BRANCH" \
  SSD_DEVICE="$SSD_DEVICE" \
  FORMAT_SSD="${FORMAT_SSD:-false}" \
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
    echo "==> Formatting $SSD_DEVICE as ext4 (wipes the disk)"
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
echo "Provisioning finished. Open Homarr at:  http://${TARGET#*@}:7575"
