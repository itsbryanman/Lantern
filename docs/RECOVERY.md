# Recovery

Use this when the stack is down or behaving badly.

## 1. Check the basics

```bash
docker ps
./scripts/health-check.sh
```

- If Traefik is down, none of the web apps will load.
- If Authentik is down, app access may fail even when containers are running.
- If DNS is wrong, services may be healthy locally but unreachable by name.

## 2. Check recent logs

```bash
docker logs traefik --tail 100
docker logs authentik-server --tail 100
docker logs homepage --tail 100
docker logs uptime-kuma --tail 100
```

For app issues, swap in the app container name such as `jellyfin`, `immich`, or `paperless`.

## 3. Restore data

```bash
./scripts/restore.sh --list
./scripts/restore.sh --latest --target /tmp/lantern-restore
```

Inspect the restored files before copying anything back into production paths.

## 4. Re-deploy a stack

```bash
./scripts/update.sh
./scripts/update.sh jellyfin
```

If a single service is broken after an image update, pin that service to a known-good image tag before bringing it back.
