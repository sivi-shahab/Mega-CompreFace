# ADR-002 — Model ML di-bake ke image core untuk air-gapped

| Metadata | |
|---|---|
| Judul | ADR-002 Model ML di-bake ke image core |
| Versi | 1.0.0 |
| Tanggal | 2026-09-29 |
| Owner | Tim Platform / DevOps |
| Status | Review — keputusan: **Accepted** |

| Versi | Tanggal | Penulis | Perubahan |
|---|---|---|---|
| 1.0.0 | 2026-09-29 | Claude Code | Versi awal |

## Context

- Upstream mengunduh model ML **saat build** dari Google Drive (`gdown`, `src/services/facescan/plugins/setup.py`). Saat runtime, plugin InsightFace melempar `ModelImportException` bila model tidak ada, tanpa mengunduh.
- Lingkungan target on-prem dan **air-gapped** ([SPEC](../../SPEC.md) NFR-09). Pod core tidak boleh punya egress sama sekali (NFR-07).
- Temuan Fase 4 (2026-09-29): semua file model upstream di Google Drive kini **meminta sign-in**. `gdown` gagal ("Access denied"), dan `curl` ke `drive.usercontent.google.com` mengembalikan halaman login. Build upstream apa adanya tidak lagi bisa dijalankan.
- Repo Debian `bullseye-security` (base `python:3.8-slim-bullseye`) sedang dipindah pasca-EOL, dan sebagian paket mengembalikan 404.

## Decision

1. **Semua model di-bake ke image** di `/app/ml/.models`. Container core berjalan tanpa jaringan keluar, dibuktikan dengan uji `docker run --network none`.
2. **Sumber model = image resmi Exadel** yang dipin digest, lewat build arg `MODEL_SOURCE=image` dan `MODELS_IMAGE=exadel/compreface-core:<tag>@sha256:…`. Nilainya didefinisikan per varian di [`build-args.env`](../../services/compreface-core/build-args.env). Varian GPU memakai image CPU bermodel sama (`1.2.0-arcface-r100`) agar unduhan lebih kecil. `setup.py` upstream tetap dijalankan untuk meng-install dependency pip plugin, dan otomatis melewati download karena model sudah ada.
3. Build memverifikasi setiap plugin yang dikonfigurasi memiliki model (build gagal bila tidak), lalu menulis `/app/ml/.models/MODELS.sha256` untuk audit integritas. Label image `id.co.bankmega.compreface.core.model-source` mencatat sumber model.
4. `MODEL_SOURCE=gdrive` tetap tersedia sebagai perilaku upstream, jika suatu saat Drive dapat diakses lagi.
5. apt pada base CPU dikunci ke `snapshot.debian.org` dengan build arg `DEBIAN_SNAPSHOT=20260801T000000Z`, sehingga build reproducible.

## Consequences

- ✅ Runtime core 100% offline. Model identik dengan yang dipakai produksi: cosine similarity embedding image baru vs image resmi = 0,999992 ([bukti](../test-evidence/2026-09-29/tc-embedding-compat.txt)).
- ✅ Build tidak bergantung pada Google Drive.
- ⚠️ Build **membutuhkan akses ke Docker Hub** (atau mirror internal berisi image `exadel/compreface-core` dengan digest yang sama) dan ke snapshot.debian.org, PyPI, dan GitHub. Build harus di mesin berinternet (lihat [DEPLOYMENT](../DEPLOYMENT.md)).
- ⚠️ Image besar: core CPU 1,5 GB terkompresi / 4,7 GB di disk; GPU 3,9 GB / 11,4 GB.
- ⚠️ Model mewarisi lisensi upstream masing-masing (lihat NOTICE). Ketergantungan pada image Exadel perlu disimpan sebagai arsip (`scripts/push.sh --save`) agar tetap bisa di-build jika image upstream dihapus.
- ⚠️ Model tidak bisa diganti tanpa build ulang. Ini disengaja: mengganti model = migrasi embedding (lihat [MIGRATION](../MIGRATION.md)).
