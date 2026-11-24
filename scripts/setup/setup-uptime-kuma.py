#!/usr/bin/env python3
"""
Homelab - Uptime Kuma Monitor Setup
====================================
Syncs Uptime Kuma with MONITORS and DOCKER_MONITORS (the source of truth):
creates what is missing and deletes orphans. Run it after every edit.

Usage (needs the API and kuma.db mounted read-only, see get_monitors() below):
  docker run --rm --network cloudflare-net \
    -v /opt/apps/uptime-kuma:/app/data:ro \
    -v /opt/homelab/scripts/setup:/s:ro \
    -e UK_URL=http://uptime-kuma:3001 -e UK_PASS=... \
    python:3-slim sh -c "pip install -q uptime-kuma-api && python3 /s/setup-uptime-kuma.py"
"""

import os
import sqlite3
import sys
from socketio.exceptions import TimeoutError as SocketTimeout
from uptime_kuma_api.exceptions import Timeout as KumaTimeout
from uptime_kuma_api import UptimeKumaApi, MonitorType, NotificationType, DockerType

# api.get_monitors() hangs forever in production (any lib version), so the
# monitor list is read from SQLite (read-only). Mutations still use the API,
# except that delete_monitor() validates the id by calling get_monitors()
# itself: see prune_stale_monitors().
KUMA_DB_PATH = os.getenv("UK_DB_PATH", "/app/data/kuma.db")

# --- CONFIG (environment variables, with fallbacks) ---
UPTIME_KUMA_URL  = os.getenv("UK_URL",  "http://192.168.15.214:3001")
UPTIME_KUMA_USER = os.getenv("UK_USER", "keydrop")
UPTIME_KUMA_PASS = os.getenv("UK_PASS", "")

DEFAULT_INTERVAL     = 60
DEFAULT_RETRIES      = 3
DEFAULT_RETRY_INTERVAL = 20

# Default notification: WhatsApp through the n8n "Homelab Notify" workflow.
# n8n runs on urahara, so it is reached by IP:port (container names do not
# resolve across hosts).
NOTIFICATION_NAME = "WhatsApp - Homelab Notify"
NOTIFICATION_WEBHOOK_URL = "http://192.168.15.215:8097/webhook/homelab-notify"

