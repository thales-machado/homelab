# Traefik and DockFlare

Traefik handles private routing (`*.lan.thalespm.me`) through Docker labels, the same model as DockFlare (`exposedByDefault: false`, so only a container with `traefik.enable: "true"` is exposed). There is no central routing file.

**Public certificate from Let's Encrypt (DNS-01 through Cloudflare)**: the `cloudflare` resolver (Lego, `CLOUDFLARE_DNS_API_TOKEN=${CF_API_TOKEN}`, reusing DockFlare's token with `Zone:DNS:Edit` on the zone). The DNS-01 challenge creates and deletes a temporary `_acme-challenge` TXT record through the Cloudflare API, so no port 80/443 is exposed to the internet and there is no public A record: split-horizon keeps access on the LAN and VPN only (Pi-hole is the only resolver that answers `*.lan.thalespm.me`, and Traefik itself is never published through the tunnel). The certificate is a **single wildcard** (`*.lan.thalespm.me`, declared with `tls.domains` on the `traefik-dashboard` router); every other router only references `tls.certresolver: cloudflare` and reuses that certificate from the store by SNI match, with no repeated `tls.domains` and no ACME request per service.

The initial wildcard issuance needs a longer propagation timeout than lego's default 120s. The apex and the wildcard share one TXT record name (`_acme-challenge.lan.thalespm.me`) and are solved sequentially, and between the cleanup of the first challenge and the creation of the second the public resolvers keep serving the cached value until the TTL expires. With the default the issuance fails with "did not return the expected TXT record".

This replaced an internal CA, so certificates are now trusted natively by any OS or browser with no root CA to install on each new device.

**`acme.json` and `acme-cloudflare.json` must exist with `chmod 600` before the first start**, or Traefik refuses to come up. `scripts/setup/setup-traefik-config.sh` takes care of it.

Label pattern for a service on zangetsu (same Docker network as Traefik):

```yaml
labels:
  traefik.enable: "true"
  traefik.http.routers.<name>.rule: "Host(`<name>.lan.thalespm.me`)"
  traefik.http.routers.<name>.entrypoints: "websecure"
  traefik.http.routers.<name>.tls.certresolver: "cloudflare"
  traefik.http.routers.<name>.middlewares: "crowdsec@file"
  traefik.http.services.<name>.loadbalancer.server.port: "<port>"
```

**CrowdSec does not apply itself to every route.** The Traefik plugin (`maxlerebourg/crowdsec-bouncer-traefik-plugin`) needs the `crowdsec@file` middleware referenced on **each** router: Traefik has no native "apply to every router" at the entrypoint level.

**A private service outside zangetsu** (urahara) **or on an external host** (Headroom, the NAS) cannot be discovered, because Traefik's Docker provider only sees the host it runs on. Those go in the file provider instead, `docker/services/platform/networking/traefik/config/dynamic/cross-host.yml`, one `router` plus `service` per entry pointing at IP:port. zangetsu still publishes no port for this; the documented exception is `dockflare`, which publishes 5000 so the remote DockFlare Agent can reach the master.

`pihole.lan.thalespm.me` (`/` → `/admin/`) and the `headroom.lan.thalespm.me` redirect use a `redirectRegex` middleware.

**Traefik dashboard**: `traefik.lan.thalespm.me` points at the internal `api@internal` service. Homepage's widget reads it on port 8080, which is never published on the host and only reachable inside the Docker network (`api.insecure: true`).

**DockFlare (master) needs `USE_EXTERNAL_CLOUDFLARED=true`.** Without it DockFlare runs in its default "managed" mode and treats the `cloudflared-agent-<tunnel>` container as its own, managing its lifecycle straight through the Docker API, outside `docker compose` and with no `com.docker.compose.*` labels. `CLOUDFLARED_IMAGE` (the variable documented for managed mode) **does not help**: DockFlare ignores the value even when `docker exec printenv` confirms it inside the container, and keeps assuming `latest` is the desired image. Every time it detects a "mismatch" against our pinned tag in `cloudflared-agent.yaml`, it recreates the container itself, and the next `docker compose up` or `--force-recreate` then collides on the name (`Conflict: container name already in use`), because Compose does not recognize that container as its own. The fix is `USE_EXTERNAL_CLOUDFLARED=true` plus `EXTERNAL_TUNNEL_ID=${CF_TUNNEL_ID}` in `dockflare.yaml`, which switches to external mode, where DockFlare only consumes labels for ingress and DNS and never touches the container's lifecycle ([official docs](https://github.com/ChrispyBacon-dev/DockFlare/wiki/ExternalcloudflaredMode.md)). `CF_TUNNEL_ID` is the tunnel UUID, taken from the payload of `CF_TUNNEL_TOKEN` itself (the token is base64 of `{"a":account_id,"t":tunnel_id,"s":secret}`, so decode it and read `"t"`; nothing new to generate). Validated with two full stack recreates in a row, exit code 0, no conflict.

**`dockflare-init` and `dockflare-agent-init`** (which chown `/opt/apps/dockflare*` to UID 65532) use `profiles: [init]` and are deliberately **not** in the main service's `depends_on`. The alternative (`depends_on: service_completed_successfully`) leaves a container in `Exited(0)` forever after every `docker compose up -d`, cluttering the Komodo list with no way to hide it (Komodo has no native label to hide a single container; `komodo.skip` only affects the bulk "Stop All Containers" action, despite the name). The accepted trade-off is that the init container **no longer runs automatically**. On a new host, or after resetting `/opt/apps/dockflare` or `/opt/apps/dockflare-agent`, run it by hand **before** the first `docker compose up -d` of the main service:

```bash
docker compose --profile init up -d dockflare-init          # zangetsu
docker compose --profile init up -d dockflare-agent-init    # urahara
```

Without it, `dockflare` / `dockflare-agent` fails on permissions at first start, because they run as UID 65532 and cannot write to a directory just created by root.

**A host-agnostic fragment that needs a port on one host only**: never put `ports:` in the `docker/services/` fragment, which would publish on the host that should not, or point at a LAN IP that does not exist there. Add a small override in `docker/hosts/<hostname>/`, included *after* the original fragment in `include:`, with only that host's `ports:` (see `docker/hosts/urahara/komodo-periphery-port.yaml` and `docker/hosts/urahara/observability-ports.yaml`). If two hosts run the same host-agnostic service and both need their own `*.lan.thalespm.me` hostname, suffix the non-zangetsu one (`<service>-urahara.lan.thalespm.me`).

**An `include:` override does not merge a nested field inside `networks:`.** Lists such as `ports:` and `environment:` merge correctly between the base fragment and the override (tested), but `networks: <net>: ipv4_address:` (a map inside a map) **does not**: the base fragment's value always wins, even with the override listed later in `include:`. For a static IP that has to vary per host, don't use a file override for that field; use `${VAR:-default}` in the base fragment and set the variable only in the `.env` of the host that needs a different value (see `PIHOLE_STATIC_IP` in `pi-hole.yaml`).
