# shellcheck shell=bash
# Interactive shell helpers, sourced from ~/.bashrc on every host:
#   source /opt/homelab/scripts/shell/homelab-functions.sh
# Not executable on purpose: it defines functions, it does not run anything.

HOMELAB_ROOT="${HOMELAB_ROOT:-/opt/homelab}"

# docker compose for this host's own stack, from anywhere.
hlab() {
  local dir
  dir="$HOMELAB_ROOT/docker/hosts/$(hostname -s)"
  local sub="$1"
  if [ "$sub" = "up" ] || [ "$sub" = "down" ]; then
    shift
    (cd "$dir" && docker compose "$sub" --remove-orphans "$@")
  else
    (cd "$dir" && docker compose "$@")
  fi
}

if command -v docker >/dev/null 2>&1; then
  eval "$(docker completion bash)"

  _hlab_completion() {
    local file
    file="$HOMELAB_ROOT/docker/hosts/$(hostname -s)/compose.yaml"
    local prefix="docker compose -f $file "
    local rest="${COMP_LINE:5}"
    COMP_POINT=$(( COMP_POINT - 5 + ${#prefix} ))
    COMP_LINE="${prefix}${rest}"
    COMP_WORDS=(docker compose -f "$file" "${COMP_WORDS[@]:1}")
    COMP_CWORD=$((COMP_CWORD + 3))
    __start_docker
  }
  complete -o default -F _hlab_completion hlab
fi

# Config that is copied to /opt/apps/ instead of bind-mounted from the repo.
# Absolute paths: this has to work from any cwd, not only from the repo root.
homelab-cp() {
  cp "$HOMELAB_ROOT"/icons/* /opt/apps/homepage/icons/ &&
  cp "$HOMELAB_ROOT"/docker/services/utilities/homepage/config/* /opt/apps/homepage/ &&
  cp "$HOMELAB_ROOT"/docker/services/observability/metrics/victoriametrics/prometheus.yml \
     /opt/apps/victoriametrics/prometheus.yml
}

# terraform in a container, on cloudflare-net so it can reach private services.
# Usage: tf <project> <terraform args...>   e.g.  tf healthchecks plan
tf() {
  local proj="$1"; shift
  local envf="${HOMELAB_ENV:?HOMELAB_ENV is not set on this host}"
  local account traefik_ip

  # The S3 backend talks to Cloudflare R2, whose endpoint carries the account id.
  # backend.tf reads it from the environment so the id stays out of git.
  account=$(grep '^CF_ACCOUNT_ID=' "$envf" | cut -d= -f2-)
  [ -n "$account" ] || { echo "tf: CF_ACCOUNT_ID missing from $envf" >&2; return 1; }

  # *.lan.thalespm.me resolves through Pi-hole, which the container cannot reach.
  # Resolve Traefik's address on the host instead of hardcoding it.
  traefik_ip=$(docker inspect -f \
    '{{(index .NetworkSettings.Networks "cloudflare-net").IPAddress}}' traefik 2>/dev/null)
  [ -n "$traefik_ip" ] || { echo "tf: no traefik container on this host" >&2; return 1; }

  docker run --rm -it \
    --network cloudflare-net \
    --add-host healthchecks.lan.thalespm.me:"$traefik_ip" \
    -v "$HOMELAB_ROOT/terraform/$proj:/workspace" -w /workspace \
    -e AWS_ENDPOINT_URL_S3="https://${account}.r2.cloudflarestorage.com" \
    -e AWS_ACCESS_KEY_ID="$(grep '^R2_ACCESS_KEY_ID=' "$envf" | cut -d= -f2-)" \
    -e AWS_SECRET_ACCESS_KEY="$(grep '^R2_SECRET_ACCESS_KEY=' "$envf" | cut -d= -f2-)" \
    -e HEALTHCHECKSIO_API_KEY="$(grep '^HEALTHCHECKS_API_KEY=' "$envf" | cut -d= -f2-)" \
    hashicorp/terraform:latest "$@"
}
