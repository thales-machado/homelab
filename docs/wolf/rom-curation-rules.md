# ROM curation (Wolf)

Rules for reducing the full MAME romset (~43,000 files in `roms/mame`, most of them clones, revisions and bootlegs of the same game) to one set holding the best version of each game, without deleting anything that is not used.

## Why this exists

MAME preserves **every** ROM file that ever existed for a game: each firmware revision, each sales region (World/USA/Europe/Japan/…) and each bootleg becomes its own `.zip`. ES-DE and RetroArch therefore list dozens of entries for the same game (Street Fighter II alone had 104 files in `roms/mame`), most of them there for preservation completeness rather than because they are worth playing.

## Which file becomes the "main" one

Within each game family (one parent plus its clones):

1. **Never pick a bootleg**: the manufacturer appears as `"bootleg"` instead of the official one in MAME's source. It is an unofficial copy, sometimes with a hack or an introduced bug.
2. **Region priority**: `World` > `USA` > `Europe` > `Japan` > others. "World" is the most neutral version (no region lock, no specific localization) and the convention preservation curations use ("1G1R", 1 Game 1 ROM).
3. **Within the chosen region, take the latest revision** (the highest date in the name or description), assuming later revisions fix bugs. **Careful**: the set MAME marks as the parent (`cloneof = 0`) is not necessarily the newest or the oldest revision, only the best documented one. Always compare the dates of every clone in the family instead of assuming the parent is the best choice.

## Identifying parent and clone

**Common datfiles do not carry that information.** Tested with "MAME 0.289 ROMs (split)": it lists only name, CRC and SHA1, with no `cloneof` / `romof`. Good for integrity checking, not for curation.

The real source is **MAME's own source code** (`src/mame/<manufacturer>/<driver>.cpp`, github.com/mamedev/mame), through each game's registration macro:

```cpp
GAME( year, short-name, parent, ... )
```

- `parent = 0` → this set is the **parent** (not a clone of anything).
- `parent = <another game's name>` → this set is a **clone** of that game.

**A confirmed special case (`neogeo.cpp` and others)**: every Neo Geo game declares `parent = "neogeo"` literally. That does **not** mean "clone of the game called neogeo"; it is just the driver's mechanism for inheriting the BIOS configuration. The same pattern exists for dozens of other boards (generic PC / `ibm5150`, Aristocrat MK5/MK6, Sega ST-V, Konami System 573, IGS PGM, Nintendo PlayChoice-10, Barcrest MPU4, …), where **completely different** games share a "parent" only because they run on the same hardware.

This has to be done **driver by driver** (each `.cpp` covers one manufacturer or board); it cannot be generalized into a single command over all 43,000 files.

## Telling a "hardware parent" from a real game parent

Confirmed while curating `mame`: naively treating every `parent` chain as "revisions of the same game" nearly caused a disaster, grouping **5,560 files** into 138 families, the vast majority of them completely different games (`neogeo` as the root merged 277 distinct Neo Geo games; `ibm5170` merged 351 different PC titles). The checks used, in this order:

1. **MAME's own flag**: `MACHINE_IS_BIOS_ROOT` as the last argument of `GAME()` / `CONS()`. A direct, reliable signal that the name is a board or BIOS rather than a playable game. It covers most cases (`neogeo`, `aristmk5`, `aristmk6`, `pgm`, `sys573`, `playch10`, `stvbios`, `v4bios`, …).
2. **Manufacturer diversity**: if, ignoring bootlegs and hacks, the family has **more than 2 distinct manufacturers** (normalized by cutting everything after `(`, so that `"Konami (Olympia license)"` is not counted as a different manufacturer from `"Konami"`), treat it as a platform. A real clone family is almost always from the same official manufacturer. This criterion alone catches cases the flag misses: `ibm5150` (108 members, 47 manufacturers) and `ibm5170` (363 members, 126 manufacturers) carry no `MACHINE_IS_BIOS_ROOT`, but the manufacturer spread gives the same verdict.
3. **Never use family size on its own.** Tested and reverted: a "more than 20 members means platform" cut looked like a reasonable safety net, but it wrongly excluded single-game families with many regional betting or jackpot variants (common in British slot machines: `pr_7hvn`, "777 Heaven", has 22 variants of the same game from a single manufacturer, with no platform involved). With `MACHINE_IS_BIOS_ROOT` plus manufacturer diversity covering the real cases (confirmed against `ibm5150`, `ibm5170`, `neogeo`, `aristmk5`, `aristmk6` after removing the size cut), the size criterion adds nothing but false positives.
4. **The resolution chain stops at the first node marked as a BIOS root** and does not cross it. For example `100lionsa` → `100lions` → `aristmk6` (BIOS root): the chain stops at `100lions`, which becomes the family root (only itself plus `100lionsa`), without dragging in the 300+ other games that also reference `aristmk6`.

