# Admin Guide

This guide covers the day-to-day tasks for the person running the family server.

## First-time setup

1. Copy `lantern.yaml.example` to `lantern.yaml`.
2. Set the domain, email, timezone, storage paths, and enabled apps.
3. Run `sudo ./install.sh --config lantern.yaml`.
4. Point your DNS records at the server before inviting the family.

## Core URLs

- Dashboard: `https://your-domain`
- Auth admin: `https://auth.your-domain/if/admin/`
- Status page: `https://status.your-domain`

## Useful commands

```bash
./scripts/health-check.sh
./scripts/backup.sh
./scripts/backup.sh --status
./scripts/update.sh
./scripts/restore.sh --list
```

## Routine operations

- Review backups weekly and run `./scripts/backup.sh --verify`.
- Update containers during a low-traffic window.
- Add or remove household users in Authentik instead of sharing one admin login.
- Keep the `secrets/` folder private and backed up.

## Before large changes

1. Confirm the latest backup exists.
2. Export or note any custom settings changed inside app web UIs.
3. Update one stack at a time so failures are easy to isolate.
