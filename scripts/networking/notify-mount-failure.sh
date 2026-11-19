#!/bin/bash
# Notifies a NAS mount failure via the Homelab Notify (n8n) webhook.
# Usage: notify-mount-failure.sh <label>
# Called by the notify-*-mount-failure.service units via the mounts' OnFailure=.
set -euo pipefail

ENV_FILE="${HOMELAB_ENV:?HOMELAB_ENV is not set}"
MOUNT_LABEL="${1:?usage: notify-mount-failure.sh <label>}"

SECRET=$(grep '^N8N_WEBHOOK_SECRET=' "$ENV_FILE" | cut -d'=' -f2-)
NODE_HOSTNAME=$(grep '^NODE_HOSTNAME=' "$ENV_FILE" | cut -d'=' -f2-)
PAYLOAD="{\"action\":\"mount-failure\",\"mount\":\"${MOUNT_LABEL}\",\"host\":\"${NODE_HOSTNAME}\"}"

SIGNATURE="sha256=$(printf '%s' "$PAYLOAD" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $2}')"

# IP:port, never the name: this runs at boot, right when a mount failed, and
# Pi-hole and Traefik are not up yet. curl exited 6 (could not resolve) on
# 2026-11-19, so the alert meant for this moment could never fire.
curl -sS --retry 10 --retry-delay 15 --retry-connrefused --max-time 30 \
  -X POST "${N8N_WEBHOOK:-http://192.168.15.215:8097/webhook/homelab-notify}" \
  -H "Content-Type: application/json" \
  -H "X-Hub-Signature-256: ${SIGNATURE}" \
  -d "$PAYLOAD"
