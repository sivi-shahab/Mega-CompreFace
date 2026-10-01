# SPEC — Pemisahan Build & Deploy Unit CompreFace untuk Kubernetes

| Metadata | |
|---|---|
| Judul | Spesifikasi Pemisahan Service CompreFace (build, versioning, deploy Kubernetes) |
| Versi dokumen | 0.2.0 |
| Tanggal | 2026-09-29 |
| Owner | Tim Platform / DevOps |
| Status | v0.1.0 **Approved** (2026-09-29); v0.2.0 **Review** — sinkronisasi dengan hasil implementasi & verifikasi (§13) |
| Basis kode | `exadel-inc/CompreFace` commit `ddf32da82` (release 1.2.0) |

| Versi | Tanggal | Penulis | Perubahan |
|---|---|---|---|
| 0.1.0 | 2026-09-29 | Claude Code (draft) | Draft awal berdasarkan hasil Discovery Fase 1 |
| 0.2.0 | 2026-09-29 | Claude Code | Tambah §13 (deviasi & temuan implementasi), R-12, koreksi A-05/A-06, lokasi dokumen upstream |

---

## 1. Latar Belakang

CompreFace adalah sistem face recognition open-source (Apache 2.0) yang terdiri dari 5 service. Di lingkungan bank ini, CompreFace saat ini berjalan dengan `docker compose` di satu host GPU, memakai image publik `exadel/*:1.2.0` dan varian core `1.2.0-arcface-r100-gpu`. Detail host dan kondisi sistem berjalan dicatat di **catatan internal** (tidak dipublikasikan).

Temuan Discovery yang melatarbelakangi pekerjaan ini:

1. **compreface-core tidak berjalan.** Image `exadel/compreface-core:1.2.0-arcface-r100-gpu` tidak tersedia di host, sehingga container tidak pernah dibuat. `compreface-api` gagal memanggil `http://compreface-core:3000/status` (error code 41).
2. **compreface-ui restart terus-menerus.** nginx me-resolve blok `upstream` secara statis saat start. Hostname `compreface-core` tidak ada di DNS, sehingga muncul `[emerg] host not found in upstream "compreface-core:3000"` dan container exit (restart policy `always`).
3. Hostname antar-service di-hardcode (`nginx.conf.template`, default `application.yml`). Build Java untuk admin dan api digabung dalam satu Dockerfile multi-target di `dev/`. Tidak ada artefak Kubernetes.
4. Model ML core di-download dari Google Drive saat build. Ini aman untuk air-gapped hanya jika image di-build di mesin berinternet lalu ditransfer.
5. Beberapa masalah keamanan dari upstream:
   - Endpoint core diekspos publik lewat route `/core/` di nginx tanpa autentikasi.
   - `APPERY_API_KEY` (telemetry ke `api.appery.io`) ter-bake di image admin.
   - Container Java berjalan sebagai root.
   - Kredensial default upstream untuk database.
   - Healthcheck admin `DOWN` karena `MailHealthIndicator`.
6. Database produksi berisi data biometrik (gambar wajah dan embedding) dalam jumlah besar yang dihasilkan model `insightface.Calculator@arcface-r100-msfdrop75`. Embedding ini tidak kompatibel dengan model lain, sehingga varian core produksi harus tetap memakai model yang sama. Jumlah record dicatat di catatan internal.

## 2. Tujuan

- **G-1** Setiap service bisa di-build, di-versioning, dan di-deploy secara independen.
- **G-2** Deployment ke Kubernetes on-prem/air-gapped memakai image dari private registry dengan namespace `mega`.
- **G-3** Masalah core yang tidak jalan dan UI yang restart terselesaikan secara struktural, bukan workaround.
- **G-4** Dokumentasi SDLC lengkap (arsitektur, konfigurasi, deployment, migrasi, runbook, security, test plan, ADR).
- **G-5** Postur keamanan dan kepatuhan yang sesuai untuk pemrosesan data biometrik (UU PDP No. 27/2022, ketentuan OJK). Gap yang tersisa didokumentasikan secara eksplisit.

## 3. Scope & Out-of-Scope

### 3.1 In-scope
- Dockerfile per service di `services/<service>/`, multi-stage, base image di-pin, non-root bila memungkinkan, tanpa secret.
- Build context boleh merujuk root repo. **Source code tidak dipindahkan** (`java/`, `ui/`, `embedding-calculator/` tetap).
- `scripts/build.sh` dan `scripts/push.sh`.
- `build-args.env` untuk varian core: default FaceNet CPU `1.2.0`, dan varian prod `1.2.0-arcface-r100-gpu`.
- nginx FE: `nginx.conf.template` dengan envsubst + `resolver` + upstream dari env var; route `/core/` dihapus.
- Manifest Kubernetes: `k8s/base` + `k8s/overlays/{dev,prod}` (kustomize). Isinya Deployment/StatefulSet, Service, ConfigMap, `secret.example.yaml`, NetworkPolicy, startupProbe, readinessProbe, livenessProbe, resource patch core, dan contoh HPA.
- `docker-compose.yml` baru di root memakai image `mega/*` untuk verifikasi lokal.
- Hardening berbasis konfigurasi (tanpa mengubah kode aplikasi):
  - Telemetry Appery nonaktif.
  - Mail health indicator nonaktif.
  - `security.signing-key` di-externalize ke Secret.