# --- MONITORS ---
# (name, url, group, interval[, statuscodes, ignore_tls, tcp_port, dns_server])
# Container names work for zangetsu services; urahara services use IP:port.
MONITORS = [
    # --- Management ---
    ("Komodo",           "http://komodo-core:9120",       "Management",    60),
    ("DockFlare",        "http://dockflare:5000/ping",    "Management",    60),
    # Watchtower's HTTP API needs a token on every route: TCP check.
    ("Watchtower (zangetsu)", "watchtower",       "Management", 60, None, False, 8080),
    ("Watchtower (urahara)",  "192.168.15.215",   "Management", 60, None, False, 8084),

    # --- Security ---
    ("Vaultwarden",      "https://vaultwarden.thalespm.me", "Security",  120),

    # --- Finance ---
    ("Firefly III",      "http://firefly-iii:8080",       "Finance",       60),
    ("FIDI",             "http://fidi:8080",              "Finance",       60),

    # --- Automation ---
    ("N8N",              "http://192.168.15.215:8097/healthz", "Automation", 60),
    ("Dagu",              "http://dagu:8080",             "Automation",    60),

    # --- Integration ---
    ("Evolution API",    "http://192.168.15.215:8094",    "Integration",   60),

    # --- Network ---
    # TCP on 443 avoids internal TLS/SNI issues.
    ("Traefik",           "traefik",                      "Network",       30,  None, False, 443),
    ("Pi-hole",          "http://pi-hole:80/admin",       "Network",       60),
    # /ready is 200 only when a tunnel connection is registered.
    ("Cloudflare Tunnel", "http://cloudflared-agent-lemonpi-5-tunel:2000/ready", "Network", 60),
    # only port 53 is published on urahara.
    ("Pi-hole (urahara)", "192.168.15.215", "Network", 60, None, False, 53),
    # End-to-end check of the HA layer: a real DNS query against the VIP.
    # The image healthcheck stays "healthy" even when FTL is hung.
    ("Pi-hole VIP (HA)",  "pihole.lan.thalespm.me", "Network", 60, None, False, None, "192.168.15.248"),
    # dockflare-agent has no endpoint: TCP on its docker-socket-proxy.
    ("DockFlare Agent (urahara)", "192.168.15.215", "Network", 60, None, False, 2375),

    # --- Observability ---
    ("Dozzle",           "http://dozzle:8080",            "Observability", 60),
    ("Uptime Kuma",      "http://uptime-kuma:3001",       "Observability", 30),
    ("Grafana",           "http://grafana:3000/api/health", "Observability", 60),
    ("VictoriaMetrics",   "http://victoriametrics:8428/health", "Observability", 60),
    ("Loki",              "http://loki:3100/ready",       "Observability", 60),
    ("Scrutiny",          "http://scrutiny:8080",         "Observability", 60),
    ("Healthchecks",      "http://healthchecks:8000",     "Observability", 60),
    # Crowdsec LAPI needs X-Api-Key on every route: TCP check.
    ("Crowdsec",         "192.168.15.215",                "Observability", 60, None, False, 8082),

    # --- Utilities ---
    ("Homepage",         "http://homepage:3000",          "Utilities",     60),
    # no cluster desde 2026-11-23: pelo hostname, exercitando DNS + Gateway + TLS
    ("OpenSpeedTest",    "https://speedtest.lan.thalespm.me", "Utilities",  60),
    ("IT-Tools",         "https://it-tools.lan.thalespm.me",  "Utilities",  60),
    ("Calnode",          "http://192.168.15.215:8093",    "Utilities",     60),
    ("Vikunja",          "http://192.168.15.215:3456",    "Utilities",     60),
    ("TriliumNext",      "http://192.168.15.215:8091",    "Utilities",     60),
    ("qBittorrent",      "http://192.168.15.215:8095",    "Utilities",     60),
    # Wolf: TCP on 47989 (pairing); the stream itself is UDP.
    ("Wolf",             "192.168.15.215",                "Utilities",     60, None, False, 47989),

    # --- Content ---
    ("Immich",            "http://192.168.15.215:2283",   "Content",       60),
    ("Paperless-ngx",     "http://192.168.15.215:8000",   "Content",       60),
    ("Stirling PDF",      "http://192.168.15.215:8080",   "Content",       60),
    # SMB only: TCP on 445.
    ("Samba",             "192.168.15.215",               "Content",       60, None, False, 445),
    ("TandoorRecipes",    "http://192.168.15.215:8083",   "Content",       60),

    # --- Smart Home ---
    ("Home Assistant",    "http://192.168.15.215:8123",   "Smart Home",    60),

    # --- External / Public ---
    ("N8N (public)",          "https://n8n.thalespm.me",          "External", 120),
    ("Vaultwarden (public)",  "https://vaultwarden.thalespm.me",  "External", 120),
    # no cluster desde 2026-11-23, servido pelo tunel do cfgate
    ("thalesmachado.net",     "https://thalesmachado.net",        "External", 60),
    # canary permanente: separa o caminho publico (tunel) da aplicacao, para um
    # incidente dizer qual dos dois quebrou em vez de so "o site caiu"
    ("cfgate canary",         "https://cfgate.thalesmachado.net", "External", 60),
]

# --- DOCKER CONTAINERS ---
# Docker Container monitors (running/healthy via each host's docker-socket-proxy),
# only for containers with no other signal (no HTTP/TCP above, no `up` scrape).
# Unhealthy counts as DOWN. Monitor name: "<container> (<host>)".
DOCKER_HOSTS = {
    # the proxy only lives on dockflare-internal (see uptime-kuma.yaml)
    "zangetsu": "http://docker-socket-proxy:2375",
    # published on the LAN (dockflare-agent.yaml)
    "urahara":  "http://192.168.15.215:2375",
}

