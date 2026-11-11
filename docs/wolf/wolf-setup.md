# Wolf (retro streaming, urahara)

Retro emulation streamed over Moonlight (Games on Whales): `infra/media-player/wolf/wolf.yaml`, urahara only. Clients are Moonlight on a Windows desktop and on the TV (Google TV), connecting straight to `192.168.15.215`. No DockFlare (streaming is UDP and the tunnel only carries HTTP) and no Tailscale (remote access is out of scope). One session at a time.

**Only Wolf itself is a Compose service.** RetroArch and the other apps are created by Wolf per session through the Docker socket and removed when the session ends, which is why the container name changes (`WolfRetroarch_<id>`) and there is no RetroArch fragment. Each app's recipe lives in Wolf's `config.toml` (`/opt/apps/wolf/cfg/`), which also holds the paired clients (`[[paired_clients]]`) and the uuid: **it is state, so it is not versioned as a whole.** `scripts/setup/setup-wolf-config.sh` edits only the RetroArch and ES-DE blocks (pinned image, mounts, limits) and preserves the rest. **CPU and memory limits for the apps go in `base_create_json` (HostConfig `NanoCpus` / `Memory`), not in a YAML `cpus` / `mem_limit`.**

**Security exceptions, for Wolf only** (do not copy): the Docker socket is mounted directly (Wolf only speaks to a unix socket, `WOLF_DOCKER_SOCKET` does not support tcp, so `docker-socket-proxy` cannot serve it; in practice it already needs `/dev` read-write, `/run/udev` and `device_cgroup_rules`, which is equivalent to root on the host), plus `/dev:/dev:rw` and `network_mode: host`. The image is pinned by digest (no releases since 2024.07, only a rolling `stable` branch) with no Watchtower label; updating is manual, with a stream test.

**RetroArch provisioning** (`scripts/setup/setup-wolf-retroarch.sh`, needs sudo, no active session): the GoW image ships with no cores, an empty Core Downloader and no `.info` files, and without those the file browser hides every ROM. The script installs cores from the buildbot's **stable** package (pinned sha256), the `.info` files (tag `libretro-core-info`), Dolphin's `Sys` (tag), GLSL shaders (commit), the PS2 BIOS (copied from `/mnt/games-4tb/retro/bios/pcsx2`) and the options versioned in `infra/media-player/wolf/config/core-options/`. Order on a first deploy: `setup-nas-mounts.sh` first, then start wolf, then `setup-wolf-config.sh`, then `setup-wolf-retroarch.sh`. Cores that need their own BIOS (`swanstation`, `mednafen_saturn`, `melonds`, `flycast`, `ppsspp` with assets) have no BIOS provisioned.

**ES-DE (the "EmulationStation" app, the catalog with cover art)**: image `ghcr.io/games-on-whales/es-de` pinned by digest, with a block already present in Wolf's default `config.toml`, edited by the same `setup-wolf-config.sh`. It launches RetroArch (and standalone Dolphin/PCSX2) as a subprocess in its own container, so it gets the same limits as the RetroArch app. Mounts: `/mnt/games-4tb/retro/roms` → `/ROMs:ro`, `/mnt/games-4tb/retro/bios` → `/bioses:ro`, `/opt/apps/wolf/es-de-media` → `/media` (scraper covers and videos, reproducible, excluded from Restic), `/mnt/games-4tb/retro/bios/mame` → `/bios-mame:ro` (see the `chown` quirk below), and the RetroArch app profile's `.config/retroarch` → `/home/retro/.config/retroarch` (cores, BIOS, shaders, saves and `retroarch.cfg` shared, provisioned once). ScreenScraper credentials are typed into the ES-DE UI and live in the `WolfES-DE` profile, never in the repo. `setup-wolf-config.sh` has to create `WolfES-DE/.config` as UID 1000 before the first start, or Docker creates it as root when mounting `retroarch` inside it.

**The MAME BIOS is mounted from the local `games-4tb` disk, outside ES-DE's `$HOME`.** `retro/bios/mame` is mounted read-only so the BIOS can be managed through the file share with no SSH. The first attempt mounted it directly at `.../retroarch/system/mame/bios`, inside `$HOME`, and broke ES-DE: the image's `setup-de.sh` runs `chown -R ${UNAME}:${UNAME} ${HOME}/.config` under `set -e` on every start, fails on the first file of a read-only mount and aborts the whole container (confirmed with a `docker run` using the same mount; RetroArch has no such script and does not break). Fix: the real mount goes to `/bios-mame`, outside `$HOME`, like `/bioses`, and `setup-wolf-retroarch.sh` creates a **symlink** `system/mame/bios` → `/bios-mame` inside the profile. GNU coreutils' `chown -R` does not follow a symlink while recursing (it only changes the link itself, which lives on the profile's writable filesystem), so it never enters the read-only mount. The MAME core still sees `system/mame/bios` normally, resolving the link when it opens a file.

