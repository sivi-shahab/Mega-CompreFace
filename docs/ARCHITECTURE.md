# Arsitektur CompreFace (mega)

| Metadata | |
|---|---|
| Judul | Arsitektur — komponen, alur data, alur data biometrik, dependency |
| Versi | 1.0.0 |
| Tanggal | 2026-09-29 |
| Owner | Tim Platform / DevOps |
| Status | Review |

| Versi | Tanggal | Penulis | Perubahan |
|---|---|---|---|
| 1.0.0 | 2026-09-29 | Claude Code | Versi awal, sesuai implementasi & verifikasi Fase 4 |

Referensi: [SPEC](../SPEC.md) §4 & §7, [ADR](adr/README.md), arsitektur upstream: [docs/upstream/Architecture-and-scalability.md](upstream/Architecture-and-scalability.md).

## 1. Diagram komponen (Kubernetes)

```
            Client / aplikasi internal bank            Browser admin
                         │  HTTPS (TLS di ingress)          │
                         ▼                                  ▼
               ┌──────────────────── Ingress Controller ─────────────────────┐
               └───────────────────────────────┬─────────────────────────────┘
 namespace compreface                          │ :80 → 8080 (NetworkPolicy: hanya dari ns ingress)
 (PodSecurity restricted,                      ▼
  NetworkPolicy default-deny)     ┌────────────────────────────┐
                                  │ compreface-fe (Deployment) │  nginx-unprivileged uid 101
                                  │ SPA Angular + reverse proxy│  resolver dinamis (ADR-004)
                                  └──────┬───────────────┬─────┘
                               /admin/** │               │ /api/v1/**
                                         ▼               ▼
              ┌──────────────────────────────┐  ┌──────────────────────────────┐
              │ compreface-admin (Deployment)│  │ compreface-api (Deployment)  │
              │ Spring Boot :8080, mgmt :8081│  │ Spring Boot :8080, mgmt :8081│
              │ user, app, collection, OAuth │  │ recognition/verification/    │
              │ Liquibase migration          │  │ detection, cache embedding   │
              └───────┬──────────────┬───────┘  └──────┬──────────────┬────────┘
                      │ JDBC :5432   │ HTTP :3000      │ HTTP :3000   │ JDBC :5432
                      │              └────────┐  ┌─────┘              │
                      │                       ▼  ▼                    │
                      │          ┌────────────────────────────────┐   │
                      │          │ compreface-core (Deployment)   │   │
                      │          │ Flask/uWSGI :3000, uid 33      │   │
                      │          │ model ML ter-bake, TANPA egress│   │
                      │          │ prod: 1 × nvidia.com/gpu       │   │
                      │          └────────────────────────────────┘   │
                      ▼                                               ▼
              ┌──────────────────────────────────────────────────────────┐
              │ compreface-postgres-db (StatefulSet, 1 replica) :5432    │
              │ PostgreSQL 11.5, uid 999, PVC (storage class terenkripsi) │
              └──────────────────────────────────────────────────────────┘
```

Semua Service bertipe **ClusterIP**. Hanya fe yang dapat dijangkau dari luar namespace (melalui ingress). Route `/core/` upstream **dihapus** ([ADR-004](adr/ADR-004-nginx-envsubst-resolver.md)).

## 2. Tanggung jawab service

| Service | Image | Tanggung jawab | State |
|---|---|---|---|
| compreface-fe | `mega/compreface-fe` | Menyajikan UI Angular. Reverse proxy `/admin/**` → admin dan `/api/v1/**` → api (+ swagger). Header CORS untuk `/api/v1` | Stateless |
| compreface-admin | `mega/compreface-admin` | Manajemen user, role, aplikasi, dan face collection (model + API key). OAuth2 (token opaque di DB, dikirim sebagai cookie `CFSESSION`). **Menjalankan migrasi skema Liquibase** saat start | Stateless (state di DB) |
| compreface-api | `mega/compreface-api` | REST API publik `/api/v1`: tambah/hapus wajah (subject, example), recognition, verification, detection. Memanggil core untuk deteksi dan embedding. Menyimpan embedding dan gambar ke DB. Cache embedding per collection di heap | Stateless (cache in-memory, rebuild dari DB) |
| compreface-core | `mega/compreface-core` | Deteksi wajah, perhitungan embedding (512 dimensi), plugin age/gender/mask/landmarks/pose. Tidak mengakses DB, tidak menyimpan data | Stateless |
| compreface-postgres-db | `mega/compreface-postgres-db` | Penyimpanan persisten: user, app, model, subject, embedding, img, token OAuth, statistik | **Stateful** (PVC) |

## 3. Alur data utama

### 3.1 Registrasi wajah (add example)
```
Client ──POST /api/v1/recognition/faces?subject=X (x-api-key, gambar)──▶ fe ──▶ api
api ──validasi api key (DB)──▶ postgres
api ──POST /find_faces (gambar)──▶ core ──▶ bbox + embedding[512]
api ──INSERT subject, embedding, img (bila SAVE_IMAGES_TO_DB=true)──▶ postgres
api ──▶ response {image_id, subject}
```

