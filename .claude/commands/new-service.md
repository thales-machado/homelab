Create a new homelab service from these arguments: $ARGUMENTS

<!--
Examples:
  /new-service uptime-kuma zangetsu private active
  /new-service it-tools zangetsu public active
  /new-service some-app zangetsu both standby
  /new-service postgres-exporter zangetsu export active
  /new-service pihole zangetsu private active host-port:53
-->

Format: `<service-name> <host> <private|public|both|export> <active|standby> [host-port:<port>]`

Follow CONVENTIONS.md strictly: the rules for the internal port, `pihole-dns.yaml` ordering, `dockflare.access.group` and the mandatory conventions all apply exactly as written there. This file only holds the YAML skeletons and the steps specific to each variant.

1. Identify the official image most used for this service, and **check its latest release for real** before pinning an exact tag (see the Docker image policy in CONVENTIONS.md). Never guess.
2. Find the internal port as described in CONVENTIONS.md. Never guess.
3. With `host-port:<port>`, publish it on the host. Otherwise, no `ports:`.
4. For private or both, when the service does **not** run on zangetsu: a label will not work, because Traefik only discovers containers on its own host. It goes in `infra/platform/networking/traefik/config/dynamic/cross-host.yml` instead.

## Skeletons

### PRIVATE (`*.lan.thalespm.me`, service on zangetsu)

```yaml
services:
  <name>:
    image: <image>:latest
    container_name: <name>
    restart: unless-stopped
    cpus: 0.50
    mem_limit: 256m
    pids_limit: 64
    env_file:
      - ${HOMELAB_ENV}        # drop if the service uses no secrets
    environment:
      - TZ=${TZ}
    volumes:
      - /opt/apps/<name>:/data
    networks:
      - cloudflare-net
    labels:
      com.centurylinklabs.watchtower.enable: "true"   # omit for a pinned tag (never auto-updated)
      traefik.enable: "true"
      traefik.http.routers.<name>.rule: "Host(`<name>.lan.thalespm.me`)"
      traefik.http.routers.<name>.entrypoints: "websecure"
      traefik.http.routers.<name>.tls.certresolver: "cloudflare"
      traefik.http.routers.<name>.middlewares: "crowdsec@file,security-headers@file"
      traefik.http.services.<name>.loadbalancer.server.port: "<port>"
```

- Write the fragment to `infra/<category>/<name>/<name>.yaml`.
- Add an entry to `pihole-dns.yaml` (domain plus zangetsu's IP).
- If it has a useful UI, add it to `infra/utilities/homepage/config/services.yaml` in the right group.

### PRIVATE, service outside zangetsu (urahara)

The same skeleton, **without** the Traefik `labels` block (labels do not work across hosts). Add this to `infra/platform/networking/traefik/config/dynamic/cross-host.yml` instead:

```yaml
http:
  routers:
    <name>:
      rule: "Host(`<name>.lan.thalespm.me`)"
      entrypoints: ["websecure"]
      tls: { certresolver: cloudflare }
      middlewares: ["crowdsec", "security-headers"]
      service: <name>
  services:
    <name>:
      loadBalancer:
        servers:
          - url: "http://<host-ip>:<port>"
```

- Add an entry to `pihole-dns.yaml` with the **real host's** IP, not zangetsu's.

### PUBLIC (`*.thalespm.me`)

```yaml
services:
  <name>:
    image: <image>:latest
    container_name: <name>
    restart: unless-stopped
    cpus: 0.50
    mem_limit: 256m
    pids_limit: 64
    env_file:
      - ${HOMELAB_ENV}        # drop if the service uses no secrets
    environment:
      - TZ=${TZ}
    volumes:
      - /opt/apps/<name>:/data
    depends_on:
      dockflare:
        condition: service_healthy
    networks:
      - cloudflare-net
    labels:
      dockflare.enable: "true"
      com.centurylinklabs.watchtower.enable: "true"
      dockflare.hostname: "<name>.thalespm.me"
      dockflare.service: "http://<name>:<port>"
      dockflare.access.group: "<ask the user; omit this label if they do not say>"
```

- Write the fragment to `infra/<category>/<name>/<name>.yaml`.
- Ask which `dockflare.access.group` to use. If the user does not say, omit the label; never assume `homelab-admin` (see the exceptions in CONVENTIONS.md).
- If it has a useful UI, add it to `infra/utilities/homepage/config/services.yaml` in the right group.

### BOTH (private and public)

The PUBLIC skeleton plus the PRIVATE skeleton's Traefik `labels` block (or its `cross-host.yml` entry, outside zangetsu). On top of the steps above:

- Add an entry to `pihole-dns.yaml` pointing at the same container and port used in the DockFlare labels.

### EXPORT

- Write the fragment to `infra/observability/metrics/exporters/<name>/<name>.yaml`.
- Add a scrape job to `prometheus.yml`.
- No Traefik, no Pi-hole, no DockFlare, no Homepage.

### Webhook (a path bypassing Cloudflare Access)

When the service needs a public path without MFA, for example to receive webhooks:

```yaml
labels:
  dockflare.enable: "true"
  dockflare.hostname: "<name>.thalespm.me"
  dockflare.service: "http://<name>:<port>"
  dockflare.access.group: "homelab-admin"
  dockflare.0.hostname: "<name>.thalespm.me"
  dockflare.0.path: "/webhook"
  dockflare.0.service: "http://<name>:<port>"
  dockflare.0.access.group: "public-default-bypass"
```

## Activation

With `active`, add the line to `include:` in `hosts/<host>/compose.yaml` as usual.

With `standby`, build the whole structure as if it were active (the service fragment with its Traefik labels, `pihole-dns.yaml`, Homepage) but comment out only the matching line in `include:`, so the container does not start until someone uncomments it. There is no separate step to "switch off" the routing: the Traefik labels live inside the service's own fragment, so they only take effect once the container is up.

Present the plan before applying it.
