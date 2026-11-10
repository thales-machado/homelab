---
name: backup
description: Use when adding backup for a new database (SQLite/Postgres), investigating a backup failure, or working with Restic (repository, DAGs, prune, restore) on zangetsu/urahara.
---

Read all of `docs/backup.md` before acting.

Things that must not be forgotten:
- A database is never covered by Restic's hot copy: always take a consistent snapshot through Dagu (SQLite `.backup`, Postgres `pg_dump`) before Restic runs.
- A new service with its own database only gets a line in the existing script (`backup-sqlite.sh` / `backup-postgres.sh`), never a new DAG. `restic-excludes.txt` already covers the generic pattern; only touch it when the database falls outside it.
- The `postgres-backup` runner image (`postgres:<N>-alpine`) must be the same major as or newer than the newest Postgres in the stack: `pg_dump` refuses a server newer than the client.
- The urahara DAGs use `action: ssh.run`, not `docker.run`. A `command:` with `\$` or `$()` needs the `\$` escaped **and** an explicit `shell: /bin/sh`, or Dagu undoes the escaping before sending it over SSH and the variable arrives empty.
- Never create one central Restic repository for more than one host: each host with data to protect has its own mount and its own pair of DAGs (backup and prune).