- Dokumen SDLC (lihat §11) dan file `NOTICE` untuk atribusi.

### 3.2 Out-of-scope
- Perubahan logika bisnis Java/Python/Angular dan upgrade framework (Spring Boot 2.5, Angular 11, Python 3.8, TF 2.2, Postgres 11). Semuanya dicatat sebagai risiko.
- Eksekusi cutover produksi (compose → Kubernetes). Hanya rencananya yang ditulis di MIGRATION.md.
- Mengubah sistem compose yang sedang berjalan. Verifikasi Fase 4 berjalan terisolasi.
- Pembuatan cluster Kubernetes, ingress controller, NVIDIA device plugin, storage class terenkripsi, service mesh / mTLS, dan pipeline CI/CD. Semuanya menjadi prasyarat atau gap.
- Enkripsi kolom (pgcrypto) untuk `img` / `embedding`, karena membutuhkan perubahan kode. Dicatat sebagai gap.
- Rotasi OAuth client `CommonClientId:password`. Nilainya di-compile ke bundle SPA (`environment.prod.ts`), jadi merupakan public client credential. Rotasi butuh perubahan source FE dan dicatat sebagai gap.
- DPIA formal (Pasal 34 UU PDP), yang menjadi tanggung jawab DPO/Compliance.

## 4. Kondisi As-Is vs To-Be

### 4.1 As-is (docker compose, host tunggal)

```
                 port UI                       port api
   Browser ───────────────► compreface-ui     Client/Integrasi ─────────────┐
                            (nginx, root,                                   │
                             upstream statis ── CRASH: core tidak resolve)  │
                              │ /admin/  │ /api/v1/  │ /core/ (publik!)     │
                              ▼          ▼           ▼                      ▼
                      compreface-admin  compreface-api ◄────────────────────┘
                      (root, Appery key) (root)
                              │    └──────┬───── PYTHON_URL=http://compreface-core:3000
                              │           ▼
                              │      compreface-core  ✗ TIDAK ADA (image tidak ada di host)
                              ▼
                      compreface-postgres-db (postgres:11.5, kredensial default, volume lokal)
```

### 4.2 To-be (Kubernetes, namespace mis. `compreface`)

```
                      Ingress Controller (TLS termination, di luar scope)
                              │  hanya ke fe:8080
                              ▼
   ┌──────────────────── NetworkPolicy: default-deny ingress+egress ────────────────────┐
   │                                                                                     │
   │   Deployment compreface-fe (nginx-unprivileged, non-root, :8080)                    │
   │     resolver <kube-dns> + proxy_pass $variable → tidak crash bila upstream belum ada │
   │        │ /admin/ → ADMIN_UPSTREAM          │ /api/v1/ → API_UPSTREAM                │
   │        ▼                                    ▼                                        │
   │   Deployment compreface-admin (:8080)   Deployment compreface-api (:8080)           │
   │   non-root, mgmt :8081                  non-root, mgmt :8081                        │
   │        │                                 │           │ PYTHON_URL (ConfigMap)       │
   │        │                                 │           ▼                              │
   │        │                                 │   Deployment compreface-core (:3000)     │
   │        │                                 │   stateless, replicas ≥1, model baked,   │
   │        │                                 │   egress: NONE, (prod: nvidia.com/gpu:1) │
   │        ▼                                 ▼                                          │
   │   StatefulSet compreface-postgres-db (:5432) + PVC (storage class terenkripsi*)      │
   └─────────────────────────────────────────────────────────────────────────────────────┘
   Image: ${REGISTRY}/mega/compreface-<service>:<version>   (* prasyarat infrastruktur)
```

## 5. Functional Requirements