DOCKER_MONITORS = {
    "zangetsu": [
        "autoheal",
        "docker-socket-proxy",
        "dockflare-redis",
        "firefly-db",
        # the VIP keeps answering from urahara if this one dies: silent loss of HA
        "keepalived",
        "komodo-ferretdb",
        "komodo-periphery",
        "komodo-postgres",
        "nebula-sync",
        "tailscale",
    ],
    "urahara": [
        "autoheal",
        "dockflare-agent",
        "dockflare-agent-tunnel",
        "dozzle-agent",
        "evolution-db",
        "evolution-redis",
        # no scrape on urahara (the alloy job only covers zangetsu)
        "grafana-alloy",
        "immich-db",
        "immich-machine-learning",
        "immich-redis",
        "keepalived",
        "komodo-periphery",
        "paperless-db",
        "paperless-redis",
        "tailscale",
        "tandoor-db",
    ],
}


def docker_monitor_names():
    return [f"{c} ({h})" for h, containers in DOCKER_MONITORS.items() for c in containers]

# --- SCRIPT ---

def list_monitors_db(db_path=KUMA_DB_PATH):
    """Read id/name/type/parent/url of every monitor from SQLite (read-only).

    url is here so reconcile_existing can tell a moved service from a settled
    one; without it the comparison reads None, never matches, and reports a
    write that in fact succeeded as "Not applied"."""
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    rows = conn.execute("SELECT id, name, type, parent, url FROM monitor").fetchall()
    conn.close()
    return [dict(r) for r in rows]


def mutate(fn, *args, **kwargs):
    """add/editMonitor, addDockerHost and deleteMonitor only ack after the
    server resends the whole monitor list, so the ack can time out after the
    write happened (or, for edit_monitor, before it was sent). Callers always
    check SQLite. Two unrelated exception classes mean the same thing here:
    socket.io's own TimeoutError, and the library's Timeout raised by its
    wait_for_event wrapper around MONITOR_LIST."""
    try:
        return fn(*args, **kwargs)
    except (SocketTimeout, KumaTimeout):
        return None


def list_docker_hosts_db(db_path=KUMA_DB_PATH):
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    rows = conn.execute("SELECT id, name, docker_daemon FROM docker_host").fetchall()
    conn.close()
    return [dict(r) for r in rows]


def monitor_notification_ids(monitor_id, db_path=KUMA_DB_PATH):
    conn = sqlite3.connect(db_path)
    rows = conn.execute(
        "SELECT notification_id FROM monitor_notification WHERE monitor_id = ?", (monitor_id,)
    ).fetchall()
    conn.close()
    return {r[0] for r in rows}


def delete_all_monitors(api):
    """Delete every monitor and group."""
    monitors = list_monitors_db()
    if not monitors:
        print("  ℹ️  No monitors to delete.")
        return
    for m in monitors:
        api.delete_monitor(m["id"])
        print(f"  🗑️  Deleted: {m['name']} (id={m['id']})")
    print(f"  ✅ {len(monitors)} monitors deleted.\n")


def create_group(api, name):
    """Create a monitor group if it does not exist."""
    for m in list_monitors_db():
        if m.get("type") == "group" and m.get("name") == name:
            return m["id"]
    mutate(api.add_monitor, type=MonitorType.GROUP, name=name)
    gid = next(m["id"] for m in list_monitors_db() if m.get("type") == "group" and m.get("name") == name)
    print(f"  ✅ Group created: {name} (id={gid})")
    return gid


def create_notification(api):
    """Create the default WhatsApp notification, applied to all monitors."""
    existing = api.get_notifications()
    for n in existing:
        if n.get("name") == NOTIFICATION_NAME:
            return n["id"]
    result = api.add_notification(
        name=NOTIFICATION_NAME,
        type=NotificationType.WEBHOOK,
        webhookURL=NOTIFICATION_WEBHOOK_URL,
        webhookContentType="json",
        isDefault=True,
        applyExisting=True,
    )
    print(f"  ✅ Notification created: {NOTIFICATION_NAME} (id={result['id']})")
    return result["id"]


