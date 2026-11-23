# Conventions

This file holds the conventions this repository follows and the reasons behind them. It is the single source of the rules for people and for AI coding assistants (`CLAUDE.md` points here), so it is written as a set of rules; most of them were learned from real production incidents, which are kept as short notes where they explain a rule.

## Hosts and roles

| Host | Hardware | LAN IP | Path | Role |
|---|---|---|---|---|
| `zangetsu` | Raspberry Pi 5 | `192.168.15.214` | `docker/hosts/zangetsu/` | Platform core: Traefik, DockFlare master, primary Pi-hole, observability, Dagu, Komodo Core |
| `urahara` | GMKtec K8 (Ryzen 7 8845HS) | `192.168.15.215` | `docker/hosts/urahara/` | Content and media: Immich, Paperless, n8n, Home Assistant, Wolf, replica Pi-hole |

Other fixed addresses: `192.168.15.248` is the Pi-hole VIP (keepalived), `192.168.15.200` the NAS. Full plan in [LAN addressing](#lan-addressing).

- Each host's entry point is `docker/hosts/<host>/compose.yaml`, whose `include:` list points to fragments in `docker/services/`. Run Compose commands from inside `docker/hosts/<host>/`.
- The repo is checked out at `/opt/homelab` on each host. Each host's real `.env` lives at `/opt/homelab/docker/hosts/<host>/.env` and is never committed (see `docker/hosts/<host>/.env.example`).
- Both hosts are reached over SSH as `keydrop` (`ssh keydrop@<ip>`), for anything that needs the real host (`systemctl`, `docker exec`, editing the real `.env`).
- When adding a host, register it in this table.

### Host operations

- **Traefik label change** → `docker compose up -d --force-recreate <service>`. A change to the file provider (`docker/services/platform/networking/traefik/config/dynamic/`) hot-reloads, but that directory is **copied**, not bind-mounted from the repo: after `git pull`, run `bash scripts/setup/setup-traefik-config.sh` on zangetsu.
- **Editing a host's `.env` recreates every container on it.** `env_file: ${HOMELAB_ENV}` injects the whole file into each service's environment, so changing one variable changes every container's config hash and the next `docker compose up -d`, a Komodo deploy included, recreates all of them: Pi-hole and the LAN's DNS with them. Confirmed on 2026-11-19: one `WATCHTOWER_NOTIFICATION_URL` edit, and the next push recreated everything on both hosts; only the three zangetsu services with no `env_file` (`smartctl-exporter`, `victoriametrics`, `keepalived`) kept their uptime. It also means the opposite surprise: adding `depends_on` to a fragment recreates nothing, because orchestration order is not part of a container's config. Batch `.env` edits rather than pushing them one at a time.
- **Pi-hole DNS reload**: `docker compose exec pi-hole pihole reloaddns` (`restartdns reload` no longer exists in Pi-hole v6).
- **Direct bind mount vs copy**: most services mount `./<folder>` from their own fragment, so `git pull` is enough. A few (`homepage`, `victoriametrics`) mount from `/opt/apps/`, outside the repo, and need their config copied there after `git pull`, with the `homelab-cp` function from `scripts/shell/homelab-functions.sh`. Check the fragment's `volumes:` when unsure.
- **Single-file bind mounts** (e.g. `keepalived.conf`, the Komodo Periphery config): `git pull` or a setup script rewrites the file with a new inode, and the container keeps serving the old one. Always `docker compose up -d --force-recreate <service>`, never just `restart`. Whole-directory bind mounts are not affected.
- **`--force-recreate <service>` also recreates that service's `depends_on`.** Confirmed on zangetsu: recreating `watchtower` took `docker-socket-proxy` with it, while the same command on urahara touched only `watchtower`, because the proxy was already up there. Add `--no-deps` when the intent is to recreate exactly one container, which is the case for a changed `.env` or a rewritten single-file mount.
- **NAS mounts (CIFS)**: units versioned in `scripts/systemd/`, installed by `bash scripts/setup/setup-nas-mounts.sh` (needs sudo). A failed mount triggers `OnFailure=` → `scripts/networking/notify-mount-failure.sh`. A `docker.service` drop-in (`scripts/systemd/docker.service.d/nas-mounts-<host>.conf`, `RequiresMountsFor=`) makes Docker wait for the mounts, so no container starts on an empty bind mount when the NAS is down at boot.
  - **Always a fixed `.mount`, never `.automount`.** An automount unmounts itself when idle; combined with `RequiresMountsFor=` that restarts Docker (and every container) on each idle cycle.
  - **Never `retrans=2` in CIFS `Options=`** (kernel 6.12): the mount reads fine but every write returns `Permission denied`. Changing mount options restarts the host's Docker through `RequiresMountsFor=`, so do one host at a time (the other Pi-hole keeps DNS up).
  - One unit per app covers all its subpaths (`mnt-media-immich.mount` → `/mnt/media/immich`). A slash in the path becomes `-` in the unit name; a literal hyphen inside a segment is escaped as `\x2d` in the installed unit name (`/mnt/games-4tb` → `mnt-games\x2d4tb.mount`, versioned as `scripts/systemd/mnt-games-4tb.mount`). Mixing them up fails with `Where= setting doesn't match unit name`.
- **Boot network delay (urahara)**: the original cause was a pair of systemd `.link` files (`/etc/systemd/network/10-eth0.link`/`10-eth1.link`, host config outside this repo) with the two RTL8125B MACs swapped, so udev failed to rename `eth0`↔`eth1` at boot. Even after fixing them, `network-online.target` was reached before the 2.5GbE link was physically up, and Docker started 31 containers with no network attached. `scripts/systemd/docker-network-delay.service` (oneshot, `sleep 120`, `Before=docker.service`) plus `scripts/systemd/docker.service.d/network-delay-urahara.conf` delays Docker until the link has negotiated. Recovery lesson: `docker restart` does not reattach a container to its network or redo its port publish; only `docker compose up -d --force-recreate <service>` does.
- **Pi-hole HA**: zangetsu is primary, urahara the replica. `keepalived` (containerized, see [Network exceptions](#network-exceptions)) holds the VIP `192.168.15.248`. Config lives in `scripts/setup/keepalived/keepalived-<host>.conf` with a `__VRRP_PASS__` placeholder; `bash scripts/setup/setup-keepalived.sh` renders it from `.env` (`KEEPALIVED_VRRP_PASS`, same on both hosts), then force-recreate `keepalived`. Pi-hole binds port 53 on `0.0.0.0`, so it answers on the VIP wherever it lands. Config sync uses Nebula Sync (Orbital Sync and Gravity Sync are archived and do not support Pi-hole v6); the replica needs `FTLCONF_webserver_api_app_sudo=true`. VRRP tracks the local Pi-hole: `vrrp_script chk_pihole` runs `scripts/networking/keepalived-check-pihole.sh` (installed next to the config by the same setup script) every 5s against `127.0.0.1:53`, and the instance goes FAULT after 3 failures, releasing the VIP to the peer. Before that it tracked only the host and the interface, so a dead Pi-hole container on a live host kept the VIP and `.248` answered nothing, which is the one failure the VIP exists to cover. The script fails open when the image has no DNS client, because a check that cannot run would fault both nodes at once and take the VIP off the LAN. Two log lines at startup are expected and need no action: `Script user 'keepalived_script' does not exist` and `SECURITY VIOLATION - scripts are being executed but script_security not enabled`. keepalived prefers to drop privileges for scripts; that user does not exist in the image, so the script runs as root and it warns. Enabling `script_security` would make keepalived refuse to run the script if any component of its path were writable by non-root, and a refused script faults the node, so the warning is the cheaper outcome.

Router DHCP hands out `192.168.15.248` as DNS 1, `192.168.15.215` (the replica, direct) as DNS 2 and a public resolver as DNS 3. The replica comes before any public resolver on purpose: a public resolver answers `REFUSED` for `*.lan.thalespm.me` and filters nothing, so a fallback breaks every internal name and all blocking at once. The ISP resolver `177.93.168.20` was measured on 2026-11-22 at 26ms against 0.9ms for the VIP on a cache hit, and then answered `REFUSED` to everything, `google.com` included, after about 130 queries and stayed that way for over 15 minutes. That disqualifies it as a secondary: the secondary is only reached when the primary dies and every client in the house switches at the same moment, which is exactly the burst that trips the rate limit, and `REFUSED` is a valid answer the client accepts rather than a timeout it retries elsewhere.
- **Tailscale**: containerized with `network_mode: host` as a subnet router for `192.168.15.0/24` on both hosts (native multi-router failover). `TS_EXTRA_ARGS` must include `--accept-dns=false`, or tailscaled rewrites the host's `/etc/resolv.conf`. Because `tailscale0` sits outside Docker's bridges, the host `FORWARD` policy (`DROP`) silently drops traffic to other LAN hosts; `scripts/networking/tailscale-forward-rules.sh` inserts `ACCEPT` rules in `DOCKER-USER`, re-applied after every Docker restart by `scripts/systemd/tailscale-forward.service`. The node is tagged `tag:no-interactive-login`, and the tailnet ACL auto-approves that tag's advertised routes (`autoApprovers.routes`, outside this repo), so a new node needs no manual approval. State persists in `/opt/apps/tailscale/state`, so recreating the container needs no new auth key. On zangetsu (RPi, no legacy `ip_tables` in the kernel, only native nftables) two extra things are needed, both set per host: `TS_DEBUG_FIREWALL_MODE=nftables`, because the default iptables backend fails to create tailscaled's own chains including SNAT; and a read-only `/lib/modules` mount, without which tailscaled cannot configure any of its netfilter at boot (`modprobe: can't change directory to '/lib/modules'`). Both failures look the same from outside: the subnet router accepts the inbound packet but the reply never comes back, because the LAN target receives the original `100.x` source address and has no route to it. urahara (x86) needs neither; leave the variable empty there. That override has a cost outside Tailscale: tailscaled then writes its rules natively with nft, and `iptables-nft` treats any table holding them as incompatible, so anything else on zangetsu that manages netfilter through iptables cannot. Calico had to move to its nftables dataplane for this reason (PM-0002), and Cilium hit it again as a total loss of pod egress on that node (PM-0009 in `platform-engineering-labs`). Check this before adding any component to zangetsu that writes iptables rules. The lab cluster worked around it with a hand-written nft table holding the pod SNAT rule that Cilium could not install on that node; the script and its unit were removed on 2026-11-19 with the lab, and `seireitei` runs on urahara, where the problem does not exist.

## Network: dual-path

- **LAN (`*.lan.thalespm.me`)**: Pi-hole resolves `*.lan.thalespm.me` to the host IP (split-horizon, no public A record). Traefik terminates HTTPS with a public Let's Encrypt wildcard certificate (DNS-01 via Cloudflare). Details: `docs/traefik-dockflare.md`.
- **Internet (`*.thalespm.me`)**: DockFlare turns Docker labels into Cloudflare Tunnel routes. The Cloudflare Access group `homelab-admin` (GitHub login + MFA) protects sensitive services; `public-default-bypass` is used only for webhook paths.

Every network is declared **only** in the host's `compose.yaml` (`name`, `subnet`, `gateway`, `driver`). A service fragment only references the network by name.

- **`cloudflare-net`**: main network for all services. Subnet and gateway differ per host.
- **`dockflare-internal`**: isolates `docker-socket-proxy`, which is not on `cloudflare-net`. Only services that need `DOCKER_HOST=tcp://docker-socket-proxy:2375` join it. Services that only query the Docker API go through the proxy; the few that cannot are listed in [Docker socket exceptions](#docker-socket-exceptions).

## LAN addressing

`192.168.15.0/24`. The router serves one contiguous DHCP range per network, so the
pool can only grow upward and whatever sits directly above it is what would have to
be renumbered. The pool is sized once, at 100 addresses, to avoid that.

| Range | Purpose | Notes |
|---|---|---|
| `.1` - `.19` | Network gear | switch, APs, room for more |
| `.20` - `.119` | DHCP pool | 100 dynamic addresses |
| `.120` - `.199` | DHCP reservation by MAC | TV, desktops, printer, predictable IoT |
| `.200` - `.209` | Storage | address set on the device: `.200` NAS |
| `.210` - `.219` | Hosts | address set on the device: `.214` zangetsu, `.215` urahara |
| `.220` - `.239` | free | infrastructure growth |
| `.240` - `.247` | Service addresses | `seireitei` LoadBalancer pool, `192.168.15.240/29` |
| `.248` | Pi-hole VIP | keepalived |
| `.250` | Gateway | fixed |

`.249` and `.251`-`.254` are free.

The dividing rule is that **only what must work without DHCP gets its address set on
the device**: the NAS, both hosts, the VIP and the gateway. Everything else
predictable is a reservation by MAC, which is still DHCP answering the same address
every time, and stays under the router's control. `.240`-`.247` holds no machines at
all: Cilium owns those addresses and announces them over L2, so they must never fall
inside the DHCP pool.

## Cross-host services (IP:port pattern)

Traefik, VictoriaMetrics, postgres-exporter, Dozzle and Nebula Sync run only on zangetsu, and Docker name resolution does not cross hosts. When something on zangetsu must reach a service on urahara:

- The urahara service publishes its port **bound to urahara's LAN IP only**, e.g. `"192.168.15.215:7007:7007"`, never `0.0.0.0`.
- The consumer on zangetsu targets `192.168.15.215:<port>` instead of a container name.
- Private HTTP routing does not use Traefik labels (Traefik only discovers containers on its own host). Add a router + service pointing to `http://<host-ip>:<port>` in `docker/services/platform/networking/traefik/config/dynamic/cross-host.yml`, and point the `pihole-dns.yaml` entry to the real host IP.
- If the fragment is host-agnostic (included on more than one host), never put `ports:` in it. Add a small override in `docker/hosts/<host>/`, included after the fragment, containing only that host's `ports:` (examples: `docker/hosts/urahara/observability-ports.yaml`, `docker/hosts/urahara/pi-hole-network.yaml`).
- An `include:` override merges lists (`ports:`, `environment:`) but **not** nested maps such as `networks: <net>: ipv4_address:`; the base value always wins. For a per-host static IP use `${VAR:-default}` in the base fragment and set the variable in that host's `.env` (see `PIHOLE_STATIC_IP`).

The same pattern covers HTTP routing, metrics scraping, Postgres access and agent connections.

## DNS (Pi-hole)

Records are versioned in `docker/services/platform/networking/pi-hole/config/pihole-dns.yaml` and applied by `scripts/networking/sync-pihole-dns.sh`, or by GitHub Actions on commit (`.github/workflows/sync-pihole-dns.yaml`). Every new private service adds a `domain`/`ip` entry there. Ordering rules: see [Ordering rules](#ordering-rules).

A **wildcard** cannot go in that file: Pi-hole's Local DNS records do not support one, only a raw dnsmasq line (`FTLCONF_misc_dnsmasq_lines=address=/<domain>/<ip>` in `pi-hole.yaml`). It also has to be repeated in the replica's override (`docker/hosts/urahara/pi-hole-network.yaml`), because the Pi-hole v6 API rejects that key with a 400 and Nebula Sync cannot propagate it: left out, its `FULL_SYNC` aborts before `RUN_GRAVITY`. There is no wildcard today: `*.lab.thalespm.me` was removed on 2026-11-19 with the lab cluster. `seireitei` needs none, because each migrated application keeps its own `*.lan.thalespm.me` record, pointed at the cluster address one line at a time.

## Homepage

Configured through files in `docker/services/utilities/homepage/config/`; it does **not** use Docker labels.

- A service with a UI gets an entry in `services.yaml` in the right group. Services with no useful UI (databases, Redis, exporters) are not added.
- `docker.yaml` has one block per host, each through that host's `docker-socket-proxy:2375`.
- Widget credentials: every variable Homepage consumes is named `HOMEPAGE_VAR_<SERVICE>_<FUNCTION>`, declared in `homepage.yaml`'s `environment:` and mapped from the `.env` variable (which follows the normal naming, without the prefix). The `HOMEPAGE_VAR_` prefix never appears in `.env`.
- API tokens for app widgets can only be generated after that app's initial onboarding; until then the variable stays empty in `.env`.

## docker/services/ structure

`platform/` · `observability/` · `automation/` · `content/` · `finance/` · `media-player/` · `integration/` · `smart-home/` · `utilities/`

Each fragment `docker/services/<category>/<service>/<service>.yaml` is self-contained.

## Storage convention

- **NAS topology** (QNAP, after the 12TB migration in 10/2026): three top-level shared folders, each on its own volume (Snapshot Shared Folder, classic QTS, so quotas work per folder), all with "hide network drive" on:
  - `lemon-drive`: owner only, synced to OneDrive.
  - `nas-drive`: owner only, not synced (Restic repositories and downloads).
  - a third share used by other people in the house, with fine-grained per-subfolder ACLs. **Before changing any permission on it, read the QNAP runbook in the private repo**: editing the share-level permission screen resets the fine ACL of the share root.
- **NAS media (synced share)**: `<share>/media/<app>/<purpose>` (e.g. `media/immich/upload`, `media/paperless/consume`), mounted at `/mnt/media/<app>/` with **one fixed CIFS `.mount` per app**. The share is synced off-site by the NAS, so it is out of Restic's scope.
- **Remote storage via rclone**: `/mnt/remote/<name>`, data that already has its own backup at the source. It does not follow `media/<app>/` and is out of Restic's scope.
- **Transient downloads (qBittorrent)**: `nas-drive/downloads/`, outside `media/<app>/` (mixed content, not one app's library) and outside `lemon-drive` (in-progress or uncurated downloads should not sync to the cloud). Out of Restic's scope. Fixed mount `mnt-downloads-qbittorrent\x2dgeral.mount` → `/mnt/downloads/qbittorrent-geral` (category "geral"); the "games" category is local, on `games-4tb`. `downloads/software/iso/` (reinstallable installers) follows the same rule.
- **Local game disk (urahara)**: `/mnt/games-4tb` (local ext4 by UUID, `scripts/systemd/mnt-games-4tb.mount`, `WantedBy=local-fs.target`, not part of `setup-nas-mounts.sh`), layout `retro/roms/<system>/` and `retro/bios/<system>/` with ES-DE system names. Wolf saves and states live in `/opt/apps/wolf` (Restic), not on this disk.
- New media service: follow `media/<app>/`, unless the data already lives on external storage with its own backup (then `/mnt/remote/`).
- **rclone and Samba share a host (urahara)**: the FUSE mount exists only inside the `rclone` container, so Samba, which re-exports it to SMB clients, must run on the same host.
- **Consumers of another container's FUSE mount** (today: Samba reading rclone's mount) need **both**:
  1. `depends_on: <fuse-service>: condition: service_healthy` (never `service_started`); `rclone` has a `mountpoint -q` healthcheck because the mount appears seconds after the container starts.
  2. `bind: propagation: rslave` on the consumer's volume. A default (`rprivate`) bind mount only sees what was mounted when the consumer started; if rclone later remounts, the consumer silently keeps an empty directory.
  Even with both, force-recreating `rclone` orphans file handles open at that moment; restart the consumer right after.

## Kubernetes: seireitei

One control-plane node, `urahara`, kubeadm on the 1.37 line, built 2026-11-23.
The reasoning lives in `docs/kubernetes-platform.md`; this section is the part
an operator needs at the keyboard.

`k8s/cluster/kubeadm-config.yaml` is the source of truth, and the phases that
apply it are idempotent: `kubeadm init phase etcd local --config <file>`
rewrites the static Pod manifest, `kubeadm init phase upload-config kubeadm
--config <file>` updates the in-cluster `kubeadm-config` ConfigMap that
`kubeadm upgrade` reads later. Changing only the manifest means the next
upgrade silently reverts it. Run the second phase after the first has settled:
rewriting the etcd manifest restarts etcd, and the upload phase fails with
`context deadline exceeded` if it runs while the API server has no etcd.

The file carries no leading `---`. kubeadm splits on the separator and a
comment-only first document fails with "kind and apiVersion is mandatory".
`extraArgs` is a list of `name`/`value` pairs in `v1beta4`, not a map.

**The CRI is the host's own containerd**, shared with the ~40 Docker
containers, with the CRI plugin already enabled and `SystemdCgroup` already
true. The namespaces (`moby` and `k8s.io`) do not mix, and restarting
containerd drops no container, because running containers are children of
`containerd-shim` rather than of the daemon. A dedicated runtime was weighed
and rejected: it would be a bespoke unit no documentation covers, and this
repo's own postmortems are mostly about bespoke pieces breaking later.

**`systemReserved` carries the Docker containers.** The kubelet cannot see
them, so without it the scheduler believes the whole 28 GiB is free and fills
the host until the OOM killer picks a victim, which could be Pi-hole or
Traefik. With `kubeReserved` 2Gi, `systemReserved` 14Gi and eviction at 1Gi,
allocatable lands at 11.2 GiB of 28.2 GiB.

**etcd metrics are scraped from outside the cluster**, by VictoriaMetrics on
zangetsu, job `etcd-seireitei` against `192.168.15.215:2381`. Port 2381 is the
unauthenticated metrics listener, not the client port 2379, and it is bound to
the host IP rather than `0.0.0.0`. The `seireitei-etcd-slow-fsync` rule has
`noDataState: Alerting` for that reason: silence means etcd stopped answering.
`/source/opt/seireitei/*` is excluded in `scripts/backup/restic-excludes.txt`,
and the `--device-read-bps` cap on the Restic DAG stays (PM-0010).

**Cilium replaces kube-proxy**, which `kubeadm init` skips via `skipPhases`.
`k8sServiceHost`/`k8sServicePort` are mandatory in the values: without them the
agent cannot reach the API server, because the ClusterIP it would use is the
service it has not provided yet. LoadBalancer addresses come from
`192.168.15.240/29` with `allowFirstLastIPs: "No"`, so the usable range is
`.241`-`.246`. The L2 announcement policy matches `^eth0$`, the LAN interface.
`node.kubernetes.io/exclude-from-external-load-balancers` is removed from the
node: kubeadm adds it to every control plane and announcement implementations
skip a node that carries it, so on a single node no LoadBalancer address would
ever appear (PM-0005). Check it again after every `kubeadm upgrade`.

**Every namespace is created with four things, not one.** Pod Security
Standards at `restricted`, a default-deny NetworkPolicy, a `ResourceQuota` and a
`LimitRange`, all from day one, because Cilium makes the policy cheap and
retrofitting any of them onto a running application is what makes people skip
it.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: <app>
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: default-deny, namespace: <app>}
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: allow-dns, namespace: <app>}
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels: {kubernetes.io/metadata.name: kube-system}
          podSelector:
            matchLabels: {k8s-app: kube-dns}
      ports:
        - {protocol: UDP, port: 53}
        - {protocol: TCP, port: 53}
```

`allow-dns` is not optional and not a detail: a default-deny Egress policy blocks
port 53 as well, so without it every pod in the namespace resolves nothing and
the failure looks like the application being broken rather than the policy. Add
it in the same commit as the deny, never after.

**cert-manager's DNS-01 self-check must bypass the cluster's own DNS.** The
`thalespm.me` stub zone sends every lookup to Pi-hole, whose split-horizon view
breaks authoritative-nameserver discovery, so a challenge sits in
`Waiting for DNS-01 challenge propagation` while the TXT record is in fact
public and answering from 1.1.1.1, 8.8.8.8 and Pi-hole itself. The fix is on
cert-manager, not on the policy: `--dns01-recursive-nameservers=1.1.1.1:53,8.8.8.8:53`
and `--dns01-recursive-nameservers-only`. The namespace policy must also allow
egress to `world` on port 53, not only 443: the self-check queries the
authoritative servers directly.

**A Gateway's address is pinned in the Gateway, and Cilium honours it.**
`spec.addresses` with `type: IPAddress` gets that address out of the pool, which
is what lets a Pi-hole record point at it. Prove a new certificate path against
`letsencrypt-staging` before `letsencrypt`: a failed production attempt spends
real quota.

**Gateway API CRDs go in before Cilium's `gatewayAPI.enabled`.** The chart only
renders the `GatewayClass` when the CRD already exists at template time, so
enabling the feature first leaves `enable-gateway-api: true` in `cilium-config`,
no `GatewayClass`, no error anywhere, and nothing working. Cilium 1.20.5 expects
Gateway API v1.6.3 (standard channel); a version mismatch fails the operator on
a kube-proxy-free cluster, which this one is. Order: CRDs, then `helm upgrade`,
then restart `cilium-operator` and the `cilium` DaemonSet.

**A LoadBalancer address does not answer ICMP.** Cilium answers ARP for it and
forwards only the ports the Service declares, so `ping` to `.241`-`.246` fails
by design. Monitoring a cluster service with an ICMP check creates a permanent
false alert.

## Observability

Metrics: VictoriaMetrics (Prometheus-compatible, viewed through Grafana). Logs: Grafana Alloy (River syntax, not YAML) → Loki, 15-day retention.

`postgres-exporter` monitors every Postgres from one container in multi-target mode (`metrics_path: /probe` + `auth_modules`, rendered by `scripts/setup/setup-postgres-exporter-config.sh`). `DATA_SOURCE_NAME` with comma-separated DSNs is not used: it only reported the first DSN, with no label to tell them apart. A new Postgres gets a new `auth_module` plus a target in `prometheus.yml` (job `postgres-exporter`), never a new exporter container.

**Mandatory checklist when adding or removing a service** (this prevents silent monitoring gaps; before it existed, an alert stayed dead for months on a removed container and about ten services were never monitored):

1. `scripts/setup/setup-uptime-kuma.py`: add/remove the entry in `MONITORS` (services with HTTP/TCP) **or** `DOCKER_MONITORS` (containers with no HTTP/TCP and no `up` scrape: databases, redis, keepalived, agents; checked through each host's `docker-socket-proxy`, unhealthy counts as DOWN), **then run the script**. It syncs both ways (creates missing monitors, deletes orphans), but only when run. Uptime Kuma's port is not published, so run it in a throwaway container on `cloudflare-net`:
   ```bash
   docker run --rm --network cloudflare-net \
     -v /opt/apps/uptime-kuma:/app/data:ro -v /opt/homelab/scripts/setup:/s:ro \
     -e UK_URL=http://uptime-kuma:3001 -e UK_PASS=... python:3-slim \
     sh -c "pip install -q uptime-kuma-api && python3 /s/setup-uptime-kuma.py"
   ```
   Every monitor needs the `WhatsApp - Homelab Notify` notification. Its "default" flag only applies in the UI, so a monitor created through the API without `notificationIDList` never alerts (20 of 41 monitors were silent). The script reconciles this on every run. **Keep the history bounded.** 1.x has no aggregate tables: it computes uptime from the raw `heartbeat` table on every monitor-list emit, once per monitor. On 2026-11-19 that table held 6.6M rows in a 963 MB file, 82 aggregates per emit, and the event stopped finishing inside the socket timeout: the dashboard rendered empty, every list call from the script timed out and a single `DELETE` took 2.2s. Retention is the lever (90 days at 118k rows/day is what got it there); the raised `cpus`/`mem_limit` only buy page cache. 2.x adds `stat_*` tables and is the structural fix.

   The script reads the monitor list from SQLite because the `uptime-kuma-api` monitor-list event hangs indefinitely; mutations still go through the API, with one exception found on 2026-11-19: `delete_monitor()` validates the id by calling `get_monitors()` itself, so it inherits the hang and times out without deleting anything. The script replaces `api.get_monitors` with the SQLite listing before pruning, which makes the library's own check pass while the delete emit works normally.
2. `docker/services/observability/metrics/victoriametrics/prometheus.yml`: add the scrape job if the service exposes metrics (Postgres: multi-target pattern above).
3. `docker/services/observability/metrics/grafana/provisioning/alerting/rules.yaml`: grep for the old container name before removing a service and fix any rule that depends on it.
4. Critical scheduled jobs (backup, sync) get a Healthchecks check (`terraform/healthchecks/`, see `docs/backup.md`). The check is declared there and nowhere else: a job pings a URL it is handed, it never creates or updates its own check over the API. `check-wolf-image-updates.sh` did exactly that (`unique=["name"]`), so every monthly run silently reverted the schedule and tags Terraform had applied. The `slug` is the one field Terraform cannot manage: the provider reports it as computed, and it does not follow a rename, so `n8n-backup-urahara` kept the slug `vaultwarden-backup` from two names ago. Fix it with a single `POST /api/v3/checks/<uuid>` carrying `{"slug": "..."}`; recreating the check would reset its ping history.
5. Rerun the whole checklist after any large migration (reverse proxy, Docker manager, etc.); those are what historically left the gaps.

An alert summary never contains a double quote. The WhatsApp contact point
builds its JSON payload by hand and interpolates the summary raw, so a quoted
container name makes the payload invalid and the webhook answers `400`. Two
rules carried one for months and never delivered anything. Use `*asterisks*`
for emphasis, which WhatsApp renders as bold.

## Docker image policy

- Default tag `:latest`; fallback `:lts`, `:stable` or the latest version.
- New service: **check the actual latest release** (GitHub/Docker Hub API) before pinning an exact tag. Never assume a version from memory or stop at the first one that fixes a given bug (Traefik was once pinned to `v3.6` while `v3.7.x` was already the current stable).
- **Auto-update: Watchtower** (maintained fork `ghcr.io/nicholas-fedor/watchtower`; the original is archived), one instance per host through that host's `docker-socket-proxy`. Runs daily at 03:30 local time, after the backup window, with `WATCHTOWER_CLEANUP=true`. Watchtower compares image digests for the same tag, not versions.
- **Opt-in labels** (`WATCHTOWER_LABEL_ENABLE=true`): every service with a floating tag carries `com.centurylinklabs.watchtower.enable: "true"`. A deliberately pinned tag (e.g. `keepalived:2.3.4`, `cloudflared:2026.8.2`) simply has no label, so it is never auto-updated. Version bumps for pinned tags come through Renovate PRs (`renovate.json`).
- **Why not WUD**: WUD was tried and reverted. Its Docker client sends the container config as a URL query string instead of a JSON body, so `docker-socket-proxy` rejects large containers with `414`/`431`; it took down the public tunnel (`cloudflared-agent`) and Homepage (upstream `getwud/wud#621`). Do not reintroduce it until that is fixed.
- **Beware `<major>-<suffix>` tags** (`16-alpine`, `pg16`, `7-alpine`) in any tool that compares versions as strings/semver: a naive parser can "upgrade" `postgres:16-alpine` to an incompatible beta or variant, which once broke databases in production. These services stay out of auto-update on purpose.

## Service internal port

Needed for Traefik labels, DockFlare labels and Homepage widgets. Find it in this order:

1. `EXPOSE`, `command` or `healthcheck` in the service's own yaml.
2. The image's official documentation (Docker Hub, project GitHub).
3. If neither states it, confirm it on a running container (listening sockets) before writing labels. Never guess.

## Ordering rules

`pihole-dns.yaml` is organized by category banners mirroring `docker/services/` (e.g. `# --- Content ---`):

- Banners and the header at the top of the file are protected: never remove or reorder them.
- Within a category, entries are in alphabetical order by domain.

Private routing has no central file; routes live in each service's Traefik labels (or `cross-host.yml`).

## Mandatory conventions

**Resource limits**, on every service:

```yaml
cpus: 0.50
mem_limit: 256m
pids_limit: 64
```

Raise them only with a documented reason in a comment (e.g. Wolf's `pids_limit`, which counts GStreamer threads).

**Volumes**: bind mounts under `/opt/apps/<name>/`. Never named volumes.

**PUID/PGID**: linuxserver.io images do not default to UID 1000; without explicit values the internal user keeps the image's baked-in UID (911), and writes to a CIFS or fixed-UID bind mount fail with `Permission denied`. Always set `PUID=1000`/`PGID=1000` for these images when they write to such mounts.

**Secrets**: via `env_file: - ${HOMELAB_ENV}`. Never hardcoded.

- `HOMELAB_ENV` is set per host in `/etc/environment` and points to `/opt/homelab/docker/hosts/<host>/.env`.
- Each `docker/hosts/<host>/` also needs a physical `.env` in the folder: Compose interpolates `${VAR}` in YAML from the working directory's `.env`, a mechanism separate from `env_file:`. `include:` resolves relative paths against the fragment, which is why a `.env` in `docker/services/` would not work.
- Scripts shared between hosts read `$HOMELAB_ENV`; never hardcode `docker/hosts/<host>/.env` in them. Scripts/DAGs that only make sense on one host may hardcode that host.
- Every variable belongs to a `# --- <Service> ---` section of each host's `.env.example`, never appended loose at the end nor dropped into an unrelated section. A variable for an existing service goes inside that service's section; a new service gets a new section at the end of the file. The same holds for the real `.env` on each host.
- systemd units that call these scripts need `EnvironmentFile=/etc/environment`; systemd does not inherit it the way login sessions do.

**Network**: never a `networks:` definition block in a service yaml. Only reference:

```yaml
networks:
  - cloudflare-net
```

The few exceptions are listed in [Network exceptions](#network-exceptions).

**Timezone**: every service sets `TZ=${TZ}`, never a hardcoded zone.

**Long `environment:` values**: break them with a double-quoted string, `\` at the end of the line (nothing after it) and an indented continuation:

```yaml
environment:
  - "DATA_SOURCE_NAME=postgresql://${DB_USER}:${DB_PASSWORD}@host1:5432/db1?sslmode=disable,\
    postgresql://${OTHER_USER}:${OTHER_PASSWORD}@host2:5432/db2?sslmode=disable"
```

YAML joins the lines with no extra character (verified with `docker compose config`). Without double quotes the `\` is literal and ends up in the value.

## .env naming

- **Global** (used by 2+ services): no prefix. `TZ`, `DB_USER`, `DB_PASSWORD`, `ADMIN_USER`, `ADMIN_PASSWORD`.
- **Platform**: platform prefix. `CF_API_TOKEN`, `CF_ACCOUNT_ID`, `CF_ZONE_ID`, `CF_TUNNEL_TOKEN`, `GITHUB_*`.
- **Per service**: `<SERVICE>_<FUNCTION>` in uppercase, no exceptions.
- **DockFlare exception**: the image's native unprefixed variables (`TUNNEL_NAME`, `LABEL_PREFIX`, `GRACE_PERIOD_SECONDS`, ...).

The yaml maps the `.env` name to whatever the image expects:

```yaml
environment:
  - NAME_THE_IMAGE_EXPECTS=${SERVICE_VARIABLE}
```

Wrong: `DOMAIN`, `JWT_SECRET`, `ENCRYPTION_KEY`, `ADMIN_TOKEN`.
Right: `VAULTWARDEN_DOMAIN`, `KOMODO_JWT_SECRET`, `KOMODO_PASSKEY`, `VAULTWARDEN_ADMIN_TOKEN`.

## Local and CI checks

`pre-commit` (`.pre-commit-config.yaml`) runs gitleaks, yamllint (`.yamllint.yml`), shellcheck, JSON validation and whitespace fixes on every commit; `pre-commit install` once per clone. CI mirrors it: `.github/workflows/ci.yaml` adds `docker compose config` for every host entry point against its `.env.example`, `python -m py_compile` and `terraform fmt -check`, and `.github/workflows/secrets.yml` runs gitleaks over the full history plus a weekly scheduled scan. The deploy lives in that same workflow and `needs:` the checks that decide what runs on a host (`yaml`, `compose`, `shell`, `python`), so broken YAML cannot reach the hosts while the checks are still running, which is what happened while the two were separate workflows racing the same push. `inventory` and `terraform fmt` do not gate it: a stale README table must not block an urgent fix.

`yamllint` is deliberately set to catch only real errors (syntax, duplicate keys, bad anchors), never formatting.

## File and folder naming

Lowercase kebab-case for every file and folder in the repo (`.yaml`, `.sh`, `.md`, ...): `sqlite-backup.yaml`, `notify-mount-failure.sh`. Never CamelCase, snake_case or UPPERCASE in a file name, even when the document's internal title uses other casing. Only names imposed by an external tool are exempt (e.g. `Dockerfile`, `README.md`, `LICENSE`).

## Comments

Comments in YAML, scripts and Terraform are short: one or two lines, three at
the most. They say **why**, never what the line already says, and they are
written for someone who has the file open and needs to not break it.

The narrative belongs here or in `docs/`: the incident, the alternatives
weighed, the measurements, the history. A comment that needs a paragraph is a
comment pointing at the wrong place, so it becomes one line plus a reference
("see X in CONVENTIONS.md"). This file is long on purpose; the config files are
not.

What earns a comment in the file itself is the thing that bites at the keyboard
and has no other warning: a value that looks arbitrary and is not
(`pids_limit: 64`), a field whose format changed between versions, a trap that
silently produces the wrong result (the missing leading `---` in the kubeadm
config). What does not: restating the key below it, describing what the service
is, or explaining a decision that CONVENTIONS already explains.

Applies to this file too. A section that grows past what an operator reads at
the keyboard moves to `docs/` and leaves a link.

## scripts/ layout

No script lives directly in `scripts/`. Each goes in a subfolder by **function**, not by app:

```
scripts/
├── backup/       # consistent snapshots (SQLite/Postgres) and Restic, plus restic-excludes.txt
├── setup/        # config provisioning/rendering, run manually once or when the config changes
├── networking/   # DNS sync, VPN forwarding rules, mount failure notification
├── immich/       # Immich-specific utilities
├── inventory/    # the service inventory that CI checks against README.md
├── monitoring/   # checks for things no Prometheus exporter covers
├── shell/        # interactive helpers sourced from ~/.bashrc on the hosts
└── systemd/      # real systemd units, referenced by scripts from several categories
```

**A script started by a systemd unit must be committed executable.** The units use `ExecStart=/opt/homelab/scripts/<folder>/<script>`, and systemd cannot exec a file without the bit: it fails with `status=203/EXEC`. Found on 2026-11-18 with `tailscale-forward.service`, which had been failing every five minutes since the zangetsu reboot of 2026-11-16, leaving the `DOCKER-USER` ACCEPT rules unapplied and the subnet router silently dropping traffic to other LAN hosts. The six `notify-*-mount-failure.service` units had the same defect, which would have silenced exactly the alert they exist to send.

A backup script for a new app goes in `backup/`, not a new folder. Create a subfolder only for genuinely distinct functionality. When a script moves, update every reference to it, including `command:` in Dagu DAGs (`docker/services/automation/dagu/dags/`) and `ExecStart=` in `scripts/systemd/` units, which use absolute paths (`/opt/homelab/scripts/<folder>/<script>`).

## Service templates

| Type | DockFlare labels + `depends_on: dockflare` | `pihole-dns.yaml` + Traefik labels |
|---|---|---|
| Private (`*.lan.thalespm.me`) | No | Yes |
| Public (`*.thalespm.me`) | Yes | No |
| Both | Yes | Yes (same container/port as the DockFlare labels) |

Full skeletons (private/public/both/webhook) live in `.claude/commands/new-service.md`, the `/new-service` command.

Common base: resource limits, `TZ=${TZ}`, `env_file: ${HOMELAB_ENV}` if it uses secrets, bind mount under `/opt/apps/<name>/`, only a reference to `cloudflare-net`. Fragment path: `docker/services/<category>/<name>/<name>.yaml`; exporters go in `docker/services/observability/metrics/exporters/<name>/` and get a scrape job, with no Traefik, DNS, DockFlare or Homepage entry.

Private service on zangetsu:

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
      - ${HOMELAB_ENV}
    environment:
      - TZ=${TZ}
    volumes:
      - /opt/apps/<name>:/data
    networks:
      - cloudflare-net
    labels:
      com.centurylinklabs.watchtower.enable: "true"   # omit for a pinned tag
      traefik.enable: "true"
      traefik.http.routers.<name>.rule: "Host(`<name>.lan.thalespm.me`)"
      traefik.http.routers.<name>.entrypoints: "websecure"
      traefik.http.routers.<name>.tls.certresolver: "cloudflare"
      traefik.http.routers.<name>.middlewares: "crowdsec@file,security-headers@file"
      traefik.http.services.<name>.loadbalancer.server.port: "<port>"
```

`crowdsec@file` must be listed on every router; Traefik has no global "apply to all routers". A private service on another host drops the Traefik labels and follows [Cross-host services](#cross-host-services-ipport-pattern).

Public service: same base plus

```yaml
    depends_on:
      dockflare:
        condition: service_healthy
    labels:
      dockflare.enable: "true"
      dockflare.hostname: "<name>.thalespm.me"
      dockflare.service: "http://<name>:<port>"
      dockflare.access.group: "homelab-admin"   # set explicitly, or omit (see exceptions)
```

Webhook path exempt from Cloudflare Access (rest of the host stays behind MFA):

```yaml
      dockflare.0.hostname: "<name>.thalespm.me"
      dockflare.0.path: "/webhook"
      dockflare.0.service: "http://<name>:<port>"
      dockflare.0.access.group: "public-default-bypass"
```

## Intentional exceptions

### Public services without `dockflare.access.group`

Services where Cloudflare Access (MFA) would break normal use. Do not add an access group to them without revisiting the reason:

- `immich`: used from the mobile app by several people.
- `vaultwarden`: shared password vault used by several people from native clients.
- `it-tools`: stateless tools, nothing to protect.
- `tandoor`: used from a mobile app (kitshn) and by non-admin accounts; protected by native login rate limiting (Tandoor 2.6.1+) and strong per-account passwords instead of platform MFA.
- `calnode`: booking page whose whole purpose is that strangers can open the link and pick a slot.
- `thalesmachado-net`: public portfolio site, must be reachable without login.

Rule: a public service is never given `homelab-admin` by assumption. If no access group is chosen, the label is omitted and the service is added to this list.

### Network exceptions

Each of these replaces `networks:` with something else for a hardware/protocol reason. Do not copy the pattern without an equivalent need.

- `pi-hole`: map-format `networks:` with a fixed `ipv4_address` (`${PIHOLE_STATIC_IP:-...}`), because DNS needs a static IP.
- `keepalived`: `network_mode: host`. VRRP (multicast + gratuitous ARP) needs the physical interface, which the `cloudflare-net` bridge does not expose.
- `tailscale`: `network_mode: host`, as recommended for subnet routers, to avoid double NAT (tailscaled's SNAT followed by Docker's masquerade).
- `home-assistant`: `network_mode: host`. Local device discovery (mDNS/SSDP for HomeKit, Chromecast, etc.) needs multicast/broadcast on the physical interface. Since Home Assistant 2026.8, reverse-proxy trust can only be set in the UI (Settings → System → Network → HTTP server); the `http: trusted_proxies` block in `configuration.yaml` validates but has no effect. Until it is set, every request through Traefik returns 400, so onboarding is done directly at `192.168.15.215:8123`.
- `wolf`: `network_mode: host`. It publishes fixed Moonlight ports (47984/47989/48010 TCP, 47999/48100/48200 UDP), announces itself via mDNS, and Moonlight clients connect straight to the host IP.

### Docker socket exceptions

The default is `docker-socket-proxy` (Homepage, Watchtower, Autoheal, DockFlare). These services mount `/var/run/docker.sock` directly, each for a stated reason; read-only wherever the service only reads:

- `traefik` (`:ro`): Docker provider for label-based routing.
- `dozzle` and `dozzle-agent` (`:ro`): Dozzle's agent mode does not work behind the socket proxy, per its official docs.
- `grafana-alloy` (`:ro`): container discovery and log collection.
- `dagu`: runs `docker.run` steps in its DAGs, which need to create containers.
- `komodo-periphery`: deploys, starts and stops stacks, so it needs full read-write control.
- `wolf`: creates and removes an app container per streaming session, and `WOLF_DOCKER_SOCKET` only supports a unix socket, not TCP.

A new service gets the socket directly only with a reason of the same kind, written as a comment next to the mount.

## Critical restrictions

- **`komodo-core`/`komodo-periphery` never go in the `include:` of a host's main `compose.yaml`** (see [Komodo deployment](#komodo-deployment)).
- Never declare a `networks:` definition block in a service yaml.
- Never use named volumes.
- Never hardcode secrets; always `${HOMELAB_ENV}`.
- New private service → `pihole-dns.yaml` entry + Traefik labels in its own yaml (or a `cross-host.yml` entry if it is not on zangetsu).
- New public service → DockFlare labels + `depends_on: dockflare`, and an explicit decision on `dockflare.access.group`.
- New "both" service → all of the above, same container/port for DockFlare and Traefik.
- **`include:` is the only source of truth for what runs.** It must match production exactly:
  - A service that moved hosts or was decommissioned has its line **removed**, not commented out. History belongs in git, and `include:` is the only statement of what a host actually runs.
  - A commented line is allowed only for a real standby with a concrete, documented reason to reactivate.
  - A fragment with no line in any `include:` is legacy or under evaluation. It gets no `pihole-dns.yaml` entry until it has an `include:` line, and compliance checks (Watchtower labels, limits, `TZ`, backup, DNS, monitoring) run only on included fragments.

## Komodo deployment

Komodo Core runs only on zangetsu (`docker/services/platform/management/komodo/komodo.yaml`); Periphery runs on every host (`periphery.yaml`). GitHub Actions calls each host's Stack webhook only when the push touches that host's `include:`. Full details: `docs/komodo.md`.

- A deploy that recreates Core or Periphery kills the process running the deploy (containers left in `Created`, Stack stuck in `DOWN`). Removing them from `include:` is not enough, because Komodo works at the Compose **project** level. So `docker/hosts/<host>/komodo-periphery.yaml` and `docker/hosts/zangetsu/komodo-core.yaml` are **separate Compose projects** (`name: komodo-periphery` / `name: komodo-core`, `cloudflare-net` as `external: true`), always deployed manually:

  ```bash
  cd docker/hosts/<host> && docker compose -f komodo-periphery.yaml up -d
  cd docker/hosts/zangetsu && docker compose -f komodo-core.yaml up -d
  ```

  Because Periphery is its own project, Watchtower can recreate it without colliding with a Komodo deploy in progress.
- Never use `DeployStackIfChanged` (intermittent silent hang on `include:`-heavy stacks, still present in 2.3.3). Both Stacks use `webhook_force_deploy: true`.
- Keep Core and Periphery on the same version. Upgrade with `pull` before `--force-recreate` (recreate alone does not pull).
- Each Stack's webhook secret must match the GitHub Actions secret `KOMODO_HOMELAB_<HOST>_WEBHOOK_SECRET`; a mismatch fails only as exit 22 in the Actions run.

## Database backup

Full details: `docs/backup.md`.

- Every database (SQLite, Postgres) is backed up by a **consistent snapshot** taken by a Dagu DAG before Restic runs. Restic's copy of a live database file is never trusted.
  - SQLite: `scripts/backup/backup-sqlite.sh` (`.backup`), DAG `sqlite-backup`; n8n on urahara uses `scripts/backup/backup-n8n-sqlite.sh`, DAG `n8n-backup-urahara`.
  - Postgres: `scripts/backup/backup-postgres.sh` (`pg_dump`), DAG `postgres-backup`. The runner image must be the same Postgres major as or newer than the newest server in the stack; `pg_dump` refuses newer servers.
  - Snapshots go to `/opt/apps/<app>/db-backup/`.
- A new service with its own database is added to the existing script; never a new DAG.
- The script and the DAG that runs it are one unit: a database added to a backup script must get, in the same commit, its app directory in the DAG's volumes and any credential the script reads in the DAG's exports. Two silent week-long failures came from exactly this (calnode missing from the volumes, `EVOLUTION_DB*` missing from the exports): the script dies on that entry, the DAG exits non-zero, and every other database in the same run still gets backed up, so only the Healthchecks alert shows it.
- `scripts/backup/restic-excludes.txt` excludes the live database files (`*.sqlite`/`*.db` + `-wal`/`-shm` directly under `/opt/apps/<app>/`, and `/opt/apps/<app>/db/`). Its patterns are non-recursive so `db-backup/` is never excluded. Edit it only for a database outside those patterns.
- Filesystem backup is Restic (`/opt` + `/etc`), one repository per host on a fixed NAS mount (`/mnt/backup/<host>`), each with its own backup + prune DAG pair. Never a central repository for several hosts.
- urahara's DAGs run from zangetsu's Dagu via `action: ssh.run`. A `command:` with `$`/`$()` must escape `\$` **and** set `shell: /bin/sh`, or the variable arrives empty.
- n8n workflows are not exported as JSON to the repo; `database.sqlite` is already backed up.

## n8n

- Edit workflows through the REST API (`X-N8N-API-KEY: ${N8N_API_KEY}` on `http://n8n:5678/api/v1/...`), never by editing `database.sqlite`, so the container never has to stop. `N8N_WEBHOOK_SECRET` validates incoming webhooks and does not work for the API.
- **Names** are always in English, for the workflow and for every node. A node referenced by name (`$('Node Name')` in expressions/code) must have every reference updated in the same rename, or executions break.
- **Format** `<System> | <Category> | <Subject - Action>`, dropping the last levels when they add nothing:
  - **System**: root namespace, the origin/integration (e.g. `Homelab`, `WhatsApp`).
  - **Category**: functional group inside the system (e.g. `Ops`, `Direct`). Omitted for a cross-cutting workflow (e.g. `Homelab | Error Notifier`).
  - **Subject - Action**: when several workflows in a category share a subject, the subject comes first, then ` - ` and the action (e.g. `Ops - Commands`), so the list scans by subject. When every workflow in the category has its own subject, the action alone is enough.
  - Separators: `|` between levels, `-` between subject and action, `&` to join two related actions (`Download & Parse`).
- Pending: the "Homelab" folder in n8n is not consistent yet (`Homelab Notify` without pipes vs `Homelab | Ops - Commands` / `Homelab | Error Notifier`). Do not rename without explicit confirmation.
- **Every alert path ends at the `Homelab Notify` workflow**, on the webhook path `/webhook/homelab-notify`. From a container on either host it is reachable through Traefik (`https://n8n.lan.thalespm.me/webhook/homelab-notify`) and directly (`http://192.168.15.215:8097/webhook/homelab-notify`, the cross-host IP:port pattern). **Anything that runs on the host rather than in a container must use the direct form**, because it fires at boot, before Pi-hole and Traefik are up: `notify-mount-failure.sh` used the name and curl exited 6 on 2026-11-19, so the mount-failure alert could never fire at the only moment it exists for. The Healthchecks integration uses the direct form too. Watchtower, Healthchecks and Uptime Kuma cannot set a custom header, so the `Validate Origin` node recognises them by the **shape of the payload** and answers `401 {"status":"error","message":"Origem nao reconhecida"}` to anything else. A hand-made `curl` therefore has to imitate the real payload (`{"title":"Watchtower updates on <host>","message":"..."}`, `{"title":"Healthchecks","message":"..."}`) or it is rejected: that 401 is the workflow working, not a broken route.
- **shoutrrr must use `generic://`, never `generic+https://`.** With the `generic+` prefix every query variable is escaped and forwarded to the server instead of configuring shoutrrr, so `?template=json` is ignored, the body arrives as plain text with no `title`/`message`, and `Validate Origin` rejects it. `generic://` already defaults to https. Watchtower's notifications were silently dropped this way until 2026-11-19.
- **Node layout** when inserting nodes through the API (`position: [x, y]`): at least **200px** horizontally between consecutive depth columns and **120px** vertically between parallel nodes (branches of an IF/Switch). Inserting into an existing chain means shifting `position` for every later node, not only the new one. A node in a straight chain keeps the same `y` as its neighbours; only vary `y` for real branches.