## Operating and maintaining Wolf

- **Only 3 apps in the menu**: Wolf UI, RetroArch and EmulationStation. `setup-wolf-config.sh` removes everything else from the default `config.toml` (Steam, Firefox, Lutris, Prismlauncher, Pegasus, Desktop, Kodi, Test ball), which all use floating `:edge` images with no limits. Wolf UI is pinned by digest and limited too (1 CPU / 512 MB).
- **The three setup scripts (`setup-wolf-config.sh`, `setup-wolf-retroarch.sh`, `setup-wolf-esde.sh`) abort when a session is open** (a `Wolf-UI_*` / `WolfRetroarch_*` / `WolfES-DE_*` container is running; `FORCE=1` skips the check). Stopping wolf kills the Moonlight session, and RetroArch and ES-DE rewrite their `.cfg` / `.xml` on exit, overwriting the merge.
- **Closing Moonlight does not end the app**: Wolf keeps the container alive in a clientless "lobby" (log line `Moonlight stream ... over, leaving lobby`), so the scripts still see a session. Before running the setups: `docker stop <app container>` (SIGTERM lets ES-DE write `es_settings.xml` before the merge) and check that `docker ps | grep ^Wolf` is empty.
- **Versioned config**: `infra/media-player/wolf/config/`.
  - `retroarch/retroarch-overrides.cfg`: controller combos (`input_quit_gamepad_combo=4`, Start+Select, and `input_menu_toggle_gamepad_combo=2`, L3+R3; the quit combo works with a single press, confirmed on the controller).
  - `core-overrides/`: Run-Ahead of 1 frame, automatic save state and a CRT shader, only on the 2D cores (Snes9x, FCEUmm, Nestopia, Genesis Plus GX, PicoDrive, Gambatte, mGBA); FinalBurn Neo gets the shader only. PS2, GameCube, N64 and PSP get neither, since Run-Ahead would double the CPU cost.
  - `es-de/es-settings-overrides.txt`: updater `never`, screensaver `dim`, first controller only.
  - `es_settings.xml` stores the ScreenScraper password in plain text: never version it, and `setup-wolf-esde.sh` refuses any credential key.
- **Image updates are manual**: the monthly `wolf-image-check` DAG (Dagu, day 1 at 09:00) runs `scripts/monitoring/check-wolf-image-updates.sh`, compares the pinned digests with GHCR's and pings Healthchecks (the `wolf-image-check` check, created by the script through the API, which needs a write-enabled `HEALTHCHECKS_API_KEY`). A new digest becomes a `/fail`. Updating means changing the digest in `wolf.yaml` / `setup-wolf-config.sh`, re-running the scripts and testing a stream.
- **Grafana alerts**: `container-restart` (cAdvisor on urahara) covers the wolf container, and `mount-retro-active` covers `/mnt/games-4tb`.

## `retro` moved from the NAS CIFS mount to the local `games-4tb` disk