def find_monitor(api, name):
    """Return the monitor with this name, or None."""
    return next((m for m in list_monitors_db() if m.get("name") == name), None)


def reconcile_existing(api, monitor, group_id, notification_id, url=None):
    """Re-check parent, notification and URL of an existing monitor. The
    notification's isDefault is only applied by the UI, so a monitor created
    through the API without notificationIDList gets no alerts. Idempotent.

    URL matters because a service that moves keeps its name: when openspeedtest
    and it-tools went to the cluster on 2026-11-23 this script skipped both as
    "Exists" and left them pointing at Docker endpoints that no longer existed,
    which is a monitoring gap that reports itself as a healthy monitor."""
    changes = pending_changes(monitor["id"], group_id, notification_id, url)
    if not changes:
        print(f"  ⏭️  Exists: {monitor['name']}")
        return
    for _ in range(3):
        mutate(api.edit_monitor, monitor["id"], **changes)
        remaining = pending_changes(monitor["id"], group_id, notification_id, url)
        if not remaining:
            print(f"  🔧 Fixed: {monitor['name']} → {', '.join(changes)}")
            return
        changes = remaining
    print(f"  ⚠️  Not applied: {monitor['name']} → {', '.join(changes)} (run the script again)")


def pending_changes(monitor_id, group_id, notification_id, url=None):
    monitor = next(m for m in list_monitors_db() if m["id"] == monitor_id)
    changes = {}
    if group_id and monitor.get("parent") != group_id:
        changes["parent"] = group_id
    if notification_id not in monitor_notification_ids(monitor_id):
        changes["notificationIDList"] = [notification_id]
    # Only HTTP monitors carry a url; tcp and dns ones describe the target in
    # hostname/port fields that this reconcile does not touch.
    if url and monitor.get("type") in ("http", "keyword") and monitor.get("url") != url:
        changes["url"] = url
    return changes


def ensure_docker_host(api, name, daemon):
    """Reuse an existing Docker host with the same daemon URL."""
    for h in list_docker_hosts_db():
        if (h["docker_daemon"] or "").rstrip("/") == daemon.rstrip("/"):
            return h["id"]
    mutate(api.add_docker_host, name=name, dockerType=DockerType.TCP, dockerDaemon=daemon)
    host = next(h for h in list_docker_hosts_db() if h["docker_daemon"].rstrip("/") == daemon.rstrip("/"))
    print(f"  ✅ Docker host created: {name} (id={host['id']})")
    return host["id"]


def prune_stale_monitors(api):
    """Delete monitors that are no longer listed (never groups)."""
    current_names = {m[0] for m in MONITORS} | set(docker_monitor_names())
    existing = list_monitors_db()
    # delete_monitor() checks the id against get_monitors() before deleting, so
    # it inherits the hang and times out without deleting anything. Hand the
    # library the SQLite listing instead; the delete itself is a plain emit and
    # works. Found on 2026-11-19, removing the two lab monitors.
    api.get_monitors = lambda: [{"id": m["id"]} for m in existing]
    pruned = 0
    for m in existing:
        if m.get("type") == "group":
            continue
        if m["name"] not in current_names:
            mutate(api.delete_monitor, m["id"])
            print(f"  🗑️  Orphan removed: {m['name']} (id={m['id']})")
            pruned += 1
    if pruned == 0:
        print("  ✅ No orphan monitors found")
    return pruned


