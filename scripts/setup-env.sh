#!/usr/bin/env bash
# Auto-generate a sensible .env. Runs on the Pi (or anywhere with the repo).
# Idempotent: refuses to overwrite an existing .env.

set -euo pipefail
cd "$(dirname "$0")/.."

if [ -f .env ]; then
  echo ".env already exists — leaving it alone."
  exit 0
fi

puid=$(id -u)
pgid=$(id -g)

# Best-effort timezone detection
if command -v timedatectl >/dev/null 2>&1; then
  tz=$(timedatectl show --property=Timezone --value 2>/dev/null || true)
fi
if [ -z "${tz:-}" ] && [ -f /etc/timezone ]; then
  tz=$(cat /etc/timezone)
fi
tz=${tz:-UTC}

# 64-char hex secret for Homarr — openssl preferred, urandom fallback
if command -v openssl >/dev/null 2>&1; then
  homarr_secret=$(openssl rand -hex 32)
else
  homarr_secret=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
fi

media_root=${MEDIA_ROOT:-/mnt/media}

cat > .env <<EOF
PUID=$puid
PGID=$pgid
TZ=$tz
MEDIA_ROOT=$media_root
HOMARR_SECRET=$homarr_secret
EOF

echo "Wrote .env:"
echo "  PUID=$puid  PGID=$pgid"
echo "  TZ=$tz"
echo "  MEDIA_ROOT=$media_root"
echo "  HOMARR_SECRET=<generated>"
