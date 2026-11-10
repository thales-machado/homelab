# Komodo (multi-host Docker management)

Core runs only on zangetsu (`infra/platform/management/komodo/komodo.yaml`: postgres + ferretdb + core). Periphery is host-agnostic, one agent per host (`infra/platform/management/komodo/periphery.yaml`). Deploys come from GitHub Actions (`.github/workflows/deploy.yaml`), which calls the `/listener/github/stack/<id>/deploy` webhook per host and only triggers the hosts whose `include:` covers the changed files.

**`komodo-core` and `komodo-periphery` must NEVER be in the `include:` of the `compose.yaml` that the `homelab-<host>` Stack itself manages.** A real `DeployStack` recreating the Core or Periphery container kills the very process running the deploy: Periphery runs `docker compose` as its own subprocess, and Core tracks the deploy's progress inside itself. What this looked like in production: half the host's containers stuck in `Created` (never reaching `Started`, and `restart: unless-stopped` does not help because the container never existed long enough to have a restart policy applied), with the Stack stuck in `DOWN` / `0 Services` and the update "Complete" with `success:false` forever, logging `"Komodo shutdown during execution"` or simply losing the Periphery process.

**Removing them from `include:` is not enough**, which was tested and confirmed: the container still carried the Stack's `com.docker.compose.project` (`homelab`, inherited from the Stack's `project_name:`), and Komodo operates at the **Compose project** level, not only on the declared files. The fix is that `hosts/<host>/komodo-periphery.yaml` and `hosts/zangetsu/komodo-core.yaml` are **their own Compose projects** (`name: komodo-periphery` / `name: komodo-core`, `networks: cloudflare-net: external: true`, and an `include:` of only the relevant fragments, never the main `compose.yaml`, which would drag the whole `homelab` project along). Deploying or updating those two is **always manual**, never through Komodo or a webhook:

```bash
cd hosts/<host> && docker compose -f komodo-periphery.yaml up -d
cd hosts/zangetsu && docker compose -f komodo-core.yaml up -d   # zangetsu only
```

urahara has one extra override included from inside its own `komodo-periphery.yaml` (the published port, `komodo-periphery-port.yaml`). Do not confuse it with the host's main `compose.yaml`.

Consequence: `komodo-core` can no longer have `depends_on: dockflare`, since `depends_on` does not work across projects. It was removed from `komodo.yaml`, and `dockflare` is up persistently well before Core needs it.

**Known bug (Komodo 2.3.2, still present in 2.3.3): do not use `DeployStackIfChanged`.** It hangs forever, with no error, no log and no persisted update, on a Stack whose `compose.yaml` is `include:`-heavy, both through the webhook and through a direct `/execute` API call. `RefreshStackCache` alone works fine on 2.3.3 (clone and diff are ok), but `DeployStackIfChanged` hangs anyway, and intermittently enough to fool you: it worked in 2 of 3 runs before hanging on the third, with a real `mem_limit` diff. **Both Stacks use `webhook_force_deploy: true`.** Do not revisit that without reproducing a controlled test several times in a row first, with a real diff rather than just `RefreshStackCache`. Keep Core and Periphery on the same version (`docker compose pull <service> && docker compose up -d --force-recreate <service>`; `--force-recreate` alone does **not** pull a new image).

**Webhook secret**: an empty `webhook_secret` on the Stack falls back to the Core's global `KOMODO_WEBHOOK_SECRET`, so a per-Stack override is only needed for a dedicated secret (`homelab-urahara` has one). The GitHub Actions secret (`KOMODO_HOMELAB_<HOST>_WEBHOOK_SECRET`) must match whichever the Stack actually uses. A mismatch makes `curl -f` fail with exit 22 (HTTP 4xx) in the Actions job, silently until someone opens the run.

**The Stack's `repo` must match the real name on GitHub.** Each Stack has a fixed `repo`, and on every deploy Periphery runs `git remote set-url` plus a reset in `/opt/homelab` against it, overwriting whatever remote was set by hand on the host. When the repository was renamed and a new, almost empty repository took the old name, every deploy emptied `/opt/homelab` on both hosts. Containers recreated in that window got their single-file bind mounts as **directories** (Docker creates a missing path as a directory) and broke on the next reboot with `not a directory: Are you trying to mount a directory onto a file`. When renaming the repository: `UpdateStack` on both Stacks (`config.repo`) **before** the next push, then `--force-recreate` every container with a bind mount from a repo subfolder.

**A `container_name` conflict leaves the whole host in `Created`.** `docker compose up -d` recreates everything first and only then starts it, so if creating a single container fails (for example `Conflict. The container name "/<name>" is already in use`, from a container created by hand with `docker run` and no Compose labels), Compose aborts and **every** already-recreated container sits in `Created`: Pi-hole, Traefik, the tunnel. `DeployStack` returns `success:false`. Fix: rename or remove the orphan container and run `docker compose up -d` again. A container left with a hash prefix (`<id>_grafana`) is the service's only instance, so just `docker rename` it back.

**`git` "dubious ownership"**: a Stack in native git-clone mode (`clone_path=/opt/homelab`, writing straight into the repo's real path) needs `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_N` / `GIT_CONFIG_VALUE_N=safe.directory` in Periphery's `environment:` (the equivalent of `git config --global --add safe.directory`, without depending on a persisted `.gitconfig`). Without it, `git remote set-url` and clone fail with "detected dubious ownership", because `/opt/homelab` on the host belongs to `keydrop` while Periphery runs as root inside the container.

## Periphery environment

Three settings exist because of a production failure, all silent:

**`PERIPHERY_PASSKEYS` must equal Core's `KOMODO_PASSKEY`.** Without it the Noise handshake never completes: the container starts normally, the Server never reaches "Ok" in the UI, and `core.pub` is never written to `/config/keys`. The public-key exchange itself is automatic (TOFU) but only runs after the passkey authenticates the connection.

**`PERIPHERY_SERVER_ENABLED=true` is required alongside `PERIPHERY_CORE_ADDRESS`.** Setting `core_address` (outbound mode) disables the inbound server on port 8120 by default, but Core always connects *directly* to the Server address set in the UI to read status and stats. With inbound off, 8120 never listens and the Server stays "NotOk" (connection refused) even while the outbound channel works. Both modes must coexist.

**`HOMELAB_ENV` has to be passed into Periphery explicitly.** A native git-clone Stack runs `docker compose` as a subprocess inside the Periphery container, where `${HOMELAB_ENV}` is empty (on the host it only exists through `/etc/environment`, i.e. in human SSH sessions). Every fragment's `env_file: - ${HOMELAB_ENV}` then fails with `env file not found: stat : no file directory`.

`PERIPHERY_CORE_ADDRESS` and `PERIPHERY_CONNECT_AS` differ per host (container name on the same Docker network on zangetsu, LAN-published `IP:port` on urahara), so each host sets them in its own `.env`, like `PIHOLE_STATIC_IP`.

`GIT_CONFIG_*` does not merge across fragments: a host override that redeclares `environment:` must repeat the whole `safe.directory` trio.

Periphery mounts the Docker socket directly, with no `docker-socket-proxy`, because it needs read-write control (start, stop, deploy).