| ID | Requirement |
|---|---|
| FR-01 | Setiap service (fe, admin, api, core, postgres-db) memiliki Dockerfile sendiri di `services/<service>/Dockerfile` dan dapat di-build tanpa mem-build service lain. |
| FR-02 | `scripts/build.sh` mem-build satu, beberapa, atau semua service (dan varian core) dengan parameter `REGISTRY`, versi per service, dan varian. `scripts/push.sh` mem-push image yang sudah di-build. Kedua script menolak tag `latest`. |
| FR-03 | Nama image mengikuti `${REGISTRY}/mega/compreface-<service>:<version>`. Setiap image diberi label OCI (`org.opencontainers.image.version`, `.revision` = git SHA, `.source`, `.licenses=Apache-2.0`). |
| FR-04 | Pilihan plugin/model dan varian CPU/GPU core didefinisikan sebagai build args di `services/compreface-core/build-args.env`. Default = image resmi 1.2.0 (FaceNet, CPU) dengan tag `1.2.0`. Varian `arcface-r100-gpu` dengan tag `1.2.0-arcface-r100-gpu` (sama dengan model data produksi). |
| FR-05 | Semua model ML dan dependency pip plugin di-bake ke image core saat build. Saat runtime core tidak melakukan koneksi keluar apa pun. |
| FR-06 | Semua hostname/URL antar-service berasal dari env var: `ADMIN_UPSTREAM`, `API_UPSTREAM`, `CORE_UPSTREAM` (fe), `PYTHON_URL` (admin, api), `POSTGRES_URL` (admin, api). Tidak ada hostname hardcoded di image yang tidak bisa di-override. |
| FR-07 | FE nginx memakai `nginx.conf.template` (envsubst) dan direktif `resolver` (otomatis dari `/etc/resolv.conf` atau env `NGINX_RESOLVER`) dengan `proxy_pass` berbasis variabel. nginx tetap start dan melayani static UI walaupun admin/api belum siap (mengembalikan 502, tidak crash). |
| FR-08 | Route `/core/` dihapus dari FE. Core hanya bisa diakses dari api/admin di dalam cluster, **kecuali** `GET /core/status` (exact match, read-only) yang wajib ada karena UI menahan halaman sampai status core `OK` dan membaca `available_plugins` darinya (revisi 2026-10-01). |
| FR-09 | `k8s/base` berisi, per service, Deployment (fe, admin, api, core) atau StatefulSet + PVC (postgres), Service ClusterIP, ConfigMap, dan NetworkPolicy. Credential diambil dari Secret; tersedia `secret.example.yaml` tanpa nilai asli. |
| FR-10 | Setiap workload memiliki probe sesuai endpoint: fe `GET /` (atau `/healthz`); admin & api `GET /actuator/health/{liveness,readiness}` di management port; core `startupProbe` toleransi panjang, lalu `readiness`/`liveness` `GET /healthcheck`; postgres `pg_isready`. |
| FR-11 | `k8s/overlays/dev` dan `k8s/overlays/prod` (kustomize) mengatur image tag, replicas, resources, dan varian core. Prod memiliki patch resource core terpisah (terbesar), `UWSGI_PROCESSES` selaras dengan CPU/GPU limit, dan contoh HPA core (dikomentari/opsional). |
| FR-12 | `compreface-api` mengakses core lewat Service ClusterIP dengan URL dari ConfigMap (`PYTHON_URL`). |
| FR-13 | Telemetry Appery dinonaktifkan: `APPERY_API_KEY` tidak di-bake ke image dan tidak di-set di manifest; egress internet diblok NetworkPolicy. |
| FR-14 | Healthcheck admin tidak bergantung ke SMTP (`MANAGEMENT_HEALTH_MAIL_ENABLED=false`). |
| FR-15 | `security.signing-key` admin di-set dari Secret lewat env `SECURITY_SIGNINGKEY`. Nilai default di image tidak dipakai. |
| FR-16 | `docker-compose.yml` di root menjalankan kelima image `mega/*` dengan konfigurasi setara manifest (env var, healthcheck, urutan startup), untuk verifikasi lokal. |
| FR-17 | Tersedia prosedur migrasi data Postgres dari compose ke StatefulSet (backup, restore, validasi jumlah record per tabel) di `docs/MIGRATION.md`. |
| FR-18 | `LICENSE` Apache 2.0 dan atribusi upstream (header copyright) dipertahankan. Ditambahkan `NOTICE` yang mengatribusikan Exadel/CompreFace (upstream tidak memiliki NOTICE). |
| FR-19 | Dokumentasi SDLC sesuai §11, konsisten dengan SPEC ini dan hasil implementasi aktual. |

## 6. Non-Functional Requirements

