# Backlog

Open items that are not conventions and not quirks: things known to be wrong or
unfinished, with enough context to pick them up cold. Delete an entry when it is
done; delete this file when it is empty.

## Calnode cannot read calendar availability (2026-11-19)

Booking a slot fails with "Calendar Availability could not be checked", and the
container logs `gcal: freeBusy status 403`. A 403 there is either the Google
Calendar API not being enabled on the GCP project that issued Calnode's OAuth
client, or a token issued without the scope `freeBusy` needs.

Triage in that order. Enable the API in the console first: an already-issued
token keeps working, so that fix needs nothing else. If the API is already
enabled, it is the scope, and the console cannot fix it: disconnect the
calendar inside Calnode and connect it again, because an existing token never
gains a scope retroactively. The body of the Google error names which one it is
(`accessNotConfigured` against `insufficientPermissions`); read it before
changing anything.

## Wolf image pins are behind (2026-11-01)

`wolf-image-check` has been down since 2026-11-01, which is the check doing its
job: at least one of the four pinned digests (`wolf`, `wolf-ui`, `retroarch`,
`es-de`) moved on GHCR, and `es-de` is roughly six months old. `DRY_RUN=1 sh
scripts/monitoring/check-wolf-image-updates.sh` lists exactly which, without
touching Healthchecks. Bumping them needs a real stream test, so it is a session
of its own, and the reply to upstream issue #576 waits for it.

## Dead duplicates in zangetsu's ~/.bashrc (2026-11-19)

`hlab`, `homelab-cp` and `tf` are now versioned in
`scripts/shell/homelab-functions.sh`, which `~/.bashrc` sources at the end, so
the versioned definitions win. The older copies above that line still exist and
are inert. They are worth removing: a drifted duplicate that silently loses to
the one below it is exactly what cost half a day on 2026-11-19, when a fix was
applied to the copy that never runs.

## Uptime Kuma: empty groups are pruned by hand (2026-11-19)

`setup-uptime-kuma.py` skips anything of type `group`, so a group never gets
deleted by mistake. The cost showed up when the two lab monitors left and
`Lab K8s` stayed behind with zero children, reporting `Child inaccessible`
until it was removed by hand. The criterion for automating it is safe and was
measured that day: of the fourteen groups, only the lab's had zero children,
every other one had between one and sixteen.

## Uptime Kuma: every deploy registers a down event (2026-11-19)

Recreating Traefik, Grafana, Loki or Dagu makes their monitors go down and
alert. Measured rather than assumed: those monitors already run `maxretries 3`
with `retry_interval 20`, so Uptime Kuma waits a full minute, and Traefik was
still out for ninety seconds during the deploy on the night of 11-18. Now that
every push deploys both hosts, this gets more frequent.

So it is a trade-off, not a misconfiguration. Absorbing a deploy needs five or
six retries, which delays a real outage alert from one minute to two. The
alternative is an automatic maintenance window around a deploy: it delays
nothing and costs real work. Decide with these numbers, not by impression.

## Uptime Kuma: 1.x recomputes uptime from the raw table (2026-11-19)

1.x has no aggregate tables, so every monitor-list emit runs one aggregate per
monitor over the whole `heartbeat` table. At 6.6M rows in a 963 MB file that
stopped finishing inside the socket timeout and took the dashboard down with
it. Retention was cut to 30 days and the database shrank to 296 KB, which
contains the problem rather than curing it.

2.x adds `stat_minutely`, `stat_hourly` and `stat_daily` for exactly this. It
is a major upgrade with a schema migration, so it needs its own plan, and
Watchtower will not do it on its own: upstream still points `:latest` at the
1.x line.

## CIFS mounts fail on the first attempt at boot, on urahara (2026-11-19)

The reboot of 11-19 fired `OnFailure=` for `mnt-media-immich` and
`mnt-media-paperless` at 19:02:49, and both were `active mounted` minutes
later without anyone touching them. So the mount units try before the network
is ready, fail, and something mounts them afterwards.

That makes every reboot produce a mount-failure alert that is not real, which
is the fastest way to teach yourself to ignore the one that is. Worth finding
out what ordering they need (`After=network-online.target` is the obvious
suspect, and the host already proved that target unreliable, see the Docker
network delay in CONVENTIONS) and what retries them today.

## Commit f284b56 has a placeholder subject

It landed on `main` as `Generating commit message...`, the IDE's temporary text.
Fixing it means rewriting published history, which this repo deliberately does
not do. Left as is unless the public history matters more than the rule.

## Alert review, after the first application (2026-11-23)

Agreed while building `seireitei`: review every alert once something real runs
on it. Three items came out of the build itself and have nowhere else to live.

**Pi-hole HA now hides a dead Pi-hole.** The keepalived track script moves the
VIP in about 15 seconds, so a failed Pi-hole stops being visible at all until
the second one also dies. A Grafana rule over the log Alloy already collects
closes it: `{container="keepalived"} |= "Entering FAULT STATE"`. Few lines, and
it reuses the contact point that already exists.

**Control-plane restarts are not watched.** `kube-apiserver-urahara` reached 14
restarts in the first 12 seconds after `kubeadm init`, while etcd was still
coming up, and then stayed at 14. Benign on that day, but PM-0010 was exactly a
control plane in a restart loop and nothing was looking. The lab had
`k8s-lab-control-plane-restart`; `seireitei` has no equivalent yet.

**Do not probe a LoadBalancer address with ICMP.** Cilium answers ARP for
`.241`-`.246` and forwards only the ports the Service declares, so `ping` fails
by design. Confirmed in production on 2026-11-23: HTTP 200 and 100% packet loss
at the same instant. An Uptime Kuma ping check against a cluster service would
be a permanent false alert.

## cfgate is not monitored yet (2026-11-23)

The service checklist was deliberately deferred, not skipped: cfgate is alpha
and may be removed, so the Uptime Kuma entry and the scrape job wait until the
canary has held for a few days. Writing it down because this is exactly the gap
the checklist exists to prevent.

Three pieces when it stays: the controller's metrics on 8080 in `cfgate-system`
need a NodePort Service to be reachable from the VictoriaMetrics in Docker, the
same way `kube-state-metrics` is exposed on 30808; a `job_name` in
`prometheus.yml`; and two monitors in `setup-uptime-kuma.py`, one on
`cfgate.thalesmachado.net` with a keyword check for `canary ok` and one on
whatever real hostname the tunnel serves, because a single check cannot tell
the tunnel and the app apart. The connector's own listener (44483) carries metrics, probes and
diagnostics together, and its readiness does not establish origin reachability,
so it is not a substitute for an end-to-end check.

## No deploy has run since 99a740f (2026-11-23)

Found while moving the site off zangetsu: `/opt/homelab` there was three
commits behind, and the containers had been created from that stale clone. The
Komodo webhook fires from `ci.yaml` after `[yaml, compose, shell, python]`, and
`inventory`/`terraform` do not gate it, so either one of those four jobs is red
or the `curl -f` to the webhook is failing - which the Komodo doc describes as
exit 22 on a `KOMODO_HOMELAB_<HOST>_WEBHOOK_SECRET` mismatch, silent until
someone opens the run. Not diagnosed yet: open the Actions run for `bc156f8`
and look at which job is red. This affects every future commit on both hosts,
not just the site.

Recovery used on zangetsu, straight from `docs/komodo.md`: `sudo chown -R
keydrop:keydrop /opt/homelab`, then `git fetch && git reset --hard
origin/main`. Periphery writes as root, so the ownership drifts back on the
next deploy; that is expected, not a fix to repeat preemptively.
