#!/bin/bash
# Creates the seireitei Secrets from the host's .env. The values never enter
# Git, only this procedure does. Bridge until the .env migration picks one tool
# for both runtimes; see "Secrets" in docs/kubernetes-platform.md.
# Idempotent: rerun after rotating a value in .env.
set -euo pipefail

# sudo does not inherit /etc/environment, same as setup-keepalived.sh.
ENV_FILE="${HOMELAB_ENV:-}"
if [ -z "$ENV_FILE" ] && [ -r /etc/environment ]; then
  ENV_FILE=$(grep -E '^HOMELAB_ENV=' /etc/environment | tail -1 | cut -d= -f2- | tr -d '"')
fi
: "${ENV_FILE:?HOMELAB_ENV is not set and not present in /etc/environment}"

# kubectl under sudo has no kubeconfig of its own, and root can read the admin
# one. Without this the checks below fail for lack of credentials and look like
# a missing namespace.
if [ -z "${KUBECONFIG:-}" ] && [ "$(id -u)" -eq 0 ] && [ -r /etc/kubernetes/admin.conf ]; then
  export KUBECONFIG=/etc/kubernetes/admin.conf
fi

if ! kubectl get --raw=/healthz >/dev/null 2>&1; then
  echo "Error: kubectl cannot reach the cluster (KUBECONFIG=${KUBECONFIG:-unset})" >&2
  exit 1
fi

read_env() {
  local val
  val=$(grep -E "^${1}=" "$ENV_FILE" | tail -1 | cut -d= -f2-)
  [ -n "$val" ] || { echo "Error: $1 not found in $ENV_FILE" >&2; return 1; }
  printf '%s' "$val"
}

# value over stdin, never as an argument: arguments are visible in ps
put_secret() {
  local ns="$1" name="$2" key="$3"
  kubectl create secret generic "$name" -n "$ns" \
    --from-file="${key}=/dev/stdin" --dry-run=client -o yaml \
    | kubectl apply -f - >/dev/null
  echo "  ok  ${ns}/${name}"
}

echo "==> cert-manager"
if kubectl get namespace cert-manager >/dev/null 2>&1; then
  read_env CF_API_TOKEN | put_secret cert-manager cloudflare-api-token api-token
else
  echo "  skipped: namespace cert-manager does not exist" >&2
fi