| ID | Kategori | Requirement |
|---|---|---|
| NFR-01 | Availability | fe, admin, api, dan core dapat dijalankan dengan ≥2 replica di prod (stateless). Rolling update `maxUnavailable: 0`. `PodDisruptionBudget` `minAvailable: 1` untuk fe, api, dan core. Postgres single-instance (HA di luar scope, dicatat sebagai risiko). |
| NFR-02 | Resiliensi startup | Tidak ada service yang crash karena dependency belum siap. fe tetap Running tanpa admin/api/core. Urutan startup tidak wajib di Kubernetes (dijamin probe + retry). |
| NFR-03 | Performa – startup core | Core Ready ≤ 180 s pada hardware target (diukur di Fase 4). `startupProbe` memberi toleransi hingga 600 s. |
| NFR-04 | Performa – latensi | Recognition 1 wajah, gambar ≤ 640 px, p95 ≤ 1,5 s (GPU, varian arcface-r100-gpu) dan ≤ 3 s (CPU, FaceNet), diukur end-to-end di api setelah warm-up. Angka ini adalah **target awal** yang akan dikalibrasi dengan hasil Fase 4. |
| NFR-05 | Skalabilitas | Core stateless dan dapat di-scale horizontal (manual atau HPA). Untuk varian GPU, jumlah replica dibatasi jumlah GPU yang tersedia. `UWSGI_PROCESSES` dikonfigurasi lewat ConfigMap dan diselaraskan dengan CPU limit (CPU) atau VRAM (GPU, ≈2,5 GB per proses InsightFace). |
| NFR-06 | Keamanan – image | Base image di-pin versi. fe, admin, api, dan core berjalan non-root (`runAsNonRoot`, `allowPrivilegeEscalation: false`, drop ALL capabilities). Tidak ada secret di layer image (diverifikasi dengan `docker history`/`inspect`). |
| NFR-07 | Keamanan – jaringan | NetworkPolicy default-deny (ingress & egress). Hanya alur ini yang diizinkan: ingress-controller→fe, fe→admin, fe→api, api→core, admin→core, admin→db, api→db, dan DNS egress. Core tanpa egress lain. |
| NFR-08 | Keamanan – secret | Credential (DB, SMTP, signing key) hanya ada di Secret Kubernetes / `.env` lokal yang tidak di-commit. Repo hanya berisi `secret.example.yaml` dan `.env.example`. |
| NFR-09 | Air-gapped | Runtime seluruh service tidak memerlukan akses internet. Build dilakukan di mesin berinternet, lalu image ditransfer (`docker save/load` atau `skopeo copy`) ke registry internal. Core lulus uji `docker run --network none` + healthcheck. |
| NFR-10 | Observability | Log ke stdout/stderr (dikumpulkan oleh platform logging cluster). Level log dari ConfigMap; prod tidak memakai DEBUG, karena log DEBUG api saat ini mencatat request dan berisiko memuat data pribadi. Health endpoint tersedia untuk monitoring. Metrics Prometheus berada di luar scope (gap). |
| NFR-11 | Kepatuhan UU PDP / OJK | Data wajah dan embedding diklasifikasikan sebagai **Data Pribadi Spesifik – biometrik** (UU 27/2022 Pasal 4). Wajib: enkripsi in-transit di titik masuk (TLS di ingress), enkripsi at-rest (PVC di storage class terenkripsi, prasyarat infra), akses minimum (NetworkPolicy, RBAC, Secret), prosedur retensi & penghapusan, dan audit log akses (gap parsial). Data dan pemrosesan tetap on-prem di Indonesia sesuai ketentuan OJK tentang penyelenggaraan TI bank umum (mis. POJK 11/POJK.03/2022). Tidak ada transfer data ke pihak ketiga (telemetry nonaktif). Validasi final oleh tim Compliance/DPO. |
| NFR-12 | Reproducibility | Build deterministik semaksimal mungkin: versi dependency di-pin, image diberi label git SHA, digest base image dicatat di CHANGELOG/DEPLOYMENT. Keterbatasan: `ui/` tidak memiliki `package-lock.json` (risiko R-05). |
| NFR-13 | Maintainability | Satu sumber kebenaran untuk konfigurasi: ConfigMap/Secret di k8s dan `.env` di compose, dengan nama variabel yang sama dan terdokumentasi di CONFIGURATION.md. |

## 7. Kontrak Antar-Service

### 7.1 Port, endpoint, healthcheck

| Service | Container port | Service (ClusterIP) | Health endpoint | User runtime |
|---|---|---|---|---|
| compreface-fe | 8080 (HTTP; sebelumnya 80) | `compreface-fe:80 → 8080` | `GET /` (static) | nginx uid 101 |
| compreface-admin | 8080 app, 8081 management | `compreface-admin:8080` | `GET :8081/actuator/health/liveness`, `/readiness` | non-root (uid 1001) |
| compreface-api | 8080 app, 8081 management | `compreface-api:8080` | `GET :8081/actuator/health/liveness`, `/readiness` | non-root (uid 1001) |
| compreface-core | 3000 | `compreface-core:3000` | `GET /healthcheck` (liveness/readiness); `GET /status` (info model) | `www-data` (uid 33) |
| compreface-postgres-db | 5432 | `compreface-postgres-db:5432` (headless + ClusterIP) | `pg_isready -U $POSTGRES_USER` | postgres (uid 999) |

Catatan: management port 8081 dipilih karena `/actuator/**` di api diblokir oleh filter `x-api-key` di port 8080. **Terverifikasi (Fase 3):** admin & api `UP` di 8081, `/actuator` di 8080 api tetap 400 — fallback tidak diperlukan.

### 7.2 Endpoint publik (via fe)

| Path | Tujuan |
|---|---|
| `/` | Angular SPA |
| `/admin/**` | admin |
| `/api/v1/**` | api (autentikasi `x-api-key`) |
| `/core/status` | core `GET /status` saja (exact match; method lain 403) |
| `/core/**` lainnya | **dihapus** |

### 7.3 Env var antar-service (ringkas; detail di CONFIGURATION.md)

