#!/bin/sh
# Filesystem backup (/opt + /etc) via Restic.
#
# Repository: /mnt/backup/<host> (CIFS mount of nas-drive), seen as /repo in
# the container; only RESTIC_PASSWORD is needed. Run by the restic-backup-* DAGs
# after the database snapshot DAGs.
#
# Usage: backup-restic.sh <host-tag>

set -eu

HOST_TAG="${1:?usage: backup-restic.sh <host-tag>}"
EXCLUDE_FILE="/opt/homelab/scripts/backup/restic-excludes.txt"

export RESTIC_REPOSITORY="/repo"

# first run initializes the repo
if ! restic cat config > /dev/null 2>&1; then
    echo "Empty repository - initializing..."
    restic init
fi

# Fixed --host: the container hostname is random, and without it restic finds
# no parent snapshot and rehashes everything on every run.
restic backup /source/opt /source/etc \
    --host "$HOST_TAG" \
    --exclude-file="$EXCLUDE_FILE" \
    --tag "$HOST_TAG"
