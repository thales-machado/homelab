#!/usr/bin/env python3
"""
Homelab - Uptime Kuma Status Page
=================================
Builds the public status page /status/homelab from STATUS_PAGE_GROUPS (the
source of truth). It references the individual monitors, never the internal
Group monitors: the public API only returns an aggregated heartbeat for a
Group. Idempotent: the whole publicGroupList is overwritten on every run.

Usage:
  pip install uptime-kuma-api
  python3 setup-uptime-kuma-status-page.py
"""

import os
import sys

from uptime_kuma_api import UptimeKumaApi

UPTIME_KUMA_URL  = os.getenv("UK_URL",  "http://192.168.15.214:3001")
UPTIME_KUMA_USER = os.getenv("UK_USER", "keydrop")
UPTIME_KUMA_PASS = os.getenv("UK_PASS", "")

STATUS_PAGE_SLUG = "homelab"

# =============================================================================
# STATUS_PAGE_GROUPS
# Monitor names must match MONITORS in setup-uptime-kuma.py exactly.
# Group names are what the public page shows.
# =============================================================================
STATUS_PAGE_GROUPS = [
    ("Platform", [
        "Komodo",
        "DockFlare",
        "Watchtower (zangetsu)",
        "Watchtower (urahara)",
        "Vaultwarden",
    ]),
    ("Network", [
        "Traefik",
        "Pi-hole",
    ]),
    ("Observability", [
        "Uptime Kuma",
        "Grafana",
        "VictoriaMetrics",
        "Loki",
        "Crowdsec",
    ]),
    ("Automation", [
        "N8N",
        "Dagu",
    ]),
    ("Content", [
        "Immich",
        "Paperless-ngx",
    ]),
    ("Utilities", [
        # public without MFA, so it can also be linked as a live demo
        "IT-Tools",
    ]),
]

# Tailscale and Restic have no monitor on purpose (no HTTP/TCP endpoint;
# Restic is a batch job covered by Healthchecks). Do not add fake monitors.


def main():
    if not UPTIME_KUMA_PASS:
        print("❌ Set UK_PASS before running:\n   export UK_PASS='your-password'")
        raise SystemExit(1)

    print(f"\n🔗 Connecting to {UPTIME_KUMA_URL}...")
    api = UptimeKumaApi(UPTIME_KUMA_URL)

    print(f"🔑 Logging in as '{UPTIME_KUMA_USER}'...")
    api.login(UPTIME_KUMA_USER, UPTIME_KUMA_PASS)
    print("✅ Logged in!\n")

    existing = api.get_monitors()
    by_name = {m["name"]: m["id"] for m in existing}

    public_group_list = []
    missing = []
    for weight, (group_name, monitor_names) in enumerate(STATUS_PAGE_GROUPS):
        monitor_list = []
        for name in monitor_names:
            mid = by_name.get(name)
            if mid is None:
                missing.append(name)
                continue
            monitor_list.append({"id": mid})
        public_group_list.append({
            "name": group_name,
            "weight": weight,
            "monitorList": monitor_list,
        })

    if missing:
        print(f"⚠️  Monitor(s) not found, skipped: {', '.join(missing)}")
        print("    (run setup-uptime-kuma.py first if they are new)\n")

    print(f"📄 Saving status page '{STATUS_PAGE_SLUG}'...")
    api.save_status_page(STATUS_PAGE_SLUG, publicGroupList=public_group_list)

    total = sum(len(g["monitorList"]) for g in public_group_list)
    print(f"✅ {len(public_group_list)} groups, {total} individual monitors published.")
    print(f"   Check: {UPTIME_KUMA_URL.replace('3001', '80')}/status/{STATUS_PAGE_SLUG}")

    api.disconnect()


if __name__ == "__main__":
    main()
