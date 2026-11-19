# homelab

A household platform running on two Debian machines: a Raspberry Pi 5 with
7.9 GiB of RAM and a mini PC with a Ryzen 7. Between them they run about
fifty containers, published to the LAN and to the internet, backed up nightly
and monitored.

Everything here is declared in this repository. A change is a commit:
GitHub Actions works out which hosts it touches and Komodo deploys it there.
Nothing is configured by hand on a host.

The interesting part is not the service list. It is what the constraints
forced: a four-core ARM board carries the control plane, so every decision
below is a trade between capability and the memory left on that board.

## The two hosts

| Host | Hardware | LAN IP | Carries |
|---|---|---|---|
| `zangetsu` | Raspberry Pi 5, 4 cores arm64, 7.9 GiB | `192.168.15.214` | Routing, DNS, deploys, automation, observability |
| `urahara` | GMKtec K8, Ryzen 7 8845HS, 28 GiB, NVMe | `192.168.15.215` | Photos, documents, smart home, media, game streaming |

The split is not by category, it is by what breaks when the machine does.
zangetsu holds what the house cannot lose: name resolution, the reverse
proxy, the deploy agent, the alerting path. urahara holds what is heavy and
tolerant of an outage. Pi-hole runs on both behind a keepalived VIP, with
Nebula Sync keeping the two configurations identical, because the one service
whose failure makes every other failure invisible is DNS.

## How a change reaches production

```
commit -> push -> GitHub Actions -> Komodo webhook -> docker compose up -d
```

`docker/hosts/<host>/compose.yaml` and its `include:` list are the single
source of truth for what runs on a host. The workflow reads those lists and
triggers a host only when a changed file falls inside a fragment that host
actually uses, so editing a service that only exists on one machine does not
redeploy the other.

Two things deliberately stay outside that path. Komodo's own Core and
Periphery live in separate Compose projects and are deployed by hand: a
deploy that recreated them would kill the process running the deploy, and the
symptom is every container on the host stuck in `Created` with the stack
reporting success forever. And a handful of configs are copied into
`/opt/apps/` rather than bind-mounted, so a `git pull` alone does not reach
them.

## What runs

Generated from the `include:` list of every host entry point by
`scripts/inventory/inventory.py`. A pre-commit hook and a CI job fail when
the committed table differs from the generated one, so it cannot drift from
what is deployed. A fragment with no `include:` line is not running, and is
not an oversight.

<!-- inventory:start -->

| Service | Runtime | Host | Category |
|---|---|---|---|
| `dagu` | docker | `zangetsu` | `automation` |
| `n8n` | docker | `urahara` | `automation` |
| `immich` | docker | `urahara` | `content` |
| `paperless-ngx` | docker | `urahara` | `content` |
| `stirling-pdf` | docker | `urahara` | `content` |
| `tandoor` | docker | `urahara` | `content` |
| `firefly-iii` | docker | `zangetsu` | `finance` |
| `firefly-iii-data-importer` | docker | `zangetsu` | `finance` |
| `evolution-api` | docker | `urahara` | `integration` |
| `rclone` | docker | `urahara` | `media-player` |
| `samba` | docker | `urahara` | `media-player` |
| `wolf` | docker | `urahara` | `media-player` |
| `blackbox-exporter` | docker | `zangetsu` | `observability` |
| `cadvisor` | docker | `urahara`, `zangetsu` | `observability` |
| `dozzle` | docker | `zangetsu` | `observability` |
| `dozzle-agent` | docker | `urahara` | `observability` |
| `grafana` | docker | `zangetsu` | `observability` |
| `grafana-alloy` | docker | `urahara`, `zangetsu` | `observability` |
| `loki` | docker | `zangetsu` | `observability` |
| `node-exporter` | docker | `urahara`, `zangetsu` | `observability` |
| `postgres-exporter` | docker | `zangetsu` | `observability` |
| `redis-exporter` | docker | `urahara`, `zangetsu` | `observability` |
| `scrutiny` | docker | `zangetsu` | `observability` |
| `smartctl-exporter` | docker | `urahara`, `zangetsu` | `observability` |
| `unpoller` | docker | `zangetsu` | `observability` |
| `uptime-kuma` | docker | `zangetsu` | `observability` |
| `victoriametrics` | docker | `zangetsu` | `observability` |
| `autoheal` | docker | `urahara`, `zangetsu` | `platform` |
| `cloudflared-agent` | docker | `zangetsu` | `platform` |
| `crowdsec` | docker | `urahara` | `platform` |
| `dockflare` | docker | `zangetsu` | `platform` |
| `dockflare-agent` | docker | `urahara` | `platform` |
| `healthchecks` | docker | `zangetsu` | `platform` |
| `keepalived` | docker | `urahara`, `zangetsu` | `platform` |
| `komodo` | docker | `urahara`, `zangetsu` | `platform` |
| `nebula-sync` | docker | `zangetsu` | `platform` |
| `pi-hole` | docker | `urahara`, `zangetsu` | `platform` |
| `tailscale` | docker | `urahara`, `zangetsu` | `platform` |
| `traefik` | docker | `zangetsu` | `platform` |
| `vaultwarden` | docker | `zangetsu` | `platform` |
| `watchtower` | docker | `urahara`, `zangetsu` | `platform` |
| `home-assistant` | docker | `urahara` | `smart-home` |
| `calnode` | docker | `urahara` | `utilities` |
| `homepage` | docker | `zangetsu` | `utilities` |
| `it-tools` | docker | `urahara` | `utilities` |
| `openspeedtest` | docker | `zangetsu` | `utilities` |
| `qbittorrent` | docker | `urahara` | `utilities` |
| `thalesmachado-net` | docker | `zangetsu` | `utilities` |
| `trilium` | docker | `urahara` | `utilities` |
| `vikunja` | docker | `urahara` | `utilities` |