### 3.2 Recognition
```
Client ──POST /api/v1/recognition/recognize (gambar)──▶ fe ──▶ api
api ──POST /find_faces──▶ core ──▶ embedding wajah pada gambar
api ──bandingkan dengan embedding collection (cache heap; load dari DB bila belum ada)──▶ similarity
api ──▶ response {box, subjects:[{subject, similarity}]}
```
Gambar yang dikirim untuk recognition **tidak disimpan**. Yang disimpan hanya gambar pada operasi *add example*.

### 3.3 Administrasi
```
Browser ──/admin/oauth/token (Basic CommonClientId)──▶ fe ──▶ admin ──▶ Set-Cookie CFSESSION
Browser ──/admin/app, /admin/app/{id}/model (cookie)──▶ fe ──▶ admin ──▶ postgres
```

## 4. Alur data biometrik (UU PDP)

Klasifikasi: **Data Pribadi Spesifik — biometrik** (UU 27/2022 Pasal 4). Detail kontrol ada di [SECURITY.md](SECURITY.md).

| # | Data | Dari → Ke | Transport | Disimpan di | Retensi |
|---|---|---|---|---|---|
| B1 | Gambar wajah (upload) | Client → ingress → fe → api | HTTPS sampai ingress; **HTTP plain di dalam cluster** (gap) | – | – |
| B2 | Gambar wajah | api → core | HTTP plain in-cluster | Tidak disimpan (diproses di memori core) | – |
| B3 | Embedding (vektor 512) | core → api | HTTP plain in-cluster | tabel `embedding` | Sampai subject/example dihapus |
| B4 | Gambar wajah (add example) | api → postgres | JDBC tanpa TLS in-cluster (gap) | tabel `img` (bytea) bila `SAVE_IMAGES_TO_DB=true` | Sampai example dihapus |
| B5 | Identitas subject (nama/ID) | api → postgres | JDBC | tabel `subject` | Sampai dihapus |
| B6 | Embedding cache | postgres → api | JDBC | heap JVM api | Selama pod hidup |
| B7 | Metadata log | semua → stdout | – | platform logging cluster | Mengikuti kebijakan logging |

Catatan: core tidak memiliki egress, telemetry Appery dinonaktifkan, dan request log uWSGI dimatikan. Log akses nginx memakai `$uri` (tanpa query string).

## 5. Dependency & urutan startup

```
compreface-postgres-db
   ├──▶ compreface-admin   (Liquibase: membuat/migrasi skema — WAJIB sukses sebelum api dipakai pada DB kosong)
   └──▶ compreface-api ──▶ compreface-core
compreface-fe  ─ ─ ▶ admin, api   (soft dependency: fe start duluan, 502 sampai backend Ready)
```

| Mekanisme | Compose | Kubernetes |
|---|---|---|
| Urutan | `depends_on: condition: service_healthy` (db → admin → api; core → api). fe tanpa `depends_on` | Tidak ada hard ordering. Readiness menahan traffic, Hikari/Feign retry. Apply awal: db → admin → sisanya ([DEPLOYMENT](DEPLOYMENT.md)) |
| Health | `HEALTHCHECK` di image | startupProbe / readinessProbe / livenessProbe |

| Service | Startup (terukur Fase 4) | Probe |
|---|---|---|
| postgres-db | ≈ 5–10 s | `pg_isready` |
| admin | ≈ 30–40 s | `:8081/actuator/health/{liveness,readiness}`, startup budget 300 s |
| api | ≈ 15–20 s | idem |
| core CPU / GPU | 48 s / 25 s sampai inferensi pertama | startupProbe exec `/find_faces` sample image (budget 600 s), lalu `/healthcheck` |
| fe | < 5 s | `/healthz` |

## 6. Skalabilitas

- fe, admin, api, dan core **stateless**, sehingga bisa di-scale horizontal (prod: fe/admin/api 2 replica).
- Throughput core bergantung pada `UWSGI_PROCESSES` × replica. Varian GPU: 1 GPU per replica ([CONFIGURATION §7](CONFIGURATION.md#7-sizing-core-uwsgi_processes-vs-resource)). HPA contoh ada di `k8s/overlays/prod/hpa-core.yaml`.
- api menyimpan cache embedding per collection di heap. Setiap replica memuat cache sendiri, jadi memori api naik seiring jumlah embedding (prod: limit 6Gi).
- postgres single instance = SPOF (risiko R-08). HA/replikasi di luar scope.

## 7. Artefak build & deploy

```
repo root
├── java/ ui/ embedding-calculator/ db/   ← source upstream (tidak diubah)
├── services/<svc>/Dockerfile             ← build unit (context = root)   ── scripts/build.sh ──▶ mega/compreface-<svc>:<ver>
├── k8s/base + overlays/{dev,prod}        ← deploy unit Kubernetes         ── kubectl apply -k
└── docker-compose.yml (+ .gpu.yml)       ← deploy unit lokal/verifikasi
```
