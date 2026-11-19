# Backlog

Open items that are not conventions and not quirks: things known to be wrong or
unfinished, with enough context to pick them up cold. Delete an entry when it is
done; delete this file when it is empty.

## Calnode cannot read calendar availability (2026-11-19)

Booking a slot fails with "Calendar Availability could not be checked", and the
container logs `gcal: freeBusy status 403`. A 403 there is either the Google
Calendar API not being enabled on the GCP project that issued Calnode's OAuth
client, or a token issued without the scope `freeBusy` needs.

Triage in that order. Enable the API in the console first: an already-issued
token keeps working, so that fix needs nothing else. If the API is already
enabled, it is the scope, and the console cannot fix it: disconnect the
calendar inside Calnode and connect it again, because an existing token never
gains a scope retroactively. The body of the Google error names which one it is
(`accessNotConfigured` against `insufficientPermissions`); read it before
changing anything.

## Wolf image pins are behind (2026-11-01)

`wolf-image-check` has been down since 2026-11-01, which is the check doing its
job: at least one of the four pinned digests (`wolf`, `wolf-ui`, `retroarch`,
`es-de`) moved on GHCR, and `es-de` is roughly six months old. `DRY_RUN=1 sh
scripts/monitoring/check-wolf-image-updates.sh` lists exactly which, without
touching Healthchecks. Bumping them needs a real stream test, so it is a session
of its own, and the reply to upstream issue #576 waits for it.

## Dead duplicates in zangetsu's ~/.bashrc (2026-11-19)

`hlab`, `homelab-cp` and `tf` are now versioned in
`scripts/shell/homelab-functions.sh`, which `~/.bashrc` sources at the end, so
the versioned definitions win. The older copies above that line still exist and
are inert. They are worth removing: a drifted duplicate that silently loses to
the one below it is exactly what cost half a day on 2026-11-19, when a fix was
applied to the copy that never runs.

## Commit f284b56 has a placeholder subject

It landed on `main` as `Generating commit message...`, the IDE's temporary text.
Fixing it means rewriting published history, which this repo deliberately does
not do. Left as is unless the public history matters more than the rule.
