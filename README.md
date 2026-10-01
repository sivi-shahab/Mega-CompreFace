# CompreFace (mega) — build & deploy unit per service untuk Kubernetes

| Metadata | |
|---|---|
| Judul | README — CompreFace (repackaging mega untuk Kubernetes on-prem/air-gapped) |
| Versi | 1.0.0 |
| Tanggal | 2026-09-29 |
| Owner | Tim Platform / DevOps |
| Status | Review |

| Versi | Tanggal | Penulis | Perubahan |
|---|---|---|---|
| 1.0.0 | 2026-09-29 | Claude Code | Versi awal |

Repositori ini berisi [CompreFace](https://github.com/exadel-inc/CompreFace) 1.2.0 (Apache 2.0, © Exadel & kontributor). CompreFace dipisah menjadi **5 image yang bisa di-build, di-versioning, dan di-deploy secara independen** (`mega/compreface-*`), lengkap dengan manifest Kubernetes (kustomize) untuk lingkungan bank yang on-prem dan air-gapped. Source aplikasi upstream **tidak diubah**. README asli upstream: [docs/upstream/README-upstream.md](docs/upstream/README-upstream.md).

> ⚠️ Sistem ini memproses **data biometrik wajah** (Data Pribadi Spesifik, UU PDP). Baca [docs/SECURITY.md](docs/SECURITY.md) sebelum deploy.

## Arsitektur singkat

```
 Client/Browser ──HTTPS──▶ Ingress ──▶ compreface-fe (nginx, UI Angular)
                                          │ /admin/**            │ /api/v1/**
                                          ▼                      ▼
                                   compreface-admin        compreface-api ──▶ compreface-core (ML, GPU di prod)
                                          │                      │
                                          └──────▶ compreface-postgres-db (StatefulSet + PVC) ◀──┘
```

| Service | Fungsi | Image | Port | Health |
|---|---|---|---|---|
| [compreface-fe](services/compreface-fe/README.md) | UI + reverse proxy | `mega/compreface-fe:1.2.0` | 8080 | `/healthz` |
| [compreface-admin](services/compreface-admin/README.md) | User, aplikasi, collection, OAuth, migrasi skema | `mega/compreface-admin:1.2.0` | 8080 / 8081 | `:8081/actuator/health` |
| [compreface-api](services/compreface-api/README.md) | REST API recognition/verification/detection | `mega/compreface-api:1.2.0` | 8080 / 8081 | `:8081/actuator/health` |
| [compreface-core](services/compreface-core/README.md) | Deteksi wajah & embedding (model ter-bake) | `mega/compreface-core:1.2.0` (FaceNet CPU) · `:1.2.0-arcface-r100-gpu` (prod) | 3000 | `/healthcheck` |
| [compreface-postgres-db](services/compreface-postgres-db/README.md) | PostgreSQL 11.5 | `mega/compreface-postgres-db:1.2.0` | 5432 | `pg_isready` |

Detail: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Quickstart

### Build (mesin berinternet, Docker + BuildKit)
```bash
scripts/build.sh --variant default,arcface-r100-gpu all       # atau: scripts/build.sh api
```

### Jalankan lokal (docker compose)
```bash
cp .env.example .env            # WAJIB isi POSTGRES_PASSWORD & SECURITY_SIGNINGKEY
docker compose up -d --wait                                            # core FaceNet CPU
# atau varian produksi (GPU):
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d --wait
```
Buka `http://localhost:8000`. User pertama yang register menjadi OWNER. Uji end-to-end: `scripts/e2e-test.sh http://127.0.0.1:8000`.

### Deploy ke Kubernetes
```bash
scripts/push.sh --save /media/transfer        # atau push langsung ke registry internal
kubectl apply -k k8s/overlays/dev             # prod: k8s/overlays/prod (buat Secret dulu)
```
Langkah lengkap (prasyarat, Secret, placeholder, verifikasi, rollback): [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).

## Struktur repo

```
SPEC.md                    spesifikasi (FR/NFR, kontrak, acceptance criteria)
services/<service>/        build unit: Dockerfile (+ .dockerignore, README, file pendukung)
k8s/base, k8s/overlays/    manifest kustomize (dev, prod)
scripts/                   build.sh, push.sh, e2e-test.sh, check-docs.sh, SQL operasional
docker-compose*.yml        deploy lokal / verifikasi
docs/                      dokumentasi SDLC (di bawah); docs/upstream/ = dokumentasi asli CompreFace
java/ ui/ embedding-calculator/ db/   source upstream (tidak diubah)
dev/ custom-builds/        artefak build upstream lama (referensi; tidak dipakai alur baru)
```

## Dokumentasi

| Dokumen | Isi |
|---|---|
| [SPEC.md](SPEC.md) | Latar belakang, scope, FR/NFR, kontrak antar-service, versioning, risiko, acceptance criteria |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Komponen, alur data & data biometrik, dependency & urutan startup |
| [docs/CONFIGURATION.md](docs/CONFIGURATION.md) | Semua env var, Secret, build args, sizing core |
| [docs/RUNNING.md](docs/RUNNING.md) | Menjalankan stack docker compose (GPU SubCenter-ArcFace-r100), restore data, file model, rollback |
| [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) | Build, transfer air-gapped, deploy per environment, verifikasi, rollback |
| [docs/MIGRATION.md](docs/MIGRATION.md) | Migrasi compose → Kubernetes termasuk data Postgres, cutover, go/no-go, rollback |
| [docs/RUNBOOK.md](docs/RUNBOOK.md) | Operasional harian, scaling, backup/restore, troubleshooting, eskalasi |
| [docs/SECURITY.md](docs/SECURITY.md) | Secret, hardening, NetworkPolicy, UU PDP, gap |
| [docs/TEST_PLAN.md](docs/TEST_PLAN.md) | Test case, traceability matrix, hasil uji |
| [docs/adr/](docs/adr/README.md) | Architecture Decision Records |
| [CHANGELOG.md](CHANGELOG.md) | Riwayat perubahan |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Branching, commit, build & test lokal, review |
| [docs/upstream/](docs/upstream/README.md) | Dokumentasi asli CompreFace (REST API, plugin, konfigurasi upstream) |

## Lisensi

Apache License 2.0 — lihat [LICENSE](LICENSE) dan [NOTICE](NOTICE). Atribusi dan header copyright upstream dipertahankan.