| Konsumen | Env var | Default to-be | Sumber |
|---|---|---|---|
| fe | `ADMIN_UPSTREAM` | `compreface-admin:8080` (k8s: FQDN `compreface-admin.<ns>.svc.cluster.local:8080`) | ConfigMap |
| fe | `API_UPSTREAM` | `compreface-api:8080` (k8s: FQDN) | ConfigMap |
| fe | `CORE_UPSTREAM` | `compreface-core:3000` (k8s: FQDN) — hanya untuk `GET /core/status` | ConfigMap |
| fe | `NGINX_RESOLVER` | otomatis dari `/etc/resolv.conf` | ConfigMap (opsional) |
| fe | `CLIENT_MAX_BODY_SIZE`, `PROXY_READ_TIMEOUT`, `PROXY_CONNECT_TIMEOUT` | `10M`, `60000ms`, `10000ms` | ConfigMap |
| admin, api | `POSTGRES_URL` | `jdbc:postgresql://compreface-postgres-db:5432/frs` | ConfigMap |
| admin, api | `POSTGRES_USER`, `POSTGRES_PASSWORD` | – | **Secret** |
| admin, api | `PYTHON_URL` | `http://compreface-core:3000` | ConfigMap |
| api | `CONNECTION_TIMEOUT`, `READ_TIMEOUT`, `MAX_ATTEMPTS` | `10000`, `60000`, `1` | ConfigMap |
| admin | `EMAIL_USERNAME`, `EMAIL_PASSWORD`, `SECURITY_SIGNINGKEY` | – | **Secret** |
| core | `UWSGI_PROCESSES`, `UWSGI_THREADS`, `IMG_LENGTH_LIMIT` | `2`, `1`, `640` | ConfigMap |

(FQDN diperlukan di fe karena resolver nginx tidak memakai `search` domain dari resolv.conf.)

### 7.4 Dependency & urutan startup

```
postgres-db ──► admin (Liquibase migration, harus jalan lebih dulu sebelum api dipakai)
            └─► api ──► core
fe ──► admin, api   (soft dependency; fe tidak menunggu)
```

- **Compose:** `depends_on` dengan `condition: service_healthy` (db → admin → api; core → api).
- **Kubernetes:** tidak ada hard ordering. admin/api melakukan retry koneksi DB (Hikari), dan readiness menahan traffic sampai siap. Core tidak memiliki dependency. Satu-satunya urutan yang penting adalah **admin harus sukses menjalankan Liquibase** sebelum api menerima traffic untuk DB kosong. Urutan ini dijelaskan di DEPLOYMENT.md (apply db → admin → sisanya), dan pada DB existing tidak kritikal.

## 8. Strategi Build, Versioning & Tagging

- **Build unit:** `services/<svc>/Dockerfile` dengan context:

  | Service | Build context |
  |---|---|
  | fe | `ui/` |
  | admin, api | `java/` (modul `common` ikut di-build) |
  | core | `embedding-calculator/` |
  | postgres-db | `db/` |

- **Versioning:** SemVer per service dan independen.
  - Rilis awal semua service = `1.2.0`, mengikuti upstream 1.2.0 dan sesuai contoh `mega/compreface-core:1.2.0`.
  - Perubahan berikutnya dinaikkan per service:
    - PATCH: perbaikan konfigurasi atau Dockerfile.
    - MINOR: fitur yang kompatibel.
    - MAJOR: perubahan kontrak API atau skema DB, atau model core yang tidak kompatibel dengan embedding existing.
- **Varian core:** suffix `-<model>[-gpu]`, misalnya `1.2.0-arcface-r100-gpu`, mengikuti konvensi upstream. Catatan: secara SemVer, suffix ini terbaca sebagai pre-release. Hal ini diterima sebagai konvensi varian dan didokumentasikan di ADR.
  - ⚠️ Mengganti model core = MAJOR secara fungsional, karena embedding lama tidak kompatibel dan harus di-recalculate.
- **Tag:** immutable, tanpa `latest`. Git SHA dicatat di label OCI `org.opencontainers.image.revision`. Deploy prod disarankan memakai digest (`@sha256:`) yang dicatat saat push.
- **Registry:** `${REGISTRY}/mega/...` (contoh `registry.bankmega.local/mega/compreface-api:1.2.0`). Untuk build lokal, `REGISTRY` boleh kosong sehingga menjadi `mega/compreface-api:1.2.0`.
- **Base image (di-pin):**

  | Service | Base image |
  |---|---|
  | fe | `node:12.22.12` (build) + `nginxinc/nginx-unprivileged:1.21.1` |
  | admin, api | `maven:3.8.2-eclipse-temurin-17` (build) + `eclipse-temurin:17.0.8_7-jre-focal` |
  | core | `python:3.8-slim-bullseye` (CPU) / `nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu20.04` (GPU) |
  | db | `postgres:11.5` (versi major sama dengan data produksi) |

  Versi final dicatat di CHANGELOG.

## 9. Asumsi & Constraint

