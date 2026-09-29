# ADR-003 — Kustomize base/overlays

| Metadata | |
|---|---|
| Judul | ADR-003 Kustomize base/overlays |
| Versi | 1.0.0 |
| Tanggal | 2026-09-29 |
| Owner | Tim Platform / DevOps |
| Status | Review — keputusan: **Accepted** |

| Versi | Tanggal | Penulis | Perubahan |
|---|---|---|---|
| 1.0.0 | 2026-09-29 | Claude Code | Versi awal |

## Context

Diperlukan manifest Kubernetes untuk dev dan prod dengan perbedaan berikut:
- registry dan tag image, termasuk varian core (FaceNet CPU vs ArcFace GPU);
- replicas, resources, GPU, dan PDB;
- storage class terenkripsi dan namespace.

Pilihan yang ada: Helm chart, kustomize, atau manifest mentah per environment. Lingkungan air-gapped dan tim operasional lebih mudah mengaudit YAML polos. `kubectl` sudah menyertakan kustomize (`kubectl apply -k`) tanpa tooling tambahan.

## Decision

- `k8s/base/`: satu subdirektori per service, masing-masing berisi Deployment/StatefulSet, Service, NetworkPolicy, dan `configmap.env`. `configmap.env` dipakai oleh `configMapGenerator`, yang menambahkan hash suffix sehingga perubahan konfigurasi otomatis memicu rolling update. Di level base juga ada NetworkPolicy default-deny + DNS, serta `secret.example.yaml` yang tidak dimasukkan ke `resources`.
- `k8s/overlays/dev` dan `k8s/overlays/prod`: namespace (dengan label Pod Security `restricted`), `images` (registry/tag), `replicas`, `configMapGenerator` `behavior: merge`, dan patch strategic-merge (resource core GPU, resource api, storage postgres). Prod juga berisi PDB, HPA contoh (non-aktif), dan Ingress contoh (non-aktif).
- Secret **tidak** dikelola kustomize/git, melainkan dibuat di luar repo (lihat [DEPLOYMENT](../DEPLOYMENT.md)).

## Consequences

- ✅ Tanpa templating: output bisa dirender dan di-review (`kubectl kustomize`) dan divalidasi `kubeconform -strict` (dev 24, prod 28 resource valid).
- ✅ Perubahan per environment terlihat eksplisit di overlay.
- ⚠️ Nilai spesifik cluster (host registry, storage class, namespace ingress controller) masih placeholder (`registry.example.internal`, `encrypted-block`, `ingress-nginx`) dan wajib diganti sebelum deploy.
- ⚠️ Kustomize tidak mengenkripsi Secret. Integrasi dengan Vault/Sealed Secrets/External Secrets diputuskan terpisah.
