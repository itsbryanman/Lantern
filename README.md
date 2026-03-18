#  Lantern

**A deployable family server stack — built once, used by everyone.**

Lantern is a single-config, Docker-based family server that gives your household a private cloud with photo backup, media streaming, file storage, recipe management, and more — without requiring anyone in your family to understand what a container is.

## What you get

- **Dashboard** — One clean page with big icons. Family sees family apps. Admin sees admin tools.
- **Photo backup** — Immich for automatic phone backup and shared albums
- **Media server** — Jellyfin for movies, TV, music
- **File storage** — FileBrowser (lightweight) or Nextcloud (full suite)
- **Recipes** — Mealie for meal planning and recipe management
- **Documents** — Paperless-ngx for scanning and organizing household paperwork
- **Real auth** — Authentik SSO with per-user accounts and app protection
- **Monitoring** — Uptime Kuma status page + health checks
- **Backups** — Automated restic snapshots with restore verification
- **HTTPS everywhere** — Traefik reverse proxy with automatic TLS certificates

## Quick start

```bash
git clone https://github.com/itsbryanman/Lantern.git
cd Lantern
cp lantern.yaml.example lantern.yaml
# Edit lantern.yaml with your domain, email, and app choices
sudo ./install.sh --config lantern.yaml
```

## Requirements

- Ubuntu 22.04+ or Debian 12+ (tested)
- 2 GB RAM minimum (4 GB+ recommended with Immich)
- 20 GB disk minimum (more for media/photos)
- A domain name (or use `.local` for LAN-only)
- Docker (installed automatically if missing)

## Project structure

```
Lantern/
├── install.sh                 # Bootstrap installer
├── lantern.yaml.example     # Config template
├── compose/
│   ├── core/                  # Traefik, Authentik, Homepage, Uptime Kuma
│   └── apps/                  # Immich, Jellyfin, Mealie, FileBrowser, etc.
├── configs/                   # Service configuration templates
├── scripts/
│   ├── backup.sh              # Automated restic backups
│   ├── restore.sh             # Snapshot restore
│   ├── health-check.sh        # Service health validation
│   └── update.sh              # Safe container updates
├── docs/
│   ├── FAMILY-GUIDE.md        # For your family — how to use everything
│   ├── ADMIN-GUIDE.md         # For you — how to manage everything
│   └── RECOVERY.md            # When things break at 2 AM
└── README.md
```

## Configuration

Everything is driven by `lantern.yaml`. Set your domain, choose your apps, and the installer handles the rest:

- Generates strong passwords and API keys
- Creates Docker networks and volumes
- Deploys services in dependency order with health checks
- Auto-registers apps on the dashboard
- Sets up automated backups
- Runs post-install validation

See [`lantern.yaml.example`](lantern.yaml.example) for all options.

## Daily operations

```bash
# Check health of all services
./scripts/health-check.sh

# Run a backup now
./scripts/backup.sh

# Check backup status
./scripts/backup.sh --status

# Update all containers
./scripts/update.sh

# Update a specific service
./scripts/update.sh jellyfin

# Restore from backup
./scripts/restore.sh --list
./scripts/restore.sh --latest
```

## Design principles

1. **Family first** — The dashboard is a launchpad, not a sysadmin console
2. **Config-driven** — One YAML file, not 47 scattered env files
3. **Modular** — Enable only the apps you want
4. **Recoverable** — Automated backups with verified restores
5. **Secure by default** — SSO, HTTPS, no shared admin accounts
6. **Repeatable** — Blow it away and rebuild from config + backup

## Built by

[Backwoods Development](https://backwoodsdevelopment.com)

## License

MIT