def main():
    reset = "--reset" in sys.argv

    if not UPTIME_KUMA_PASS:
        print("❌ Set UK_PASS before running:\n   export UK_PASS='your-password'")
        raise SystemExit(1)

    print(f"\n🔗 Connecting to {UPTIME_KUMA_URL}...")
    # the lib's default 10s timeout is too short with dozens of monitors
    api = UptimeKumaApi(UPTIME_KUMA_URL, timeout=int(os.getenv("UK_TIMEOUT", "30")))

    print(f"🔑 Logging in as '{UPTIME_KUMA_USER}'...")
    api.login(UPTIME_KUMA_USER, UPTIME_KUMA_PASS)
    print("✅ Logged in!\n")

    if reset:
        print("🗑️  --reset: deleting every monitor...")
        delete_all_monitors(api)

    print("🧹 Checking orphan monitors...")
    prune_stale_monitors(api)

    print("🔔 Setting up notification...")
    notification_id = create_notification(api)

    groups = {}
    unique_groups = list(dict.fromkeys(m[2] for m in MONITORS))
    print("📁 Creating groups...")
    for group_name in unique_groups:
        gid = create_group(api, group_name)
        groups[group_name] = gid

    print("\n📡 Creating monitors...")
    created = 0
    skipped = 0

    for entry in MONITORS:
        name, url, group, interval = entry[0], entry[1], entry[2], entry[3]
        statuscodes = entry[4] if len(entry) > 4 else ["200-299"]
        ignore_tls  = entry[5] if len(entry) > 5 else False
        tcp_port    = entry[6] if len(entry) > 6 else None
        dns_server  = entry[7] if len(entry) > 7 else None

        existing_monitor = find_monitor(api, name)
        if existing_monitor:
            reconcile_existing(
                api, existing_monitor, groups.get(group), notification_id,
                url if tcp_port is None and dns_server is None else None,
            )
            skipped += 1
            continue

        if dns_server:
            mutate(
                api.add_monitor,
                type=MonitorType.DNS,
                name=name,
                hostname=url,
                port=53,
                dns_resolve_server=dns_server,
                dns_resolve_type="A",
                interval=interval,
                maxretries=DEFAULT_RETRIES,
                retryInterval=DEFAULT_RETRY_INTERVAL,
                notificationIDList=[notification_id],
            )
        elif tcp_port:
            mutate(
                api.add_monitor,
                type=MonitorType.PORT,
                name=name,
                hostname=url,
                port=tcp_port,
                interval=interval,
                maxretries=DEFAULT_RETRIES,
                retryInterval=DEFAULT_RETRY_INTERVAL,
                notificationIDList=[notification_id],
            )
        else:
            mutate(
                api.add_monitor,
                type=MonitorType.HTTP,
                name=name,
                url=url,
                interval=interval,
                maxretries=DEFAULT_RETRIES,
                retryInterval=DEFAULT_RETRY_INTERVAL,
                accepted_statuscodes=statuscodes,
                ignoreTls=ignore_tls,
                notificationIDList=[notification_id],
            )
        mid = find_monitor(api, name)["id"]

        # set the group in a second call: more reliable than parent= on create
        group_id = groups.get(group)
        if group_id:
            print(f"  ✅ Created: {name} (id={mid}) | accepted status: {statuscodes}")
            reconcile_existing(api, {"id": mid, "name": name}, group_id, notification_id)
        else:
            print(f"  ⚠️  Created: {name} (id={mid}) — group '{group}' not found!")
        created += 1

    print("\n🐳 Creating Docker Container monitors...")
    for host, daemon in DOCKER_HOSTS.items():
        host_id = ensure_docker_host(api, host, daemon)
        group_id = create_group(api, f"Containers ({host})")
        for container in DOCKER_MONITORS[host]:
            name = f"{container} ({host})"
            existing_monitor = find_monitor(api, name)
            if existing_monitor:
                reconcile_existing(api, existing_monitor, group_id, notification_id)
                skipped += 1
                continue
            mutate(
                api.add_monitor,
                type=MonitorType.DOCKER,
                name=name,
                docker_container=container,
                docker_host=host_id,
                interval=DEFAULT_INTERVAL,
                maxretries=DEFAULT_RETRIES,
                retryInterval=DEFAULT_RETRY_INTERVAL,
                notificationIDList=[notification_id],
            )
            mid = find_monitor(api, name)["id"]
            print(f"  ✅ Created: {name} (id={mid})")
            reconcile_existing(api, {"id": mid, "name": name}, group_id, notification_id)
            created += 1

    api.disconnect()
    print(f"\n🎉 Done! {created} monitors created, {skipped} skipped.")


if __name__ == "__main__":
    main()
