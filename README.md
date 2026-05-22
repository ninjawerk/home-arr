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

### 1. Prepare the host

Raspberry Pi OS Lite (64-bit). Then:

```bash
# Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
# log out + back in

# Samba on the host (not containerised)
sudo apt install samba

# Mount your SSD at /mnt/media and create the layout
sudo mkdir -p /mnt/media/{movies,tv,music,books,downloads}
sudo chown -R $USER:$USER /mnt/media
```

### 2. Clone + configure

```bash
git clone https://github.com/ninjawerk/home-arr.git
cd home-arr
cp .env.example .env
# edit .env — set PUID/PGID (run `id`), TZ, MEDIA_ROOT
```

### 3. Bring up the stack

```bash
docker compose up -d
```

Each service has a web UI on its port. First-run config:
1. **Prowlarr** (`:9696`) — add indexers, then link Sonarr + Radarr from Settings → Apps
2. **qBittorrent** (`:8090`) — default login is `admin` / check container logs for temp password
3. **Sonarr** (`:8989`) / **Radarr** (`:7878`) — add qBittorrent as download client, set root folder to `/tv` or `/movies`

The [TRaSH Guides](https://trash-guides.info/) are the gold standard for *arr configuration — quality profiles, naming, indexers, the lot.

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
