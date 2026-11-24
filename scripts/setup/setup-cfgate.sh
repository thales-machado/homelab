#!/usr/bin/env bash
# Creates the cfgate credential Secret and applies the tunnel, both of which
# carry values from the host .env and so cannot live in this public repo.
# Run on the cluster host (urahara) after Argo has created cfgate-edge.
set -euo pipefail

: "${HOMELAB_ENV:?HOMELAB_ENV is unset}"
[ -f "$HOMELAB_ENV" ] || { echo "env file not found: $HOMELAB_ENV" >&2; exit 1; }

# Reading two values instead of sourcing the whole file, like the other scripts
# here: nothing else from .env belongs in this process.
CF_API_TOKEN=$(grep '^CF_API_TOKEN=' "$HOMELAB_ENV" | cut -d= -f2-)
CF_ACCOUNT_ID=$(grep '^CF_ACCOUNT_ID=' "$HOMELAB_ENV" | cut -d= -f2-)
[ -n "$CF_API_TOKEN" ] || { echo "CF_API_TOKEN is empty in $HOMELAB_ENV" >&2; exit 1; }
[ -n "$CF_ACCOUNT_ID" ] || { echo "CF_ACCOUNT_ID is empty in $HOMELAB_ENV" >&2; exit 1; }

SRC="$(cd "$(dirname "$0")" && pwd)/cfgate"

kubectl get namespace cfgate-edge >/dev/null 2>&1 || {
  echo "namespace cfgate-edge does not exist yet; let Argo sync cfgate-config first" >&2
  exit 1
}

# The token never reaches argv: it goes in on stdin and out as a manifest.
printf '%s' "$CF_API_TOKEN" |
  kubectl create secret generic cloudflare-api-token \
    --namespace cfgate-edge \
    --from-file=CLOUDFLARE_API_TOKEN=/dev/stdin \
    --dry-run=client -o yaml |
  kubectl apply -f -

sed "s|__CF_ACCOUNT_ID__|${CF_ACCOUNT_ID}|" "$SRC/tunnel.yaml" | kubectl apply -f -

kubectl wait cloudflaretunnel/seireitei -n cfgate-edge --for=condition=Ready --timeout=300s