`retro` (and qBittorrent's `games` category) left the CIFS mount and now lives on `/mnt/games-4tb`, a dedicated local disk on urahara: the very 4 TB HDD that used to be a QNAP volume, now partitioned directly as ext4 over USB. The data was recovered from the QNAP's proprietary RAID/LVM with a VM running a patched kernel (`czankel/qnap-kernel-ramdisk`) before repartitioning. The mount is managed by `scripts/systemd/mnt-games-4tb.mount` (`WantedBy=local-fs.target`, not part of `setup-nas-mounts.sh` because it is not CIFS). The on-disk layout is already final (`roms/<system>/`, `bios/<system>/`), with no reorganization needed.

System folder names are ES-DE's, lowercase: `nes`, `snes`, `mastersystem`, `megadrive`, `gb`, `gbc`, `gba`, `psx`, `n64`, `nds`, `psp`, `dreamcast`, `saturn`, `pcengine`, `neogeo`, `mame`, `fbneo`, `ps2`, `gc`, `wii`. `bios/mame` is mounted into the RetroArch profile as described above, so the BIOS can be managed over the Samba share with no SSH.

## PulseAudio in the `wolf` container hangs for good if `/opt/apps/wolf/run` is not owned by root

`wolf` runs as root internally (`UNAME=root` in `10-setup_user.sh`) and so does its built-in PulseAudio, but the image refuses (its own check, not a kernel permission error) to run as root against an `XDG_RUNTIME_DIR` (`/run/user/wolf`, a bind mount of `/opt/apps/wolf/run`) owned by someone else: `XDG_RUNTIME_DIR ... is not owned by us (uid 0), but by uid 1000!`. After a few attempts it gives up (`entered FATAL state`), taking down audio and the whole Moonlight session. It only shows up on a **real restart** of `wolf`, which is rare, since app containers come and go without touching it; if the directory ever ended up owned by uid 1000 (created by hand, or by an older version), the next restart exposes the bug. Fix: `sudo chown -R root:root /opt/apps/wolf/run` before restarting `wolf`. Read and execute permissions for others (`755` on `wolf.sock`) still let RetroArch and ES-DE (uid 1000 inside their containers) connect to the socket, so nothing breaks on the app side.

## Komodo's `auto_prune` was deleting the app images between sessions

The RetroArch and ES-DE images are only "in use" while a session is open, so Komodo's daily auto prune (`auto_prune: true` by default on a Server) removed them overnight. In Moonlight the apps then showed the red download icon (Wolf marks an app whose image is missing locally) and the first use of the day tried to pull several GB. Fix: `auto_prune: false` on the `urahara` Server in Komodo (done through the `UpdateServer` API; zangetsu keeps prune on). If the images disappear again, `docker pull` the digests pinned in `setup-wolf-config.sh`. Watchtower is not the cause: it only removes the old image of containers it updates itself.

## An invalid core-option value is discarded silently

RetroArch rewrites the `.opt` file when it loads a core, replacing an unknown value with the default. That happened with `pcsx2_upscale_multiplier = "2x"`, which became `1x Native (PS2)`: the stored value is the core's full string (`2x Native (~720p)`). Before versioning an option, check the exact text (`grep -a -o` on the core's `.so` with `LC_ALL=C`, or read the `.opt` RetroArch wrote after picking the value in the UI).

## "Z80 ERROR" in Neo Geo games comes from global Run-Ahead, not from the ROM or BIOS

Metal Slug X hung on the boot screen with "Z80 ERROR" on the MAME core even with `neogeo.zip` and `mslugx.zip` audited byte by byte against the official CRC32 embedded in MAME's source (`src/mame/snk/neogeo.cpp`, `ROM_LOAD`), all matching, and even after deleting `saves/MAME/mame/nvram/mslugx` and moving the core from 0.282 to 0.289 (a buildbot nightly; stable is stuck on 0.282). The real cause, confirmed against identical reports on the libretro forum and the NeoGeo Dev Wiki, is that Z80 ERROR is a real 68k↔Z80 handshake timeout (command $01 with no answer in time), and RetroArch's **Run-Ahead** interferes with that timing. `run_ahead_enabled` had leaked into the **global** `retroarch.cfg` (probably saved by the Quick Menu in an earlier session instead of only in the per-core override), affecting MAME even though the documented intent is Run-Ahead on the 7 light 2D cores only, through their own `config/<core>/<core>.cfg`. FBNeo does not hang with Run-Ahead on (more tolerant timing), which is why it worked while MAME did not. Fix: `run_ahead_enabled = "false"` pinned in the versioned `retroarch-overrides.cfg` (global level); the 7 2D cores keep Run-Ahead through their own override (`core-overrides/cores-2d.cfg`), untouched.

## LRPS2 needs `GameIndex.yaml`

The core's `.info` lists `pcsx2/resources/GameIndex.yaml` as a required file (the database of per-game hardware fixes). Without it no fix is applied, and one game rendered with texture noise even though its CHD was intact (verified with `chdman verify`). `setup-wolf-retroarch.sh` installs the file from `libretro/ps2`, pinned by commit and sha256, into `system/pcsx2/resources/` (the `libretroization` branch mentioned in libretro's docs no longer exists; the file lives in `bin/resources/` on `master`).

## Standalone Dolphin as a per-game alternative emulator

The libretro/dolphin core has a confirmed "target refresh rate" oscillation bug in games that change video mode at runtime (for example a collection whose built-in SNES emulator switches video mode between titles). Performance degrades to slow motion even with hardware to spare, confirmed in `dolphin.log` and matching external reports of the identical bug in the same core source (`portare-ch/portareos#463`). It is not a config or hardware problem: a local standalone Dolphin with the same settings runs the game smoothly. The fix follows the pattern already used for PCSX2: an `<altemulator>Dolphin (Standalone)</altemulator>` tag in the affected game's `gamelist.xml`, plus an override of ES-DE's default find rule in `infra/media-player/wolf/config/es-de/es_find_rules.xml` (`<emulator name="DOLPHIN">`) pointing at the `~/dolphin-launch.sh` wrapper (`infra/media-player/wolf/config/es-de/dolphin-launch.sh`). The AppImage is unofficial (`pkgforge-dev/Dolphin-emu-AppImage`, no FUSE needed), downloaded by hand to `/opt/apps/wolf/profile-data/user/WolfES-DE/dolphin-emu.AppImage`, outside `~/bin`.

