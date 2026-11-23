#!/bin/bash
# Installs the seireitei metrics-reader token where VictoriaMetrics reads it.
# Runs on zangetsu: the token lives in the cluster, kubectl lives on urahara,
# and the file belongs next to the other VictoriaMetrics secrets.
# Rerun if the ServiceAccount or its Secret is recreated.
set -euo pipefail

REMOTE="${REMOTE:-keydrop@192.168.15.215}"
DEST=/opt/apps/victoriametrics/secrets/seireitei-token

token=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE" \
  "kubectl -n observability get secret metrics-reader -o jsonpath='{.data.token}'")
[ -n "$token" ] || { echo "Error: empty token from $REMOTE" >&2; exit 1; }

# only the write needs root; the ssh must stay as the invoking user, whose key
# is the one urahara knows
printf '%s' "$token" | base64 -d | sudo tee "$DEST" >/dev/null
sudo chmod 0600 "$DEST"
echo "ok  $DEST ($(sudo wc -c <"$DEST") bytes)"
echo "now: cd /opt/homelab/docker/hosts/zangetsu && docker compose restart victoriametrics"
