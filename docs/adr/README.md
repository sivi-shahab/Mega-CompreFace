# Indeks ADR

| Metadata | |
|---|---|
| Judul | Indeks Architecture Decision Records |
| Versi | 1.0.0 |
| Tanggal | 2026-09-29 |
| Owner | Tim Platform / DevOps |
| Status | Review |

| Versi | Tanggal | Penulis | Perubahan |
|---|---|---|---|
| 1.0.0 | 2026-09-29 | Claude Code | Versi awal |


Format: Context → Decision → Consequences. ADR tidak diedit setelah Accepted; perubahan keputusan dicatat di ADR baru yang me-*supersede* ADR lama.

| ADR | Judul | Status |
|---|---|---|
| [ADR-001](ADR-001-build-deploy-unit-terpisah.md) | Pemisahan build & deploy unit tanpa memindahkan source | Accepted |
| [ADR-002](ADR-002-model-ml-baked-air-gapped.md) | Model ML di-bake ke image core untuk air-gapped | Accepted |
| [ADR-003](ADR-003-kustomize-base-overlays.md) | Kustomize base/overlays | Accepted |
| [ADR-004](ADR-004-nginx-envsubst-resolver.md) | envsubst + resolver di nginx FE | Accepted |
| [ADR-005](ADR-005-varian-core.md) | Varian core default (FaceNet CPU) vs produksi (ArcFace-r100 GPU) | Accepted |