Any family caught by any of those three criteria is **left alone**: nothing is moved. A false negative (a real family that was not deduplicated) is always preferable to a false positive (different games treated as clones of each other).

## Traps confirmed during the real run

Found while running the full `mame` curation; kept here so the same mistakes are not repeated on other systems.

- **Game names starting with a digit** (`99lstwar`, `100lions`, `1942`, `007`, …): a regex requiring a leading letter (`[A-Za-z_]…`) loses them silently into the "unresolved" bucket. Use `[A-Za-z0-9_]+` for both the name and the parent when extracting from `GAME()`.
- **"Phantom parent"**: some games point at a `parent` that only has a `ROM_START` in the source and was never exposed through `GAME()` (not playable on its own; used only as a shared ROM container for renamed releases). When the parent is not a resolvable machine (neither among the local files nor registered through `GAME()`) **but is not a known BIOS root either**, group by the **parent's name anyway** (`return parent`, not `return name`), or each clone becomes its own one-member family and they are never compared.
- **Firmware/BIOS variants named `<base>__<suffix>`** (`m4tenten__0` … `m4tenten__z`, up to 100 files for the same game) are firmware or protocol options of the **same physical machine**, expanded by the datfile as pseudo-separate entries. They never appear in `GAME()` in the source, so parent/clone extraction cannot see them. They need their own detection by filename pattern (`^(.+)__[0-9a-z]+$`), grouped by the base name. **Important**: those groups must not go through the size or manufacturer-diversity checks, since by construction they are guaranteed to be the same game, and such families easily pass 20 members (`ec_redbr` reached 100) without being a platform.
- **Some drivers define their OWN registration macro wrapping `GAME()` / `GAMEL()`** (`GAME_CUSTOM` in `barcrest/mpu4mod4oki.cpp`, 3,379 occurrences in that one file). Those macro names do not match a fixed list (`GAME` / `GAMEL` / `CONS` / `COMP` / `COMPX` / `SYST`) and are **completely invisible** to name-exact extraction. This was the bug that affected the most files at once (one game alone had 56 untouched files). Fix: match any macro whose name **contains** one of those tokens as a substring (`[A-Z_]*(?:GAME|GAMEL|CONS|COMP|COMPX|SYST)[A-Z_]*`), which covers `GAME_CUSTOM`, `CUSTOM_GAME` and so on with no per-driver list.
- **An inline C comment before the macro on the same line** (`/* Naomi */ GAME( 1998, naomi, 0, ... )` in `sega/naomi.cpp`): a regex anchored at `^\s*GAME\(` does not match, because the first non-space token is `/*`. It affected the whole `naomi` family, including `naomi` itself as a BIOS root, which broke the "stop at the BIOS" rule for every clone depending on it. Fix: allow an optional `/* … */` comment before the macro name in the anchor.
- **Downloads of large source files fail silently** (normal size, no error, but the content the extraction expects is not there), seen twice each with `misc/proconn.cpp` and `sega/naomi.cpp`. Checking the HTTP `Content-Length` against the downloaded size helps catch network truncation, but it was not the real cause in those cases (the file downloaded fully, the regex just did not find the pattern). Even with the check, always re-verify a suspicious driver by hand (`grep` / `wc -l` on the downloaded file) before concluding "there are no games here".
- **A driver whose download fails leaves its games permanently uncurated**, with no explicit warning among thousands of others. `misc/proconn.cpp` (where `pr_7hvn` is defined) failed silently in one round and its 22 files stayed untouched until a later visual audit. Re-running the download fixes it (the failure looks transient or rate-limited rather than a permanent 404). The ~13 device/skeleton files that fail **every** time are real 404s (renamed or removed upstream) and are accepted as a limitation.
- **ALWAYS do a full dry run before moving any real file, and repeat the global duplicate check after every round.** Each bug above only showed up in a manual audit after the run (a visible duplicate in ES-DE), never in a spot test of one or two families. It took **4 rounds** of run plus fix to really reach zero duplicates in `mame`. Final check: no datfile `description` may repeat among the files left in `roms/<system>/`.
- **A whole family can end up with no representative in `roms/mame`.** Found while resolving 4 games for a favorites list (`pacman`, `dkong`, `kof98`, `sfiii3`): the family had been correctly grouped and moved to `roms-clones/mame/<parent>/`, but the "pick one winner and put it back in `roms/mame`" step failed silently for those 4, so the whole game disappeared from the playable library, not just its clones. A "zero duplicates" check cannot catch this (a duplicate means more than one file for the same `description`; here there are **zero**). Fixed by restoring the best candidate from each clone folder by hand. **Still open**: there has been no systematic audit of "families with zero representative" across the whole romset, only those 4 found by chance. Run that check (every folder in `roms-clones/mame/<parent>/` should have a matching `<parent>` or equivalent sitting in `roms/mame`) before considering the clone curation finished.
- **Never assume a family from a name prefix.** An earlier survey counted "ungrouped large families" with `grep "^sf2"` and similar, which mixes games from completely different franchises that happen to share leading letters. Checking each case against the real driver source (`GAME()` / `cloneof`) corrected almost all of it: `sf2` is in fact **3 distinct games** (World Warrior, Champion Edition, Hyper Fighting, each its own parent) with one file each; the real `tmnt` family (Konami, `konami/tmnt.cpp`) already had only `tmnt.zip`, and the other six `tmnt*` files are entirely different products (Turtles in Time with its own driver, a Data East pinball, four plug-and-play handhelds); `xmen`, `outrun`, `gng`, `1942` and `bublbobl` already had one file each (a lone clone with no parent present is an absence, not a duplicate, and is acceptable); `ddragon` is 3 distinct families; `galaga` is 2 different games; `tetris` is **4 different implementations** by different manufacturers on different hardware (Sega System 16A, Sega System E, Jaleco Tetris Plus, Jaleco Tetris Plus 2), one file each.
  **The only family with a real duplicate was `galaxian`**: all 13 files come from the same driver (`galaxian/galaxian.cpp`) and the same family. Resolved by keeping `galaxian.zip` (the parent, Namco "set 1", no bootleg or regional license) and moving the other 12 to `roms-clones/mame/galaxian/` (7 bootlegs plus 5 licensed variants losing to the official parent).

