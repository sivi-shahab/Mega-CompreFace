# ADR-005 — Varian core default (FaceNet CPU) vs produksi (ArcFace-r100 GPU)

| Metadata | |
|---|---|
| Judul | ADR-005 Varian core default vs produksi |
| Versi | 1.0.0 |
| Tanggal | 2026-09-29 |
| Owner | Tim Platform / DevOps |
| Status | Review — keputusan: **Accepted** |

| Versi | Tanggal | Penulis | Perubahan |
|---|---|---|---|
| 1.0.0 | 2026-09-29 | Claude Code | Versi awal |

## Context

- Instruksi proyek: default build core mengikuti image resmi 1.2.0 (FaceNet, CPU).
- DB produksi berisi embedding `insightface.Calculator@arcface-r100-msfdrop75` (SubCenter-ArcFace r100) dalam jumlah besar. Embedding antar-model **tidak kompatibel**.
- Host produksi memiliki GPU NVIDIA.

## Decision (disetujui user, 2026-09-29)

- `build-args.env` varian `[default]` = FaceNet CPU dengan tag `1.2.0`.
- Varian `[arcface-r100-gpu]` dengan tag `1.2.0-arcface-r100-gpu` dipakai di **overlays/prod** dan `docker-compose.gpu.yml`.
- `overlays/dev` memakai default (FaceNet CPU) dengan DB terpisah.
- Varian lain dari upstream (`arcface-r100` CPU, `facenet`, `mobilenet`, `mobilenet-gpu`) tersedia tetapi tidak dibangun secara default.
- Suffix varian mengikuti konvensi upstream. Secara SemVer suffix ini terbaca sebagai pre-release; hal ini diterima dan didokumentasikan.

## Consequences

- ✅ Embedding produksi tetap valid (dibuktikan dengan cosine similarity 0,999992 vs image resmi).
- ⚠️ Hasil uji di dev (FaceNet) tidak merepresentasikan akurasi prod (ArcFace). Uji akurasi harus memakai varian prod.
- ⚠️ Mengganti varian di environment berisi data adalah perubahan MAJOR dan memerlukan recalculation embedding (lihat [MIGRATION §8](../MIGRATION.md#8-perubahan-model-core-tidak-dalam-scope-cutover)).
