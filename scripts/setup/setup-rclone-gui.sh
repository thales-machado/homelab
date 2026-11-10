#!/bin/bash
# Downloads the official rclone web GUI (rclone-web) to /opt/apps/rclone/gui,
# served by the mount's own rc via --rc-files (see rclone.yaml). Replaces
# --rc-web-gui, which crashes the process since 1.76 (`rclone gui` starts a
# separate rc). Watchtower does not update it: rerun for a new release. urahara.
set -euo pipefail

DEST=/opt/apps/rclone/gui
TAG=$(curl -fsSL https://api.github.com/repos/rclone/rclone-web/releases/latest \
  | python3 -c 'import sys, json; print(json.load(sys.stdin)["tag_name"])')

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/dist.zip" "https://github.com/rclone/rclone-web/releases/download/${TAG}/dist.zip"
python3 -m zipfile -e "$TMP/dist.zip" "$TMP/gui"
test -f "$TMP/gui/index.html"

rm -rf "${DEST}.new"
mv "$TMP/gui" "${DEST}.new"
rm -rf "$DEST"
mv "${DEST}.new" "$DEST"
echo "rclone-web ${TAG} installed in ${DEST}"
