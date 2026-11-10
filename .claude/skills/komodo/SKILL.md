---
name: komodo
description: Use when dealing with a Komodo deploy (Stack, webhook, DeployStackIfChanged), managing komodo-core/komodo-periphery, or any "git dubious ownership" error, stack stuck in DOWN, or webhook failing in GitHub Actions.
---

Read all of `docs/komodo.md` before acting.

Non-negotiable rule: `komodo-core` and `komodo-periphery` **never** go in the `include:` of any host's main `compose.yaml`, because that takes down the very deploy that manages them. Deploying or updating those two is always manual:

```bash
cd hosts/<host> && docker compose -f komodo-periphery.yaml up -d
cd hosts/zangetsu && docker compose -f komodo-core.yaml up -d
```

Other points:
- Never use `DeployStackIfChanged` (intermittent hang, known bug still present in 2.3.3): always `webhook_force_deploy: true`.
- Upgrades: always `pull` before `--force-recreate` (recreate alone does not pull a new image), and keep Core and Periphery on the same version.
- The Stack's webhook secret must match the one configured in GitHub Actions (`KOMODO_HOMELAB_<HOST>_WEBHOOK_SECRET`); a mismatch fails silently (exit 22 in Actions).
- A Stack's `repo` must match the real repository name on GitHub. Every deploy resets `/opt/homelab` against it, so renaming the repository without `UpdateStack` first empties the checkout on both hosts.