## What happens to what is not used

**Never delete.** Move it to a parallel folder on the same disk, outside what RetroArch and ES-DE scan:

```
retro/roms-clones/<system>/<parent-game>/
```

- `<system>`: the same name used in `roms/<system>/` (lowercase, ES-DE convention).
- `<parent-game>`: the family's parent set (`sf2`, not `sf2ce`; those are different families even though the names start the same).
- No extra subfolder per release or region inside each game: the file name already identifies the revision (`sf2ea.zip`, `sf2j17.zip`, …), so another layer gains nothing.
- This disk is neither synced nor backed up on purpose (ROMs are re-downloadable), as described in the storage conventions.

## Removing content that is not a traditional game

Separate from the clone curation above: here the criterion is not "duplicate" but "this is not a game to play". MAME preserves any emulable machine, including hardware that was never meant as entertainment.

**Categories confirmed and removed from `roms/mame`** (never deleted, moved to `retro/roms-excluded/mame/<category>/`, same principle as the clone curation):

- **`slot-machines`**: real betting machines (casino or pub), with no story, only a betting and reels mechanism. Whole folders: `barcrest`, `bfm`, `maygay`, `jpm`, `igt`, `aristocrat`, `amcoe`, `funworld`, `astrocorp`, `subsino`, `sigma`, `midcoin`, `acorn` (which mixes `aristmk5` with real Acorn computers, see the note below). Plus a keyword filter in **mixed** folders that also hold relevant arcade games: `dynax` (description contains `mahjong` / `pachinko`; the folder is mostly betting mahjong, but about 15 legitimate arcade games stayed, such as Rong Rong, Real Break and the Quiz series) and `bally` (description contains `poker`, plus a fixed list of console BIOS and sound test boards with no game: `astrocde`, `astrocdl`, `astrocdw`, `midcsd`, `midssio`, `sente6vb`, `sentetst`; the rest of `bally` was left untouched, being a genuine classic arcade catalog: Tron, Spy Hunter, Wizard of Wor, Tapper, Rampage, Trivial Pursuit).
- **`computers`**: a generic personal-computer platform with no specific game loaded (the "machine" is just the base hardware). Folders: `pc` (IBM and clone motherboards), `msx`, `apple` (including Franklin ACE-style clones), `sinclair` (ZX Spectrum and clones), `commodore`, `vtech`, `ussr` (Soviet clones).
- **`peripherals`**: expansion or accessory boards that never run on their own (the `devices/` folder: modem, network card, printer interface, floppy controller).
- **`skeleton`**: MAME's own convention for "barely emulated, practically does not work" (the `skeleton/` folder): teletext terminals, a mobile-phone tester, obscure office computers.
- **`calculator-pda`**: the `ti` folder (Texas Instruments), an Avigo PDA and pocket calculators/computers, no game.
- **`chess`**: dedicated chess computers (the hardware only plays chess against you; it is not a video game). Folders: `fidelity`, `hegenerglaser` (Mephisto), `newcrest` (which despite the generic name is also chess: Chess 2001, Computachess, Sphinx Commander).

