---
name: wolf
description: Use when touching anything related to Wolf (retro Moonlight/Games on Whales streaming on urahara), RetroArch, ES-DE, ROM curation, or the favorites list.
---

Read these before any change, in this order:
1. `docs/wolf/wolf-setup.md` — structure, provisioning, operation and known traps (the whole file, mandatory).
2. `docs/wolf/rom-curation-rules.md` — ROM curation rules.
3. `docs/wolf/favorite-games.md` — the favorites list.
4. `docs/wolf/snes-adapter-troubleshooting.md` and `docs/wolf/mayflash/mf105-reference.md` — only when a controller misbehaves in Moonlight.

Wolf is the only service that mounts the Docker socket directly (no `docker-socket-proxy`) and it runs with `network_mode: host`. Do not copy either pattern into another service without an equivalent need.