- **Standalone Dolphin's config (`~/.config/dolphin-emu`, separate from the libretro core's) needs its own mount**: only paths listed under `mounts` in `config.toml` survive a container recreation, so `/opt/apps/wolf/profile-data/user/WolfES-DE/dolphin-emu-standalone:/home/retro/.config/dolphin-emu` was added to the `WolfES-DE` app. A mount only applies to containers created **after** the edit; a running container has to be recreated (close the Moonlight session) to inherit it.
- **`docker stop` (SIGTERM) kills the process before it saves its config** (`GCPadNew.ini`, `Hotkeys.ini`). Close Dolphin from its own UI (File → Exit / Alt+F4) inside the streamed session, never by killing the container. Even then the container may stay alive in a lobby (same behavior as RetroArch and ES-DE): check with `pgrep -af dolphin-emu.AppImage` before assuming anything persisted, and if the container was created **before** the mount existed (`docker inspect --format '{{range .Mounts}}...'` shows no `dolphin` entry), copy the file out with `docker cp` before removing the container.
- **Port 1 can silently fall back to "Triforce Baseboard"** instead of "Standard Controller" on the GameCube Controllers screen, which blocks the game with a modal alert ("Non-Triforce games cannot be booted with Triforce hardware attached") and prevents configuring the pad. Set it back to "Standard Controller" before mapping.
- **`ConfirmStop = True` (the default) asks for confirmation on exit even from the hotkey** (`Back&Start`, mapped under Hotkey Settings → General → Exit), which is unusable on a TV with no keyboard. `ConfirmStop = False` is pinned under `[Interface]` in the persisted `Dolphin.ini`.
- **`Fullscreen = True` in `Dolphin.ini` instead of the `-f` flag**: passing `-f` in the wrapper hangs the process silently (confirmed with `ps -eo pid,etime,cmd`: the process is alive but no window appears, likely an AppImageUpdate dialog outside the visible area). Setting `Fullscreen = True` under `[Display]` in the INI works without the hang.
- **Deliberate trade-off in not moving the whole library to standalone**: it loses Run-Ahead and RetroArch's unified save states and quick menu (each standalone game becomes its own profile). Only move a game when there is a confirmed real bug; most of the ~130 GameCube games run fine on the libretro core.

## One SNES game freezes its controls after the intro on the Snes9x core

