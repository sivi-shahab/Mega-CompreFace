# ADR-001 — Pemisahan build & deploy unit tanpa memindahkan source

| Metadata | |
|---|---|
| Judul | ADR-001 Pemisahan build & deploy unit tanpa memindahkan source |
| Versi | 1.0.0 |
| Tanggal | 2026-09-29 |
| Owner | Tim Platform / DevOps |
| Status | Review — keputusan: **Accepted** |

| Versi | Tanggal | Penulis | Perubahan |
|---|---|---|---|
| 1.0.0 | 2026-09-29 | Claude Code | Versi awal |

## Context

Upstream CompreFace 1.2.0 mem-build admin dan api dari satu `dev/Dockerfile` multi-target. Kelima image dibangun bersama lewat `dev/docker-compose.yml` dan dirilis dengan satu versi. Modul `java/common` dan `embedding-calculator/src` dipakai bersama. Kebutuhan bank ([SPEC](../../SPEC.md) G-1, FR-01) adalah setiap service bisa di-build, di-versioning, dan di-deploy secara independen, tanpa fork yang menyulitkan sinkronisasi dengan upstream.

## Decision

- Setiap service punya **build unit sendiri** di `services/<service>/`: `Dockerfile`, `Dockerfile.dockerignore`, README, dan file pendukung.
- **Build context = root repo**. Setiap Dockerfile memakai *Dockerfile-specific ignore file* (fitur BuildKit) sehingga yang terkirim ke daemon hanya direktori yang relevan (mis. api: `java/pom.xml`, `java/common`, `java/api`).
- **Source code tidak dipindah atau diubah.** `java/`, `ui/`, dan `embedding-calculator/` tetap di lokasinya. Perilaku aplikasi disesuaikan lewat Dockerfile, env var, dan konfigurasi (Spring relaxed binding, uWSGI env, template nginx).
- Maven mem-build hanya modul yang dibutuhkan (`-pl admin -am` / `-pl api -am`).
- `scripts/build.sh` mem-build per service, per varian, dan per versi. Setiap image memiliki versi SemVer sendiri (`FE_VERSION`, `ADMIN_VERSION`, …).

## Consequences

- ✅ Rilis per service independen dan diff terhadap upstream minimal (`git diff` pada `java/ ui/ embedding-calculator/` = kosong), sehingga merge upstream lebih mudah.
- ✅ Cache build per service lebih efisien.
- ⚠️ Perubahan di `java/common` memengaruhi admin **dan** api. Keduanya harus di-build ulang dan diberi versi baru (lihat [CONTRIBUTING](../../CONTRIBUTING.md)).
- ⚠️ Membutuhkan BuildKit (Docker ≥ 23 / buildx). Builder lama akan mengabaikan `Dockerfile.dockerignore` dan mengirim seluruh repo sebagai context.
- ⚠️ Dokumen upstream dipindah ke `docs/upstream/` untuk menghindari bentrok nama (`Configuration.md` vs `CONFIGURATION.md`) di filesystem case-insensitive.