**Note on the `acorn` folder**: for historical code reasons (ARM hardware), the Aristocrat MK5 (`aristmk5.cpp`) lives inside MAME's `acorn/` folder along with real Acorn computers (BBC Micro, Archimedes, Electron). That is not a miscategorization on our side, it is literally where MAME keeps the driver. Since both kinds of content in that folder already fall under exclusion categories, the whole folder was removed with no extra check.

**Before excluding a whole folder, always check a sample of its real content** (`description` and `manufacturer` of a few files). Folder names mislead: `newcrest` looks like slot machines but is chess; `alliedleisure`, `yunsung` and `stern` sound like gambling but are real arcade manufacturers (Aztarac, Megatack, Berzerk, Bomb Kick); `dynax` and `bally` mix relevant games with excludable content.

**Second round**: a review after the first pass ("check that we only have games") found whole categories the first round had missed, all handled the same way (move to `roms-excluded/mame/<category>/`, never delete):

- **`terminals-computers`**: additional computer, terminal and workstation brands not covered by round 1's generic folders (DEC, Wang, Xerox, TeleVideo, Tektronix, IBM terminals, Olivetti, Amstrad, TRS, …).
- **`io-devices`**: internal I/O boards and chips that are never "the game" (Namco sound and input boards 50xx-76xx, Sega I/O boards, a keyboard treated as a peripheral).
- **`synthesizers`**: real musical keyboards and sound modules (Roland, Korg, Akai, Kawai, Ensoniq, Novation). MAME emulates the sound hardware; there is no game.
- **`bios-no-game`**: platform BIOS with no game loaded (NAOMI, System 573, PlayChoice-10, 3DO, CD-i, ST-V). They were already treated as hardware parents in the clone curation (never merged into a game), but until this round they were still physically in `roms/mame` with no game attached.
- **`chess`** (more): further chess-computer brands that slipped through (Saitek, Novag, the `chess` and `chessking` folders).
- **`slot-machines`** (more): betting items that escaped round 1's folder filter (`unkanyw`, `telmahjn`, `vscompmj`, `mc_mk4_hopper`).

That round moved 714 files (10,849 → 10,135 in `roms/mame`).

## Scope and state

- **MAME: in progress, not finished.** Of the original 43,394 files in `roms/mame`, 6 rounds of clone curation left **17,539**; removing non-game content in 2 rounds (6,690 then 714) left **10,135**; restoring families with no representative added 4 back; and the `galaxian` round moved 12 more, for **10,127** today. The rest is in `roms-clones/mame/` and `roms-excluded/mame/`.
  **Important caveat**: the automatic "zero duplicates" check has passed green in earlier rounds and real visible duplicates still appeared in the next one. The `description` check has blind spots: it does not cover an extraction bug that is never reached (such as the custom macros) or a family left with **zero** representatives. **Do not treat "zero duplicates in the automatic check" as a guarantee.** If duplicates are still visible (or a classic game is missing) in ES-DE or RetroArch after a round, that is another extraction bug to find, not noise.
  **Known open items**: (1) the systematic audit of families with zero representative across the whole romset (only 4 cases fixed so far); (2) a third round of non-game removal (247 candidate files, catalogued in 9 categories including two new ones, electronic toys and internal tests), reviewed and **deliberately not applied** for now.
- Every move is logged (file → family → winner kept) in `retro/roms-clones/_curation-log/mame-move-log-<date>-batch<N>.tsv`.
- Other systems (`roms/<system>/`) have no curation applied yet; they are only touched on request.
- **Nothing is applied in production without explicit confirmation.** This document defines the rules; running it (actually moving files) is a separate, always-reviewed action.
