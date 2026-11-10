#!/bin/bash
# Provisions the homelab NAS (CIFS) mounts:
#   1. Credentials (/etc/.nas-credentials) from the .env
#   2. systemd units versioned in scripts/systemd/
#   3. docker.service drop-in so Docker only starts once the mounts are ready
# Requires sudo; run manually.
# Rerun whenever the QNAP password or the units change.
set -euo pipefail

REPO_DIR="/opt/homelab"
ENV_FILE="${HOMELAB_ENV:?HOMELAB_ENV is not set}"
UNITS_DIR="$REPO_DIR/scripts/systemd"
SYSTEMD_DIR="/etc/systemd/system"
HOST_NAME="$(basename "$(dirname "$ENV_FILE")")"

# --- 1. CIFS credentials ---
QNAP_USER=$(grep '^QNAP_USER=' "$ENV_FILE" | cut -d'=' -f2)
QNAP_PASSWORD=$(grep '^QNAP_PASSWORD=' "$ENV_FILE" | cut -d'=' -f2)

if [[ -z "$QNAP_USER" || -z "$QNAP_PASSWORD" ]]; then
  echo "Error: QNAP_USER or QNAP_PASSWORD not found in .env"
  exit 1
fi

sudo bash -c "cat > /etc/.nas-credentials << EOF
username=${QNAP_USER}
password=${QNAP_PASSWORD}
domain=WORKGROUP
EOF"
sudo chmod 600 /etc/.nas-credentials
echo "✓ credentials file updated"

# --- 2. systemd units ---
# Fixed .mount, never automount: with RequiresMountsFor an idle unmount takes
# Docker down. Each host installs only the units it uses.
case "$HOST_NAME" in
  urahara)
    UNITS=(
      "mnt-media-immich.mount:mnt-media-immich.mount"
      "mnt-media-paperless.mount:mnt-media-paperless.mount"
      "mnt-backup-urahara.mount:mnt-backup-urahara.mount"
      "mnt-downloads-qbittorrent\x2dgeral.mount:mnt-downloads-qbittorrent-geral.mount"
      "notify-immich-mount-failure.service:notify-immich-mount-failure.service"
      "notify-paperless-mount-failure.service:notify-paperless-mount-failure.service"
      "notify-backup-urahara-mount-failure.service:notify-backup-urahara-mount-failure.service"
      "notify-qbittorrent-geral-mount-failure.service:notify-qbittorrent-geral-mount-failure.service"
    )
    MOUNT_UNITS=(mnt-media-immich mnt-media-paperless mnt-backup-urahara "mnt-downloads-qbittorrent\x2dgeral")
    CONF_SRC="nas-mounts-urahara.conf"
    DF_PATHS="/mnt/media/immich /mnt/media/paperless /mnt/backup/urahara /mnt/downloads/qbittorrent-geral"
    ;;
  zangetsu)
    UNITS=(
      "mnt-backup-zangetsu.mount:mnt-backup-zangetsu.mount"
      "notify-backup-zangetsu-mount-failure.service:notify-backup-zangetsu-mount-failure.service"
    )
    MOUNT_UNITS=(mnt-backup-zangetsu)
    CONF_SRC="nas-mounts-zangetsu.conf"
    DF_PATHS="/mnt/backup/zangetsu"
    ;;
  *)
    echo "Error: unknown host ($HOST_NAME) - add a case for it in this script"
    exit 1
    ;;
esac

for entry in "${UNITS[@]}"; do
  dest_name="${entry%%:*}"
  src_name="${entry##*:}"
  sudo cp "$UNITS_DIR/$src_name" "$SYSTEMD_DIR/$dest_name"
  echo "✓ unit installed: $dest_name"
done

# sudo: the checkout is owned by root (Komodo)
sudo chmod +x "$REPO_DIR/scripts/networking/notify-mount-failure.sh"

# --- 3. docker.service drop-in ---
sudo mkdir -p /etc/systemd/system/docker.service.d
sudo cp "$UNITS_DIR/docker.service.d/$CONF_SRC" /etc/systemd/system/docker.service.d/nas-mounts.conf
echo "✓ drop-in installed: docker.service.d/nas-mounts.conf ($CONF_SRC)"

sudo systemctl daemon-reload

# Stop a .mount only when migrating from an old automount. NEVER stop an active,
# correct .mount: through RequiresMountsFor the stop reaches docker.service.
for mount_unit in "${MOUNT_UNITS[@]}"; do
  if systemctl is-active --quiet "${mount_unit}.automount" || \
     systemctl is-enabled --quiet "${mount_unit}.automount" 2>/dev/null; then
    sudo systemctl stop "${mount_unit}.automount" 2>/dev/null || true
    sudo systemctl disable "${mount_unit}.automount" 2>/dev/null || true
    sudo systemctl stop "${mount_unit}.mount" 2>/dev/null || true
  fi
  if sudo systemctl enable --now "${mount_unit}.mount"; then
    echo "✓ mount active: ${mount_unit}"
  else
    echo "✗ failed to enable mount: ${mount_unit} - see journalctl -xe"
  fi
done

echo "OK - verify with: df -h $DF_PATHS"
echo "Note: the docker.service drop-in only takes effect on the next docker.service restart (e.g. reboot)."
echo "      docker.service was not restarted automatically because that restarts every container."
