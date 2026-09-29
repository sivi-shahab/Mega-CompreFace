# Changelog

| Metadata | |
|---|---|
| Judul | Changelog CompreFace (mega) |
| Versi | 1.0.0 |
| Tanggal | 2026-09-29 |
| Owner | Tim Platform / DevOps |
| Status | Review |

| Versi | Tanggal | Penulis | Perubahan |
|---|---|---|---|
| 1.0.0 | 2026-09-29 | Claude Code | Entri awal |

Format mengikuti [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/). Setiap image di-versioning independen ([SemVer](https://semver.org/)); versi image yang dirilis dicantumkan per entri.

## [Unreleased]

## [1.2.0-mega.1] - 2026-09-29

Rilis awal repackaging dari upstream `exadel-inc/CompreFace` 1.2.0 (commit `ddf32da82`).

Image: `mega/compreface-fe:1.2.0`, `mega/compreface-admin:1.2.0`, `mega/compreface-api:1.2.0`, `mega/compreface-core:1.2.0`, `mega/compreface-core:1.2.0-arcface-r100-gpu`, `mega/compreface-postgres-db:1.2.0`.

### Added
- Build unit per service di `services/<service>/` (multi-stage, base image di-pin digest, `Dockerfile.dockerignore` per service) — ADR-001.
- `services/compreface-core/build-args.env`: varian `default` (FaceNet CPU), `arcface-r100-gpu` (prod), `arcface-r100`, `facenet`, `mobilenet`, `mobilenet-gpu` — ADR-005.
- `scripts/build.sh` (per service/varian/versi, tolak `latest`, label OCI) dan `scripts/push.sh` (push + catat digest, atau `--save` tarball + SHA256SUMS untuk air-gapped).
- `scripts/e2e-test.sh`, `scripts/db-record-counts.sql`, `scripts/db-purge-orphan-images.sql`, `scripts/check-docs.sh`.
- Manifest Kubernetes `k8s/base` + `k8s/overlays/{dev,prod}`: Deployment/StatefulSet+PVC, Service, ConfigMap (generator ber-hash), NetworkPolicy default-deny, Pod Security `restricted`, PDB, contoh HPA & Ingress — ADR-003.
- `docker-compose.yml` baru (image `mega/*`, read-only, non-root, healthcheck dependency) + `docker-compose.gpu.yml` + `.env.example`.
- Dokumentasi SDLC: `SPEC.md`, `docs/{ARCHITECTURE,CONFIGURATION,DEPLOYMENT,MIGRATION,RUNBOOK,SECURITY,TEST_PLAN}.md`, `docs/adr/`, bukti uji `docs/test-evidence/2026-09-29/`.
- `NOTICE` (atribusi upstream).
- Endpoint `/healthz` di fe; management port 8081 untuk probe admin/api.

### Changed
- fe: `nginx-unprivileged` (uid 101, port 8080); `nginx.conf.template` dengan envsubst + `resolver` dinamis + upstream dari env (`ADMIN_UPSTREAM`, `API_UPSTREAM`) — ADR-004.
- admin/api: build Maven per modul (`-pl … -am`), runtime non-root uid 1001, `MaxRAMPercentage` alih-alih `-Xmx` tetap.
- core: multi-stage (toolchain build tidak ikut ke runtime), non-root (uid 33), `uwsgi.ini` tanpa setuid, port dari `ML_PORT`; model ML disalin dari image resmi Exadel yang di-pin digest (`MODEL_SOURCE=image`), checksum di `/app/ml/.models/MODELS.sha256`; apt dikunci ke `snapshot.debian.org` — ADR-002.
- postgres-db: `PGDATA=/var/lib/postgresql/data/pgdata` (aman untuk PVC), bisa berjalan langsung sebagai uid 999 dengan root FS read-only.
- Dokumentasi upstream dipindah ke `docs/upstream/` (README → `README-upstream.md`, CONTRIBUTING → `CONTRIBUTING-upstream.md`); link relatif disesuaikan.

### Removed
- Route `/core/` di fe (core tanpa autentikasi terekspos lewat UI).
- `APPERY_API_KEY` (telemetry ke api.appery.io) dari image admin.
- `.env` di root repo (kredensial default `postgres/postgres`); gunakan `.env.example`.

### Fixed
- `compreface-ui` restart loop (`host not found in upstream "compreface-core:3000"`) — resolver dinamis; fe tetap hidup tanpa backend.
- `compreface-core` tidak berjalan (image varian tidak tersedia) — image core dibangun sendiri dan dapat ditransfer ke registry internal.
- Healthcheck admin `DOWN` karena `MailHealthIndicator` saat email nonaktif (`MANAGEMENT_HEALTH_MAIL_ENABLED=false`).
- Build core gagal karena model Google Drive upstream kini meminta sign-in dan repo `bullseye-security` mengembalikan 404.

### Security
- Semua container non-root, `readOnlyRootFilesystem`, drop ALL capabilities, seccomp `RuntimeDefault`.
- Credential hanya dari Secret/`.env` (tidak di image/git); `security.signing-key` hardcoded upstream di-override dari Secret.
- Log prod INFO (stack lama DEBUG + request logging).
- Known issue (upstream): penghapusan subject meninggalkan gambar wajah di tabel `img` — mitigasi `scripts/db-purge-orphan-images.sql` (SECURITY S-13).