| ID | Asumsi / Constraint |
|---|---|
| A-01 | Build dilakukan di mesin berinternet (host ini). Target deploy (cluster k8s) air-gapped dan hanya bisa pull dari registry internal. |
| A-02 | Cluster k8s menyediakan: CNI yang mendukung NetworkPolicy, StorageClass (idealnya terenkripsi at-rest), ingress controller dengan TLS, dan (prod) NVIDIA device plugin + node GPU. |
| A-03 | Model default build (`build-args.env`) adalah FaceNet CPU. Overlay prod memakai `1.2.0-arcface-r100-gpu` agar kompatibel dengan embedding produksi yang sudah ada. Overlay dev memakai FaceNet CPU dengan DB terpisah. |
| A-04 | Verifikasi Fase 4 memakai compose project, nama container, port (mis. 18000), dan volume yang terpisah dari sistem berjalan. |
| A-05 | Mesin build harus punya ruang disk cukup di storage Docker (≥ 40 GB, lihat DEPLOYMENT §1.1). Catatan Fase 4: dengan containerd snapshotter, lokasi data Docker bisa berbeda dari `Docker Root Dir` yang ditampilkan `docker info` — cek partisi sebenarnya. |
| A-06 | `kubectl`/`kustomize`/`kubeconform` tidak terpasang dan **tidak ada cluster**; validasi Fase 4 memakai binary standalone (kubectl 1.30.4, kustomize 5.4.3, kubeconform 0.6.7) secara statis. Uji di cluster nyata = TC-36 (Not Run). |
| C-01 | Tidak boleh mengubah source code aplikasi. Semua perubahan dilakukan lewat Dockerfile, konfigurasi, env var, dan manifest. |
| C-02 | Upstream tidak memiliki file NOTICE. NOTICE baru dibuat untuk atribusi tanpa mengubah LICENSE. |

## 10. Risiko & Mitigasi

| ID | Risiko | Dampak | Mitigasi |
|---|---|---|---|
| R-01 | Salah varian core di prod (FaceNet vs ArcFace) sehingga semua recognition gagal atau similarity salah | Tinggi | Tag varian eksplisit di overlay prod. Test case membandingkan `GET /status` core dengan kolom `embedding.calculator`. Ceklist go/no-go di MIGRATION.md. |
| R-02 | Google Drive (sumber model) rate-limit atau file dihapus saat build | Tinggi | Build di mesin berinternet; simpan image hasil build di registry internal + `docker save` sebagai arsip. Dokumentasikan ID file model. Opsi mirror model internal (future). |
| R-03 | Dependency EOL (Python 3.8, TF 2.2, Postgres 11, Spring Boot 2.5, Node 12, Angular 11) membawa CVE | Sedang–Tinggi | Dicatat di SECURITY.md sebagai gap. Scan image (Trivy) direkomendasikan. Upgrade adalah proyek terpisah. |
| R-04 | Multi-stage / non-root core memutus dependency native (opencv, imagecodecs, mxnet CUDA) | Sedang | Test build + pytest (CPU) + uji e2e Fase 4. Fallback: single-stage yang sudah dibersihkan, dengan alasan tercatat di ADR. |
| R-05 | `ui/` tanpa `package-lock.json` sehingga build FE tidak reproducible dan bisa gagal karena versi transitive | Sedang | Pin versi Node. Build diverifikasi dan artefak image disimpan. Rekomendasi: commit lockfile (future). |
| R-06 | Disk host penuh saat build | Sedang | Prasyarat A-05; build per service. |
| R-07 | Resolver nginx di k8s tidak memakai search domain sehingga 502 | Sedang | Upstream FQDN di ConfigMap overlay; test case khusus. |
| R-08 | Postgres single-instance (SPOF) dan kehilangan data saat migrasi | Tinggi | Backup `pg_dump` sebelum cutover, validasi jumlah record per tabel, rollback plan (compose tetap utuh). HA/backup terjadwal direkomendasikan di RUNBOOK. |
| R-09 | Log DEBUG api (konfigurasi compose lama) mencatat request yang berisi data pribadi | Sedang | Level INFO di prod lewat ConfigMap. Dicatat di SECURITY.md. |
| R-10 | OAuth client secret SPA publik (`CommonClientId:password`) dan tidak adanya TLS internal | Sedang | Gap di SECURITY.md; TLS di ingress; rekomendasi service mesh/mTLS. |
| R-11 | GPU tidak cukup untuk replica core sehingga pod Pending | Sedang | HPA `maxReplicas` ≤ jumlah GPU; dokumentasi scaling di RUNBOOK. |
| R-12 | **(baru, Fase 5)** Penghapusan subject via API upstream meninggalkan gambar wajah di tabel `img` (hak penghapusan UU PDP tidak terpenuhi) | Tinggi | `scripts/db-purge-orphan-images.sql` setelah penghapusan & terjadwal (RUNBOOK §5.5); perbaikan kode upstream (SECURITY S-13). |

