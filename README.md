# home-arr

Self-hosted media stack for a Raspberry Pi: the *arr suite in Docker plus Samba on the host. Queue movies and TV from your phone, watch them from your TV's Infuse app.

## What's in here

| Service      | Port | Purpose                                       |
|--------------|------|-----------------------------------------------|
| Prowlarr     | 9696 | Indexer manager — feeds Sonarr/Radarr         |
| Sonarr       | 8989 | TV show automation                            |
| Radarr       | 7878 | Movie automation                              |
| Lidarr       | 8686 | Music automation                              |
| Readarr      | 8787 | Book / audiobook automation                   |
| Bazarr       | 6767 | Subtitles for Sonarr/Radarr libraries         |
| qBittorrent  | 8090 | Download client                               |
| FlareSolverr | 8191 | Bypasses Cloudflare for some indexers         |
| Homarr       | 7575 | Dashboard — single landing page for the stack |
| Recyclarr    | —    | Syncs TRaSH-Guides quality profiles into *arr |

Samba runs on the host (not in Docker) and shares `movies/` and `tv/` read-only so any device with an SMB client can stream from them.

## Architecture

```
Phone (LunaSea / nzb360) ──HTTP+API key──► Sonarr/Radarr ──► qBittorrent
                                                                  │
                                                                  ▼
                                                       /mnt/media/downloads
                                                                  │
                                                                  ▼ (Sonarr/Radarr import)
                                                       /mnt/media/{movies,tv}
                                                                  │
                                                                  ▼ (Samba share)
                                            Apple TV / Infuse, VLC, Kodi, etc.
```

## Hardware

- Raspberry Pi 4 or 5 (8GB recommended for headroom)
- **USB 3 SSD or NVMe HAT** for media + config — do not run this off the SD card. SD cards are too slow for *arr's constant small writes and will wear out.
- Wired ethernet to the router (Wi-Fi works but ethernet is more reliable for streaming)

## Setup

There are two paths. **Remote deploy** is recommended — you run one script on your laptop and it provisions the Pi end to end.

### Path A — Remote deploy from your laptop (recommended)

**1. Flash Raspberry Pi OS Lite**

