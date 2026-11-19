# CLAUDE.md

Instructions for coding agents working in this repository. It holds no rules of its own: every convention lives in [`CONVENTIONS.md`](CONVENTIONS.md), which is the single source of truth.

## Before changing anything

1. **Read `CONVENTIONS.md`.** It covers hosts, networks, DNS, storage, observability, naming, mandatory conventions and the critical restrictions. Do not infer a convention from existing code: a fragment may predate a rule.
2. **Load the skill that matches the task** (`.claude/skills/`). Each one names the runbook in `docs/` to read first:
   - `backup` — databases, Restic, backup DAGs.
   - `komodo` — deploys, Stacks, webhooks, `komodo-core` / `komodo-periphery`.
   - `traefik` — private routes, Traefik labels, certificates, CrowdSec, DockFlare.
   - `wolf` — Moonlight streaming, RetroArch, ES-DE, ROMs, controllers.
3. **Use `/new-service`** (`.claude/commands/new-service.md`) to add a service. It carries the YAML skeletons and the per-variant steps (private, public, both, export, webhook).

## What is true in this repository

- **`include:` in `docker/hosts/<host>/compose.yaml` is the only source of truth about what exists.** A fragment outside every host's `include:` is legacy: never report it as a gap or an inconsistency, never suggest enabling it, and keep it out of any audit.
- **An audit of conventions** (resource limits, `TZ`, Watchtower labels, backup, DNS and Traefik, monitoring) runs **only** over fragments that are active in an `include:`.
- **The real `.env` of each host** lives at `/opt/homelab/docker/hosts/<hostname>/.env` on the host itself and is never in the repo. `.env.example` lists the variable names only. Never print a secret's value: read a variable's **name** from `.env` when you need to confirm it exists, and refer to it as `${NAME}`.
- Commands run from inside `docker/hosts/<hostname>/`.

## Working on the hosts

Both hosts take direct SSH (`ssh keydrop@<ip>`), which is the way to run anything that has to happen on the host itself: `systemctl`, `docker exec`, editing the real `.env`. Host operations, the deploy quirks (what needs `--force-recreate`, what needs a config copy) and the systemd and mount setup are in [Host operations](CONVENTIONS.md#host-operations).

Nothing is applied to production without explicit confirmation. Writing the change to the repo and applying it to a host are two separate steps.

## When in doubt

- **A service's internal port**: find it as described in `CONVENTIONS.md`, never guess.
- **A public service's `dockflare.access.group`**: always ask; if the answer does not come, omit the label.
- **Anything not covered here or in `CONVENTIONS.md`**: ask instead of inventing a convention.