## 11. Deliverable Dokumentasi

`README.md`, `CHANGELOG.md`, `CONTRIBUTING.md` (ditulis ulang untuk konteks internal; CLA/CoC upstream dipertahankan), `NOTICE`, `.env.example`, `services/*/README.md`, `docs/ARCHITECTURE.md`, `docs/CONFIGURATION.md`, `docs/DEPLOYMENT.md`, `docs/MIGRATION.md`, `docs/RUNBOOK.md`, `docs/SECURITY.md`, `docs/TEST_PLAN.md`, dan `docs/adr/ADR-001..004` (+ ADR-005 varian core dan model default).

Catatan: dokumentasi upstream dipindah (`git mv`, isi tidak diubah selain link relatif) ke `docs/upstream/` — termasuk README & CONTRIBUTING asli — karena `docs/Configuration.md` bentrok dengan `docs/CONFIGURATION.md` di filesystem case-insensitive. Lihat §13 D-06.

## 12. Acceptance Criteria

| Req | Acceptance criteria (terukur) |
|---|---|
| FR-01 | `docker build -f services/<svc>/Dockerfile <context>` sukses untuk kelima service secara terpisah (exit 0). |
| FR-02 | `scripts/build.sh all` menghasilkan 5 image + varian core yang diminta. `scripts/build.sh core --variant arcface-r100-gpu` hanya mem-build core. `VERSION=latest scripts/build.sh fe` gagal dengan pesan error. |
| FR-03 | `docker images` menampilkan `mega/compreface-{fe,admin,api,core,postgres-db}:1.2.0`. `docker inspect` menunjukkan label OCI `version` dan `revision` terisi. |
| FR-04 | `build-args.env` berisi blok default (FaceNet) dan `arcface-r100-gpu`. `GET /status` pada image `1.2.0` menampilkan `calculator_version` = `facenet.Calculator`, dan pada `1.2.0-arcface-r100-gpu` = `insightface.Calculator@arcface-r100-msfdrop75`. |
| FR-05 / NFR-09 | `docker run --network none mega/compreface-core:<tag>` mencapai `GET /healthcheck` = 200 dan `POST /find_faces` dengan sample image mengembalikan ≥1 wajah (diuji via `docker exec`). |
| FR-06 | `grep` tidak menemukan hostname service hardcoded di `services/compreface-fe/nginx.conf.template`. Mengubah `API_UPSTREAM` di compose mengubah target proxy (diverifikasi di config ter-render). |
| FR-07 / NFR-02 | Container fe dijalankan sendirian (tanpa admin/api/core): status Up/healthy ≥ 60 s, `GET /` = 200, `GET /api/v1/...` = 502, restart count = 0. |
| FR-08 | `GET /core/status` via fe = 200 dengan JSON core (`status: OK`); `POST /core/status` = 403; path core lain (`/core/healthcheck`, `/core/find_faces`, …) bukan respons core (SPA index/405) dan tidak tercatat di log core. |
| FR-09 | `kubectl kustomize k8s/overlays/{dev,prod}` sukses. Output memuat 4 Deployment, 1 StatefulSet dengan `volumeClaimTemplates`, 5 Service, ConfigMap, NetworkPolicy (default-deny + allow). Tidak ada Secret dengan nilai asli di repo. `kubeconform -strict` lulus bila tersedia. |
| FR-10 | Setiap container di output kustomize memiliki `readinessProbe` dan `livenessProbe`. Core memiliki `startupProbe` dengan `failureThreshold × periodSeconds ≥ 600`. |
| FR-11 | Overlay prod: core memakai tag `1.2.0-arcface-r100-gpu`, requests/limits core paling besar di antara semua service, `nvidia.com/gpu: 1`, dan manifest HPA contoh (dikomentari di `kustomization.yaml`). `UWSGI_PROCESSES` di ConfigMap prod konsisten dengan tabel sizing di CONFIGURATION.md. |
| FR-12 | ConfigMap api berisi `PYTHON_URL=http://compreface-core:3000`, dan Service `compreface-core` bertipe ClusterIP. |
| FR-13 | `docker inspect mega/compreface-admin:1.2.0` tidak memuat `APPERY_API_KEY`. `grep -r APPERY k8s/ docker-compose.yml` kosong. NetworkPolicy tidak mengizinkan egress internet. |
| FR-14 | `GET :8081/actuator/health` admin = `{"status":"UP"}` dengan email nonaktif. |
| FR-15 | Admin start dengan `SECURITY_SIGNINGKEY` dari env/Secret. Nilai tersebut tidak ada di image atau repo. |
| FR-16 | `docker compose up -d` di root: kelima container `Up (healthy)` dalam ≤ 5 menit. |
| FR-17 | MIGRATION.md memuat perintah backup/restore dan query validasi jumlah record untuk tabel `user`, `app`, `model`, `subject`, `img`, `embedding`, dengan kriteria go/no-go (selisih = 0). |
| FR-18 | `LICENSE` identik dengan upstream (checksum). `NOTICE` ada. Header copyright di source tidak berubah (git diff kosong pada `java/`, `ui/src`, `embedding-calculator/src`). |
| FR-19 | Semua dokumen memiliki blok metadata. Pengecekan konsistensi: setiap FR/NFR punya ≥1 TC, setiap env var di manifest tercantum di CONFIGURATION.md, dan semua link relatif valid (diverifikasi dengan script). |
| NFR-01 | Overlay prod: fe/api/core `replicas ≥ 2` (core GPU: sesuai jumlah GPU, default 1 dengan catatan), `PodDisruptionBudget` ada, strategy `maxUnavailable: 0`. |
| NFR-03 | Waktu dari container start hingga `/healthcheck` = 200 dan request pertama `/find_faces` sukses tercatat di TEST_PLAN; ≤ 180 s. |
| NFR-04 | Uji 20 request recognition setelah warm-up; p95 tercatat di TEST_PLAN dan dibandingkan dengan target. |
| NFR-05 | Mengubah `UWSGI_PROCESSES` di ConfigMap/compose tercermin di log uWSGI (jumlah worker). |
| NFR-06 | `docker run --rm <img> id -u` ≠ 0 untuk fe, admin, api, core. `docker history --no-trunc` tidak memuat password/key. Manifest memiliki `securityContext.runAsNonRoot: true`. |
| NFR-07 | NetworkPolicy yang ter-render hanya memuat alur di NFR-07 (review manifest + test case). |
| NFR-08 | `git ls-files` tidak memuat `.env` atau Secret berisi nilai asli (`.env` ditambahkan ke `.gitignore`; `.env.example` berisi placeholder). |
| NFR-10 | Log semua service ke stdout. ConfigMap prod tidak memuat level `DEBUG`. |
| NFR-11 | SECURITY.md memuat klasifikasi data, kontrol enkripsi in-transit/at-rest, akses, retensi & penghapusan, audit log, dan daftar gap beserta owner. |
| NFR-12 | Label OCI `revision` = `git rev-parse HEAD`. Digest image dicatat di output `push.sh`. |
| NFR-13 | Nama env var sama antara `.env.example`, compose, dan ConfigMap/Secret (dicek oleh script konsistensi). |

