---
name: traefik
description: Use when creating or editing a private *.lan.thalespm.me route, a Traefik label, a Let's Encrypt certificate, the CrowdSec middleware, cross-host.yml, or anything involving DockFlare (public tunnel/ingress) and its relationship with Traefik.
---

Read all of `docs/traefik-dockflare.md` before acting.

Things that must not be forgotten:
- A label change needs `docker compose up -d --force-recreate <service>`. A change to the file provider (`config/dynamic/`) hot-reloads, but that directory is **not** bind-mounted from the repo: after `git pull`, run `scripts/setup/setup-traefik-config.sh` on zangetsu so the hot-reload sees it.
- `crowdsec@file` has to be referenced on **each** router; Traefik has no native "apply to every router".
- A service outside zangetsu (urahara, an external host) never gets a label: it gets an entry in `docker/services/platform/networking/traefik/config/dynamic/cross-host.yml`.
- Without `USE_EXTERNAL_CLOUDFLARED=true` and `EXTERNAL_TUNNEL_ID`, DockFlare (master) recreates `cloudflared-agent` on its own and collides with any manual `docker compose up`. Never remove those two env vars.
- `networks: <net>: ipv4_address:` does not merge between a base fragment and an `include:` override. For a static IP that varies per host, use `${VAR:-default}` in the base fragment, never a file override.