Use [Raspberry Pi Imager](https://www.raspberrypi.com/software/), pick **Pi OS Lite (64-bit)**, and open advanced options (`Cmd-Shift-X`):
- **Hostname:** `home-arr`
- **Enable SSH** → use public key, paste in your `~/.ssh/id_*.pub`
- **Username + password** for the default user
- **Wi-Fi** (or leave blank for ethernet — recommended)
- **Locale + timezone**

Flash, boot the Pi, plug in the USB SSD.

**2. Clone this repo on your laptop**

```bash
git clone https://github.com/ninjawerk/home-arr.git
cd home-arr
```

**3. Run the deploy script**

```bash
# If the SSD is already mounted at /mnt/media on the Pi:
./scripts/deploy-to-pi.sh <user>@home-arr.local

# Or let the script format + mount it for you:
./scripts/deploy-to-pi.sh --ssd-device /dev/sda1 --format <user>@home-arr.local

# Or mount an already-formatted SSD without erasing it:
./scripts/deploy-to-pi.sh --ssd-device /dev/sda1 <user>@home-arr.local
```

The script SSHes into the Pi, installs Docker + Samba, mounts the SSD (if requested), clones this repo to `~/home-arr` on the Pi, auto-generates `.env` (PUID, PGID, TZ, Homarr secret), seeds the no-seed qBittorrent config, and brings up the whole stack. At the end it prints every service URL.

Re-runnable safely — re-running on the same Pi just pulls the latest repo and `docker compose up -d` again.

---

### Path B — Manual install on the Pi

If you'd rather SSH in and run things by hand:

**1. Flash Raspberry Pi OS Lite**

1. Download [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
2. Pick: **Raspberry Pi OS Lite (64-bit)**
3. Open advanced options (`Cmd-Shift-X` on macOS, `Ctrl-Shift-X` on Linux/Windows):
   - **Set hostname:** `home-arr`
   - **Enable SSH** → use public key, paste in your `~/.ssh/id_*.pub`
   - **Set username and password** for the default user
   - **Configure Wi-Fi** (or leave blank if using ethernet — recommended)
   - **Set locale** to your timezone
4. Flash to the SD card, boot the Pi, find its IP from your router and:
   ```bash
   ssh <user>@home-arr.local   # or @<ip>
   ```

### 2. Mount the SSD at `/mnt/media`

Plug in the USB 3 SSD (or NVMe via HAT). Then:

```bash
# Find the device name (look for sda1 or nvme0n1p1)
lsblk

# Get the UUID
sudo blkid /dev/sda1

# Persistent mount (replace UUID + filesystem type as needed)
echo 'UUID=<your-uuid> /mnt/media ext4 defaults,nofail 0 2' | sudo tee -a /etc/fstab
sudo mkdir -p /mnt/media
sudo mount -a

# Confirm
mountpoint /mnt/media   # should print "/mnt/media is a mountpoint"
```

> **SSD not yet formatted?** `sudo mkfs.ext4 /dev/sda1` first (this erases the disk).

### 3. Clone + configure

```bash
git clone https://github.com/ninjawerk/home-arr.git
cd home-arr
cp .env.example .env
nano .env
# Set: PUID/PGID (run `id`), TZ, MEDIA_ROOT, HOMARR_SECRET
# Generate the Homarr secret with: openssl rand -hex 32
```

### 4. Run the bootstrap script

One command installs Docker + Samba, wires up shares, seeds qBittorrent's no-seed config, and brings the whole stack up:

```bash
./scripts/bootstrap-pi.sh
```

At the end it prints the URLs for every service and the IP + SMB share paths. The first time you run it you'll be added to the `docker` group — log out and back in once before running future `docker` commands without sudo.

Each service has a web UI on its port. First-run config:
1. **Prowlarr** (`:9696`) — add indexers, then link Sonarr + Radarr from Settings → Apps
2. **qBittorrent** (`:8090`) — default login is `admin` / check container logs for temp password
3. **Sonarr** (`:8989`) / **Radarr** (`:7878`) — add qBittorrent as download client, set root folder to `/tv` or `/movies`

The [TRaSH Guides](https://trash-guides.info/) are the gold standard for *arr configuration — quality profiles, naming, indexers, the lot.

### qBittorrent: don't seed after completion

This stack is set up to grab, not to seed. The `scripts/init-qbittorrent.sh` script (run during setup) copies `templates/qbittorrent/qBittorrent.conf` into place before the container's first start, which sets:

| Setting | Value | Effect |
|---|---|---|
| `Session\GlobalMaxRatio` | `0` | Stop seeding the moment a torrent finishes |
| `Session\GlobalMaxSeedingMinutes` | `0` | Same, but on time basis |
| `Session\MaxRatioAction` | `1` | Remove torrent from qBit (files stay on disk for *arr to import) |
| `Session\DefaultSavePath` | `/downloads/` | Where completed downloads live |
| `Session\TempPath` | `/downloads/incomplete/` | Where in-progress downloads live |

No need to touch the UI after first launch — it's already configured.

If you want to change these later, stop the container, edit `config/qbittorrent/qBittorrent/qBittorrent.conf` directly (or use the WebUI while running), then bring it back up. qBit will overwrite the file on graceful shutdown, so direct edits must happen while the container is stopped.

**Important caveat:** if you ever join a **private tracker**, this config will get you banned — private trackers require seeding. Create a separate qBittorrent category in the UI with normal share limits and route private-tracker grabs to that category in Sonarr/Radarr.

### Recyclarr — quality profiles from TRaSH

Recyclarr is a one-shot CLI that pulls TRaSH-Guides profiles into Sonarr/Radarr. After the *arr apps are up:

```bash
# Generate a starter config
docker compose run --rm recyclarr config create

# Edit ./config/recyclarr/recyclarr.yml — paste in Sonarr/Radarr URLs + API keys
# Then run a sync:
docker compose run --rm recyclarr sync
```

To run it automatically, add a host crontab entry:

```cron
0 4 * * * cd /home/<user>/home-arr && /usr/bin/docker compose run --rm recyclarr sync
```

### Homarr — dashboard

Open `http://<pi>:7575` to set it up. On first launch it walks you through creating an admin user, then you add each service as a tile (it can show queue counts, recent grabs, disk usage, etc.). The `SECRET_ENCRYPTION_KEY` in `.env` is used to encrypt the per-service API keys it stores.

### 4. Samba

```bash
sudo cp smb.conf.example /etc/samba/smb.conf  # or merge into existing
sudo systemctl restart smbd
```

On the Apple TV in Infuse: Add Files → Network Share → SMB → enter the Pi's IP or `raspberrypi.local`. The `movies` and `tv` shares show up automatically.

## Remote access

If you want to queue downloads from outside the home network:
- **Tailscale** (recommended) — `curl -fsSL https://tailscale.com/install.sh | sh`. Your phone joins the same tailnet and can reach the Pi's IP directly. No port forwarding, no public exposure.
- **Cloudflare Tunnel** also works but is more setup.

Do **not** port-forward the *arr web UIs to the public internet. They were not designed to be exposed.

## Mobile clients

- [LunaSea](https://www.lunasea.app/) — iOS + Android, free, talks to Sonarr/Radarr/qBittorrent in one app
- [nzb360](https://nzb360.com/) — Android only, very polished

Both use the *arr REST APIs. API keys are in each app's Settings → General.

## Backups

The `./config/` directory holds everything that matters (database, settings, history). Snapshot it periodically:

```bash
tar czf home-arr-config-$(date +%F).tar.gz config/
```

Media itself is reproducible — *arr can re-fetch anything.
