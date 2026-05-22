#!/usr/bin/env bash
# One-shot bootstrap for a fresh Raspberry Pi OS Lite install.
# Installs Docker + Samba, wires up the SMB shares, seeds qBittorrent config,
# brings the stack up.
#
# Prereqs (do these BEFORE running):
#   1. Mount your SSD at /mnt/media (persistent — fstab entry)
#   2. Copy .env.example to .env and edit it
#   3. Run from the repo root: ./scripts/bootstrap-pi.sh

set -euo pipefail

# ---- Sanity checks --------------------------------------------------------

if [ "$EUID" -eq 0 ]; then
  echo "Don't run this as root — it'll sudo when it needs to." >&2
  exit 1
fi

if [ ! -f "docker-compose.yml" ] || [ ! -f ".env.example" ]; then
  echo "Run this from the repo root (where docker-compose.yml lives)." >&2
  exit 1
fi

if [ ! -f ".env" ]; then
  echo ".env missing — copy .env.example to .env and edit it first." >&2
  exit 1
fi

# Source MEDIA_ROOT etc. so we can validate them
set -a; . ./.env; set +a
: "${MEDIA_ROOT:?MEDIA_ROOT not set in .env}"
: "${PUID:?PUID not set in .env}"
: "${PGID:?PGID not set in .env}"

if [ ! -d "$MEDIA_ROOT" ]; then
  echo "MEDIA_ROOT=$MEDIA_ROOT does not exist. Mount your SSD there first." >&2
  exit 1
fi

if ! mountpoint -q "$MEDIA_ROOT"; then
  echo "Warning: $MEDIA_ROOT exists but isn't a mount point."
  echo "         You probably want your SSD mounted there before continuing."
  read -rp "Continue anyway? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || exit 1
fi

# ---- Packages -------------------------------------------------------------

echo "==> Updating apt + installing samba"
sudo apt-get update
sudo apt-get install -y samba

if ! command -v docker >/dev/null 2>&1; then
  echo "==> Installing Docker"
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$USER"
  echo "Added $USER to docker group — you'll need to log out + back in for it to take effect."
fi

# ---- Media directories ----------------------------------------------------

echo "==> Ensuring media directory layout at $MEDIA_ROOT"
sudo mkdir -p \
  "$MEDIA_ROOT/movies" \
  "$MEDIA_ROOT/tv" \
  "$MEDIA_ROOT/music" \
  "$MEDIA_ROOT/books" \
  "$MEDIA_ROOT/downloads/complete" \
  "$MEDIA_ROOT/downloads/incomplete"
sudo chown -R "$PUID:$PGID" "$MEDIA_ROOT"

# ---- Samba ---------------------------------------------------------------

echo "==> Installing Samba config"
if [ ! -f /etc/samba/smb.conf.home-arr-backup ] && [ -f /etc/samba/smb.conf ]; then
  sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.home-arr-backup
  echo "    Existing /etc/samba/smb.conf backed up to /etc/samba/smb.conf.home-arr-backup"
fi
sudo cp smb.conf.example /etc/samba/smb.conf
sudo systemctl enable --now smbd
sudo systemctl restart smbd

# ---- qBittorrent template -------------------------------------------------

echo "==> Seeding qBittorrent config (no-seed defaults)"
./scripts/init-qbittorrent.sh

# ---- Bring up the stack ---------------------------------------------------

echo "==> Pulling images + starting containers"
# Use sudo if the current shell isn't yet in the docker group
if id -nG "$USER" | grep -qw docker; then
  docker compose pull
  docker compose up -d
else
  sudo docker compose pull
  sudo docker compose up -d
fi

# ---- Done -----------------------------------------------------------------

ip=$(hostname -I | awk '{print $1}')
cat <<EOF

==========================================================================
Done. Open the services on this Pi (IP: $ip):

  Homarr (dashboard) http://$ip:7575
  Prowlarr           http://$ip:9696
  Sonarr             http://$ip:8989
  Radarr             http://$ip:7878
  Lidarr             http://$ip:8686
  Readarr            http://$ip:8787
  Bazarr             http://$ip:6767
  qBittorrent        http://$ip:8090
  FlareSolverr       http://$ip:8191

Samba shares (browse from Infuse / Finder / Explorer):
  smb://$ip/movies   smb://$ip/tv   smb://$ip/music   smb://$ip/books

First-time tips:
- qBittorrent's temp admin password is in: docker logs qbittorrent
- If you were just added to the docker group, log out + back in so future
  'docker' commands don't need sudo.
==========================================================================
EOF
