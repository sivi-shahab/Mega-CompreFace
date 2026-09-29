# compreface-postgres-db

| Metadata | |
|---|---|
| Judul | README service compreface-postgres-db |
| Versi | 1.0.0 |
| Tanggal | 2026-09-29 |
| Owner | Tim Platform / DevOps |
| Status | Review |

| Versi | Tanggal | Penulis | Perubahan |
|---|---|---|---|
| 1.0.0 | 2026-09-29 | Claude Code | Versi awal |

## Tujuan
Database PostgreSQL untuk admin & api (user, app, collection, subject, embedding, gambar wajah, token OAuth). Skema dibuat/dimigrasi oleh **admin** (Liquibase); image ini hanya menyiapkan ekstensi `uuid-ossp` (`db/initdb.sql`). Menyimpan **data biometrik** — lihat [SECURITY](../../docs/SECURITY.md).

## File
| File | Isi |
|---|---|
| `Dockerfile` | `postgres:11.5` (di-pin digest; major tetap 11 agar kompatibel dengan data live) + `initdb.sql`; `PGDATA=/var/lib/postgresql/data/pgdata` |
| `Dockerfile.dockerignore` | Context: `db/initdb.sql`, `LICENSE`, `NOTICE` |

## Build
```bash
scripts/build.sh postgres-db                           # → mega/compreface-postgres-db:1.2.0
```

## Env var utama
`POSTGRES_DB` (`frs`), `POSTGRES_USER`/`POSTGRES_PASSWORD` (Secret; hanya diterapkan saat inisialisasi volume kosong), `PGDATA` — lengkap di [CONFIGURATION §6](../../docs/CONFIGURATION.md#6-compreface-postgres-db).

## Port & healthcheck
| Port | Healthcheck |
|---|---|
| 5432 | `pg_isready -U $POSTGRES_USER -d $POSTGRES_DB -h 127.0.0.1` |

Kubernetes: StatefulSet 1 replica + PVC (`volumeClaimTemplates`), `runAsUser/fsGroup 999`, root FS read-only (emptyDir `/var/run/postgresql`, `/tmp`). Backup/restore: [RUNBOOK §5](../../docs/RUNBOOK.md#5-backup--restore-postgres).
