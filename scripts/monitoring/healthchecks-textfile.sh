#!/bin/sh
# Publishes the state of every Healthchecks check as node-exporter textfile
# metrics, so "the backup job did not run" becomes a Grafana alert on the same
# path that already reaches a phone.
#
# Why this exists: Healthchecks notifies on the transition into down and never
# again. A check that stays red sends one message and goes quiet. postgres-backup
# sat red for 71 days that way, and sqlite-backup-urahara for 7, each after a
# single notification nobody saw twice.
#
# Why not the Prometheus endpoint Healthchecks ships: it carries the project key
# in the URL path, which cannot live in a public repo, and it reports nothing
# when Healthchecks itself is wedged. Here the key travels in a header, and
# node_textfile_mtime_seconds plus hc_scrape_timestamp_seconds expose this
# script dying, which a textfile metric would otherwise hide by serving its last
# value forever.
#
# Run by a systemd timer, not a Dagu DAG, so it survives Dagu being the thing
# that broke. See scripts/systemd/healthchecks-textfile.timer.
set -eu

OUT_DIR=/var/lib/node-exporter/textfile
OUT="$OUT_DIR/healthchecks.prom"
API="${HEALTHCHECKS_API:-http://192.168.15.214:8000}"

: "${HOMELAB_ENV:?HOMELAB_ENV is unset (the unit needs EnvironmentFile=/etc/environment)}"
KEY=$(grep '^HEALTHCHECKS_API_KEY=' "$HOMELAB_ENV" | cut -d= -f2-)
[ -n "$KEY" ] || { echo "HEALTHCHECKS_API_KEY is empty in $HOMELAB_ENV" >&2; exit 1; }

mkdir -p "$OUT_DIR"

# Written to a temporary file and renamed: node-exporter reads this file on its
# own schedule and must never see it half written.
curl -sf --max-time 20 -H "X-Api-Key: $KEY" "$API/api/v3/checks/" \
  | python3 -c '
import json, sys, time

data = json.load(sys.stdin)
checks = data.get("checks", [])
if not checks:
    sys.exit("Healthchecks returned no checks")

lines = [
    "# HELP hc_check_up 1 unless the check is in the down state.",
    "# TYPE hc_check_up gauge",
]
for c in checks:
    name = str(c.get("name", "")).replace("\\", "\\\\").replace("\"", "\\\"")
    lines.append("hc_check_up{name=\"%s\"} %d" % (name, 0 if c.get("status") == "down" else 1))

lines += [
    "# HELP hc_scrape_timestamp_seconds When this file was last written.",
    "# TYPE hc_scrape_timestamp_seconds gauge",
    "hc_scrape_timestamp_seconds %d" % time.time(),
    "",
]
sys.stdout.write("\n".join(lines))
' > "$OUT.tmp"

mv "$OUT.tmp" "$OUT"
