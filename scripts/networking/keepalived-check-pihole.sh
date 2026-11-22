#!/bin/sh
# keepalived track script: does the Pi-hole on THIS host still answer DNS?
#   exit 0 -> healthy, node keeps the VIP
#   exit 1 -> unhealthy, instance goes FAULT and releases the VIP to the peer
# Runs inside the keepalived container (network_mode: host, so 127.0.0.1:53 is
# the host's own Pi-hole).
# Probes in order of strength: a real query first, a TCP connect last. The
# connect only proves FTL is listening, which still catches the case this
# exists for (container dead or crash-looping on a live host).
# Fails OPEN if none of them is available: a check that cannot run would fault
# both nodes at once and take the VIP off the LAN.
set -u

NAME="${CHECK_NAME:-pi.hole}"
SERVER="127.0.0.1"

if command -v dig >/dev/null 2>&1; then
  dig +short +time=2 +tries=1 "@$SERVER" "$NAME" A >/dev/null 2>&1 || exit 1
elif command -v nslookup >/dev/null 2>&1; then
  nslookup -timeout=2 "$NAME" "$SERVER" >/dev/null 2>&1 || exit 1
elif command -v host >/dev/null 2>&1; then
  host -W 2 "$NAME" "$SERVER" >/dev/null 2>&1 || exit 1
elif command -v nc >/dev/null 2>&1; then
  nc -z -w 2 "$SERVER" 53 >/dev/null 2>&1 || exit 1
elif command -v bash >/dev/null 2>&1; then
  bash -c "exec 3<>/dev/tcp/$SERVER/53" >/dev/null 2>&1 || exit 1
else
  echo "keepalived-check-pihole: no probe available in image, failing open" >&2
fi

exit 0
