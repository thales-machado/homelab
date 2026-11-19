#!/usr/bin/env python3
"""Generate the service inventory table in README.md, or check it is current.

The include: list of each host entry point is the single source of truth for
what runs on that host (CONVENTIONS.md). A fragment with no include: line is
legacy and is deliberately absent from the inventory, not reported as a gap.

Entry points are the host compose.yaml plus its komodo-*.yaml, which are
separate Compose projects on purpose (docs/komodo.md) and would otherwise be
missing from an inventory of what is actually running.

Kubernetes workloads are read from k8s/apps/<category>/<app>/ once that tree
exists; until then the runtime column is docker for every row.

Usage:
    inventory.py            rewrite the table in README.md
    inventory.py --check    exit 1 if README.md differs from what we generate
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
README = REPO / "README.md"
HOSTS_DIR = REPO / "docker" / "hosts"
K8S_APPS = REPO / "k8s" / "apps"

START = "<!-- inventory:start -->"
END = "<!-- inventory:end -->"

# "  - ../../services/platform/networking/pi-hole/pi-hole.yaml", ignoring a
# commented line and anything after a trailing comment.
INCLUDE_RE = re.compile(r"^\s*-\s*(\.\./\.\./services/\S+\.ya?ml)\s*(?:#.*)?$")


def docker_services():
    """Map every included fragment to the hosts that include it."""
    found = {}
    for host_dir in sorted(p for p in HOSTS_DIR.iterdir() if p.is_dir()):
        host = host_dir.name
        entry_points = [host_dir / "compose.yaml"]
        entry_points += sorted(host_dir.glob("komodo-*.yaml"))
        for entry in entry_points:
            if not entry.is_file():
                continue
            for line in entry.read_text(encoding="utf-8").splitlines():
                m = INCLUDE_RE.match(line)
                if not m:
                    continue
                parts = m.group(1).split("/")
                # ../ ../ services <category> ... <service> <file>.yaml
                category, service = parts[3], parts[-2]
                found.setdefault((category, service), set()).add(host)
    return {k: ("docker", v) for k, v in found.items()}


def k8s_services():
    """Map every k8s app directory to the cluster. Empty until k8s/ exists."""
    if not K8S_APPS.is_dir():
        return {}
    found = {}
    for category_dir in sorted(p for p in K8S_APPS.iterdir() if p.is_dir()):
        for app_dir in sorted(p for p in category_dir.iterdir() if p.is_dir()):
            found[(category_dir.name, app_dir.name)] = ("k8s", {"cluster"})
    return found


def render(rows):
    out = ["| Service | Runtime | Host | Category |", "|---|---|---|---|"]
    for (category, service), (runtime, hosts) in sorted(rows.items()):
        where = ", ".join(f"`{h}`" for h in sorted(hosts))
        out.append(f"| `{service}` | {runtime} | {where} | `{category}` |")
    return "\n".join(out)


def splice(text, table):
    if START not in text or END not in text:
        sys.exit(f"markers {START} / {END} not found in README.md")
    head = text.split(START)[0]
    tail = text.split(END)[1]
    return f"{head}{START}\n\n{table}\n\n{END}{tail}"


def main():
    check = "--check" in sys.argv[1:]
    rows = docker_services()
    rows.update(k8s_services())
    if not rows:
        sys.exit("no services found: is docker/hosts/ in place?")

    current = README.read_text(encoding="utf-8")
    wanted = splice(current, render(rows))

    if current == wanted:
        print(f"inventory is current: {len(rows)} services")
        return

    if check:
        import difflib

        diff = difflib.unified_diff(
            current.splitlines(keepends=True),
            wanted.splitlines(keepends=True),
            "README.md (committed)",
            "README.md (generated)",
        )
        sys.stdout.writelines(diff)
        sys.exit(
            "\nREADME.md inventory is out of date. "
            "Run: python3 scripts/inventory/inventory.py"
        )

    README.write_text(wanted, encoding="utf-8")
    print(f"inventory updated: {len(rows)} services")


if __name__ == "__main__":
    main()