<!-- inventory:end -->

## Two ways in

**LAN**, `*.lan.thalespm.me`: Pi-hole answers with the host's address, so the
name never resolves publicly, and Traefik still terminates real TLS using a
Let's Encrypt wildcard issued over DNS-01 through Cloudflare. No internal CA,
no certificate warnings on any device.

**Internet**, `*.thalespm.me`: DockFlare writes Cloudflare Tunnel routes
straight from Docker labels, so publishing a service is a label rather than a
firewall rule. No port is open on the router. Cloudflare Access with MFA
guards the sensitive ones; the handful of exceptions are listed, each with
its reason, in [`CONVENTIONS.md`](CONVENTIONS.md).

## Staying alive

Databases are never backed up by copying their files. Dagu takes a consistent
snapshot first, `.backup` for SQLite and `pg_dump` for Postgres, and Restic's
pass over `/opt` and `/etc` explicitly excludes the live data directories.
One repository per host on the NAS, never shared. Every scheduled job pings
Healthchecks, because a job that stops running is the one failure a scheduler
does not report by itself.

Metrics go to VictoriaMetrics and are read through Grafana; logs go from
Grafana Alloy to Loki with fifteen days of retention; Uptime Kuma watches the
endpoints and Scrutiny the disks. Alerts reach a phone over WhatsApp.

Adding or removing a service means walking a checklist, because monitoring
gaps are silent by construction: an alert once survived months pointing at a
container that no longer existed.

## Decisions worth reading

The rules in this repository are mostly scar tissue. Four examples:

**The auto-update tool was replaced after it corrupted production.** Its HTTP
client serialised the whole container config as a URL query string instead of
a JSON body, which any proxy in front of the Docker socket rejects once the
URI grows: `414 URI Too Long`. It took down the public tunnel and the
dashboard. A second bug in the same tool coerced `postgres:16-alpine` into a
beta build and broke the databases. Watchtower came back, opt-in per label,
and images whose tag can be misread are deliberately left out of auto-update.

**A `.automount` unit took the whole Docker daemon down in a loop.** systemd
unmounts an idle automount, `docker.service` had `RequiresMountsFor` on that
path, and every idle cycle killed every container on the host and restarted
it. The mounts here are permanent, so the lazy semantics bought nothing. Now
they are plain `.mount` units.

**One CIFS option made every write fail while reads kept working.** With
`retrans=2` on kernel 6.12, the mount came up, listed files and read them,
and returned `Permission denied` on every write, including as root, while
`smbclient` with the same credentials wrote fine. It broke two applications
and both Restic repositories at once.

**A single-file bind mount serves stale config silently.** `git pull`
rewrites the file with a new inode; the container keeps the old handle and
goes on serving the previous content with no error anywhere. Those services
are recreated, never restarted, and the ones affected are listed.

The rest, with the symptom each produced, is in
[`CONVENTIONS.md`](CONVENTIONS.md) and the runbooks in [`docs/`](docs/).

## Where this is going

The top level is split by runtime. `docker/` is everything that runs today.
`k8s/` will hold a permanent cluster: **it is not built yet**, and nothing
depends on it. The plan and the decisions already taken are in
[`docs/kubernetes-platform.md`](docs/kubernetes-platform.md).

One rule decides what will ever move there: *what you use to repair cannot
depend on what broke*. Tailscale is how the house is reached from outside,
Pi-hole is its DNS, Komodo deploys, Dagu runs the backups, and the
observability stack is how a failure is noticed. A cluster outage that took
those with it would take the repair tools too, so they stay in Docker. That
is bootstrap order, not caution.

## The repository

```text
docker/hosts/<host>/compose.yaml       entry point per host: include: list and overrides
docker/services/<category>/<service>/  one self-contained Compose fragment per service
k8s/                                   planned, see docs/kubernetes-platform.md
scripts/                               setup, backup, networking, inventory, systemd units
terraform/healthchecks/                Healthchecks.io checks as code
.github/workflows/                     validation, secret scanning, deploy, DNS sync
docs/                                  runbooks: backup, Komodo, Traefik/DockFlare, Wolf, k8s
```

Every push runs **validate** (yamllint, `docker compose config` against each
host's `.env.example`, shellcheck, `py_compile`, `terraform fmt -check` and
the inventory check) and **secrets** (gitleaks over the full history, plus a
weekly pass). The same checks run before a commit leaves the machine:

```bash
pipx install pre-commit && pre-commit install
pre-commit run --all-files
```

## License

All rights reserved. See [`LICENSE`](LICENSE).