---

## 13. Deviasi & temuan implementasi (v0.2.0)

| ID | Terkait | SPEC v0.1.0 | Implementasi aktual | Alasan / bukti |
|---|---|---|---|---|
| D-01 | FR-05, NFR-09 | Model di-download dari Google Drive saat build | Model disalin dari image resmi `exadel/compreface-core:<tag>@sha256` (`MODEL_SOURCE=image`, default); `gdrive` tetap opsi | File Drive upstream kini meminta sign-in → build upstream gagal. Embedding identik (cosine 0,999992). [ADR-002](docs/adr/ADR-002-model-ml-baked-air-gapped.md) |
| D-02 | NFR-12 | – | apt core CPU dikunci ke `snapshot.debian.org` (`DEBIAN_SNAPSHOT=20260801T000000Z`) | `bullseye-security` mengembalikan 404 (pasca-EOL) |
| D-03 | NFR-01 | fe/api/core ≥ 2 replica, PDB `minAvailable 1`, `maxUnavailable 0` | core prod **1 replica** (1 GPU), strategi `maxSurge 0 / maxUnavailable 1`, PDB core `maxUnavailable 1` | Tanpa GPU cadangan, `maxSurge 1` → Pending; `minAvailable 1` dengan 1 replica memblokir drain. Ubah bila GPU ≥ 2 (RUNBOOK §4) |
| D-04 | – | – | compose api: `tmpfs /tmp:exec` | ND4J/JavaCPP memuat `.so` dari `/tmp`; tmpfs docker default `noexec` → `UnsatisfiedLinkError` (terdeteksi saat E2E) |
| D-05 | NFR-06 | – | Postgres di compose start sebagai root lalu turun ke uid 999 (gosu, perilaku image resmi); di k8s langsung `runAsUser 999` + read-only FS | Kompatibilitas volume compose; diuji ala k8s (TC-32) |
| D-06 | §11 | Dokumen upstream tetap di `docs/` | Dipindah ke `docs/upstream/` (termasuk README/CONTRIBUTING asli) | Bentrok nama case-insensitive |
| D-07 | NFR-11 | – | Temuan R-12 (gambar orphan setelah hapus subject) + mitigasi SQL | TC-33 |
| D-08 | FR-02 | – | Tambahan `scripts/e2e-test.sh`, `db-record-counts.sql`, `db-purge-orphan-images.sql`, `check-docs.sh` | Uji berulang & operasional |

Hasil verifikasi lengkap: [docs/TEST_PLAN.md](docs/TEST_PLAN.md).

## 14. Persetujuan

| Peran | Nama | Keputusan | Tanggal |
|---|---|---|---|
| Owner | | ☐ Approved ☐ Revisi | |
