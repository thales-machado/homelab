data "healthchecksio_channel" "homelab" {
  kind = "webhook"
}

# Renamed again, to what actually pings it: the DAG n8n-backup-urahara carries
# this check's id, while the DAG named sqlite-backup pinged nothing at all. The
# green light on "sqlite-backup" was borrowed from another job on another host,
# and zangetsu's own SQLite backup went unwatched. The move keeps the id, the
# ping URL and the history: with this provider a name change is an in-place
# update, which is how this same check was once renamed from vaultwarden-backup.
moved {
  from = healthchecksio_check.sqlite_backup
  to   = healthchecksio_check.n8n_backup_urahara
}

resource "healthchecksio_check" "n8n_backup_urahara" {
  name     = "n8n-backup-urahara"
  schedule = "35 2 * * *"
  timezone = "America/Sao_Paulo"
  grace    = 900
  tags     = ["dagu", "backup"]
  channels = [data.healthchecksio_channel.homelab.id]
}

# The check the sqlite-backup DAG never had. Named for its host, like every
# other pair here. Its id only exists after the first apply: read it from the
# ping_urls output and wire it into the DAG.
resource "healthchecksio_check" "sqlite_backup_zangetsu" {
  name     = "sqlite-backup-zangetsu"
  schedule = "30 2 * * *"
  timezone = "America/Sao_Paulo"
  grace    = 900
  tags     = ["dagu", "backup"]
  channels = [data.healthchecksio_channel.homelab.id]
}

resource "healthchecksio_check" "sqlite_backup_urahara" {
  name     = "sqlite-backup-urahara"
  schedule = "20 2 * * *"
  timezone = "America/Sao_Paulo"
  grace    = 900
  tags     = ["dagu", "backup"]
  channels = [data.healthchecksio_channel.homelab.id]
}

resource "healthchecksio_check" "postgres_backup" {
  name     = "postgres-backup"
  schedule = "35 2 * * *"
  timezone = "America/Sao_Paulo"
  # 900s (15min) raised false alarms when the first attempt was SIGKILLed
  # (memory pressure on the RPi5 during the Immich dump) and Dagu's retry
  # (interval_sec: 900) only finished ~15min later, seen twice in
  # production. 1500s (25min) covers one full retry with no false alarm.
  grace    = 1500
  tags     = ["dagu", "backup"]
  channels = [data.healthchecksio_channel.homelab.id]
}

resource "healthchecksio_check" "restic_backup_zangetsu" {
  name     = "restic-backup-zangetsu"
  schedule = "40 2 * * *"
  timezone = "America/Sao_Paulo"
  grace    = 2700
  tags     = ["dagu", "backup"]
  channels = [data.healthchecksio_channel.homelab.id]
}

resource "healthchecksio_check" "restic_backup_urahara" {
  name     = "restic-backup-urahara"
  schedule = "45 2 * * *"
  timezone = "America/Sao_Paulo"
  grace    = 2700
  tags     = ["dagu", "backup"]
  channels = [data.healthchecksio_channel.homelab.id]
}

resource "healthchecksio_check" "restic_prune_zangetsu" {
  name     = "restic-prune-zangetsu"
  schedule = "0 4 * * 0"
  timezone = "America/Sao_Paulo"
  grace    = 3600
  tags     = ["dagu", "backup"]
  channels = [data.healthchecksio_channel.homelab.id]
}

resource "healthchecksio_check" "restic_prune_urahara" {
  name     = "restic-prune-urahara"
  schedule = "30 4 * * 0"
  timezone = "America/Sao_Paulo"
  grace    = 3600
  tags     = ["dagu", "backup"]
  channels = [data.healthchecksio_channel.homelab.id]
}

resource "healthchecksio_check" "immich_album_naming" {
  name     = "immich-album-naming"
  schedule = "0 4 * * 0"
  timezone = "America/Sao_Paulo"
  grace    = 1800
  tags     = ["dagu"]
  channels = [data.healthchecksio_channel.homelab.id]
}

# Created through the API by scripts/monitoring/check-wolf-image-updates.sh
# before this file existed; adopted with `terraform import`, never recreated,
# so the id the script looks up by name stays the same.
#
# Unusual on purpose: it pings /fail to report that a new image digest is
# waiting on GHCR, so "down" here means "there is an update to review", not
# "the job broke". Monthly, because that is the DAG's schedule.
resource "healthchecksio_check" "wolf_image_check" {
  name     = "wolf-image-check"
  desc     = "Wolf pinned digests vs. GHCR. A failure means an update is available, not a broken job."
  schedule = "0 9 1 * *"
  timezone = "America/Sao_Paulo"
  grace    = 172800
  tags     = ["dagu", "homelab"]
  channels = [data.healthchecksio_channel.homelab.id]
}

output "ping_urls" {
  value = {
    sqlite_backup_zangetsu = "https://healthchecks.lan.thalespm.me/ping/${healthchecksio_check.sqlite_backup_zangetsu.id}"
    n8n_backup_urahara     = "https://healthchecks.lan.thalespm.me/ping/${healthchecksio_check.n8n_backup_urahara.id}"
    wolf_image_check       = "https://healthchecks.lan.thalespm.me/ping/${healthchecksio_check.wolf_image_check.id}"
    sqlite_backup_urahara  = "https://healthchecks.lan.thalespm.me/ping/${healthchecksio_check.sqlite_backup_urahara.id}"
    postgres_backup        = "https://healthchecks.lan.thalespm.me/ping/${healthchecksio_check.postgres_backup.id}"
    restic_backup_zangetsu = "https://healthchecks.lan.thalespm.me/ping/${healthchecksio_check.restic_backup_zangetsu.id}"
    restic_backup_urahara  = "https://healthchecks.lan.thalespm.me/ping/${healthchecksio_check.restic_backup_urahara.id}"
    restic_prune_zangetsu  = "https://healthchecks.lan.thalespm.me/ping/${healthchecksio_check.restic_prune_zangetsu.id}"
    restic_prune_urahara   = "https://healthchecks.lan.thalespm.me/ping/${healthchecksio_check.restic_prune_urahara.id}"
    immich_album_naming    = "https://healthchecks.lan.thalespm.me/ping/${healthchecksio_check.immich_album_naming.id}"
  }
}