A known core bug, confirmed against external reports; not a hardware or mapping problem (validated separately with both MF105 controllers working in other SNES games). There was no remap or override in `retroarch.cfg` or in `remaps/` / `overrides/`; the game loads and runs (confirmed by `playcount` / `playtime` in `gamelist.xml`), but no button responds after the intro. Fix: a per-game core override through a tag in `gamelist.xml` (`gamelists/snes/gamelist.xml`; ES-DE 3.4.1's current format is `<emulator name="RetroArch"><core name="bsnes"/></emulator>`, not the legacy `<altemulator>` used in the Dolphin entry above):

```xml
<emulator name="RetroArch">
    <core name="bsnes"/>
</emulator>
```

Validated in production: bsnes fixes it, with d-pad, buttons, L/R, Start and Select all working. **Editing `gamelist.xml` while ES-DE is running is risky**: the process keeps the gamelist in memory and may rewrite the file on exit, overwriting the manual edit. Close the Moonlight session after editing (not just going back to the menu) so the next ES-DE boot loads the version on disk.

## App containers do not inherit `TZ` from the `wolf` container

Wolf-UI, WolfRetroarch and WolfES-DE are created by Wolf itself through the Docker API from `config.toml`, not by Compose, so they do not inherit `environment: TZ=${TZ}` from `wolf.yaml` and came up with the base image's timezone. Fix: `TZ=America/Sao_Paulo` added to the `env` array of all three `[[apps]]` blocks in `config.toml`. **Wolf does not reload `config.toml` at runtime**: it needs `docker restart wolf` for new containers to pick it up, which kills any active session or stream, not only the one asking for the change.

## Traps confirmed during the initial spike

- **Moonlight has to request 60 fps** (both the PC and the TV client). At 30 fps the game runs in slow motion and the audio is poor.
- **LRPS2 (PS2) with Renderer on Auto gives a black screen with audio.** It has to be OpenGL, and the option only takes effect when the content is reopened.
- Internal resolution: PS2 at 2x (GPU ~36%; 4x reached 83-94%, no headroom) and GameCube at 3x (GPU ~43%). Measured at 1080p60 HEVC, where the encoder (VCN) stays at ~29-36% regardless of the game.
- Performance overlay: `Ctrl+Alt+Shift+S` on the PC client; on Moonlight Android it is "Show performance overlay" in the settings. UniFi's DPI does not see this traffic (the TV and urahara are on the same subnet, so it never reaches the gateway).
- Pairing: Wolf logs `Insert pin at http://192.168.15.215:47989/pin/#<secret>`; open that URL and type the PIN Moonlight shows. It is also published as `wolf.lan.thalespm.me` (`cross-host.yml`). Wolf rewrites `config.toml` when pairing.
- Wolf's app containers show up in Komodo but disappear on their own when the session closes.

## The session freezes: zero-copy DMABuf on this AMD iGPU

Symptom: the picture freezes, the controller and the keyboard stop responding, and the only way out is to close Moonlight, **stop** the app from Wolf's menu and start it again — reopening ES-DE without stopping it brings the frozen game back. It hit both RetroArch and standalone Dolphin, every system, several times an hour.

It is not a performance problem, although it looks like one. Measured on the host during a freeze: CPU 4% median across 16 threads, load 0.6, GPU 7%, 18 GB of memory free, no swap, no cgroup throttling, the ROM disk reading 32 MB in two minutes, `dmesg` clean of any amdgpu, DRM, ring-timeout or GPU-reset line. Moonlight's own overlay was perfect at the same moment: 60.04 fps end to end, 0.00% frames dropped, 1 ms network latency, 0.18 ms decode — because Wolf keeps encoding and sending the last, unchanging frame.

What the freeze actually looks like: the app container stays `Up` while its CPU falls from 0.55 core to **0.02**, and every thread of every process in it — the emulator, ES-DE, and `sway`, the nested compositor — sits in `futex_wait_queue` or `poll`, state `S`, with no thread in `D` and none inside a DRM `ioctl`. The whole graphics chain is idle, waiting for a buffer that never comes back.

Wolf logs the cause at every session start:

```
basetransform: transform could not transform video/x-raw(memory:DMABuf),
               format=DMA_DRM ... drm-format=AR24 in anything we support
basetransform: warning: not negotiated
dmabuf: gst_dmabuf_mem_unmap: Failed to synchronize DMABuf: Bad file descriptor (9)
```

This is a known upstream problem on AMD iGPUs: `games-on-whales/wolf#559` reports the same `not negotiated` on the DMABuf caps of `wolf_wayland_source`, and `#364` reports `WOLF_USE_ZERO_COPY: "FALSE"` as the workaround that avoids it. Hence `WOLF_USE_ZERO_COPY=FALSE` in `wolf.yaml`, which switches Wolf to the legacy pipeline (confirm with `docker logs wolf | grep -i pipeline` → `Using legacy pipeline on AMD`). The cost is one buffer copy per frame, and this host streams with the CPU at 4% and the GPU at 26%, so it has the headroom. Remove the variable once the zero-copy path is fixed upstream, and re-test a long session before trusting it.

**Do not update the Wolf image to fix this.** `#559` reports the regression arriving *with* the newer Fedora-based image, where the zero-copy path on an AMD iGPU produces no video at all.

### `CAP_SYS_PTRACE` on the app containers

While diagnosing the above, the ES-DE container was logging

```
amdgpu: os_same_file_description couldn't determine if two DRM fds reference
        the same file description. If they do, bad things may happen!
```

Docker's default seccomp profile allows `kcmp` only for a container that holds `CAP_SYS_PTRACE`, and Mesa uses `kcmp` to decide whether two DRM fds are the same file description. Without it Mesa guesses. `setup-wolf-config.sh` now adds `SYS_PTRACE` to `CapAdd` in `base_create_json` for the RetroArch and EmulationStation apps, which silences the warning; `seccomp=unconfined` would have worked too but drops the whole filter instead of one syscall.

**This was not the cause of the freeze** — the freeze reproduced with the capability in place. It stays because the warning describes a real hazard, and removing it costs nothing.

### Method note

Four hypotheses died on the way here, each to the same mistake: reading `max` over a long window instead of the distribution. A single bad sample made the host look CPU-saturated (3 samples of 268 above 0.8, median 0.042) and made a disk burst look like sustained load. Use median, p95 and "how many samples crossed the threshold"; `max` alone tells you almost nothing.
