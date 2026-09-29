# Konfigurasi CompreFace (mega)

| Metadata | |
|---|---|
| Judul | Referensi Konfigurasi — env var, Secret, build args |
| Versi | 1.0.0 |
| Tanggal | 2026-09-29 |
| Owner | Tim Platform / DevOps |
| Status | Review |

| Versi | Tanggal | Penulis | Perubahan |
|---|---|---|---|
| 1.0.0 | 2026-09-29 | Claude Code | Versi awal, sesuai implementasi Fase 3–4 |

Dokumen ini adalah **sumber kebenaran** nama dan nilai konfigurasi ([SPEC](../SPEC.md) NFR-13). Nama env var sama di tiga tempat:

| Lokasi | File |
|---|---|
| Kubernetes | `k8s/base/<service>/configmap.env` (ConfigMap), Secret di luar git |
| Compose | `docker-compose.yml` + `.env` (salinan dari [`.env.example`](../.env.example)) |
| Default di image | `ENV` di `services/<service>/Dockerfile` |

Kolom **Sumber**: `CM` = ConfigMap, `Secret` = Secret Kubernetes, `Image` = default di Dockerfile (tidak di-set manifest), `Compose` = hanya compose.
**Wajib** = service tidak berjalan benar tanpa nilai ini (bila default image tidak cocok).

## 1. Secret

Dibuat di luar git (lihat [DEPLOYMENT §4](DEPLOYMENT.md#4-buat-secret)); contoh struktur di [`k8s/base/secret.example.yaml`](../k8s/base/secret.example.yaml).

| Secret | Key | Dipakai oleh | Wajib | Keterangan |
|---|---|---|---|---|
| `compreface-postgres-credentials` | `POSTGRES_USER` | postgres-db, admin, api | Ya | User DB aplikasi. Compose: `.env` (default `compreface`) |
| `compreface-postgres-credentials` | `POSTGRES_PASSWORD` | postgres-db, admin, api | Ya | Password kuat (≥ 24 karakter acak). **Jangan** `postgres` |
| `compreface-admin-secrets` | `SECURITY_SIGNINGKEY` | admin | Ya | Menggantikan `security.signing-key` yang hardcoded di upstream. Kode 1.2.0 memakai `JdbcTokenStore` (token opaque di DB), sehingga key ini tidak aktif dipakai. Tetap di-set dari Secret agar tidak ada default di image (defense in depth). `openssl rand -hex 32` |
| `compreface-admin-secrets` | `EMAIL_USERNAME` | admin | Opsional | Hanya jika `ENABLE_EMAIL_SERVER=true` (`optional: true` di manifest) |
| `compreface-admin-secrets` | `EMAIL_PASSWORD` | admin | Opsional | idem |

## 2. compreface-fe

| Env var | Deskripsi | Default | Wajib | Sumber |
|---|---|---|---|---|
| `ADMIN_UPSTREAM` | `host:port` Service admin | `compreface-admin:8080` | Ya | CM |
| `API_UPSTREAM` | `host:port` Service api | `compreface-api:8080` | Ya | CM |
| `NGINX_RESOLVER` | IP DNS untuk resolver nginx; kosong = otomatis dari `nameserver` pertama di `/etc/resolv.conf` | *(kosong)* | Opsional | CM |
| `NGINX_RESOLVER_VALID` | TTL cache DNS nginx | `10s` | Opsional | CM |
| `NGINX_UPSTREAM_AUTO_FQDN` | `true` = host tanpa titik dilengkapi domain `search` pertama (k8s). Diabaikan di DNS docker (127.0.0.11) | `true` | Opsional | CM |
| `CLIENT_MAX_BODY_SIZE` | Batas ukuran request nginx | `10M` | Opsional | CM |
| `PROXY_READ_TIMEOUT` | Timeout baca proxy ke api (dengan satuan `ms`) | `60000ms` | Opsional | CM |
| `PROXY_CONNECT_TIMEOUT` | Timeout koneksi proxy ke api | `10000ms` | Opsional | CM |
| `TZ` | Zona waktu | `Asia/Jakarta` | Opsional | CM |

Port container: **8080** (non-root). Service: `80 → 8080`. Health: `GET /healthz`.

## 3. compreface-admin

| Env var | Deskripsi | Default | Wajib | Sumber |
|---|---|---|---|---|
| `POSTGRES_URL` | JDBC URL | `jdbc:postgresql://compreface-postgres-db:5432/frs` | Ya | CM |
| `POSTGRES_USER`, `POSTGRES_PASSWORD` | Kredensial DB | – | Ya | Secret |
| `SECURITY_SIGNINGKEY` | lihat §1 | – | Ya | Secret |
| `PYTHON_URL` | URL core (dipakai modul common) | `http://compreface-core:3000` | Ya | CM |
| `ADMIN_JAVA_OPTS` | Opsi JVM | `-XX:MaxRAMPercentage=75.0` | Opsional | CM |
| `JAVA_TOOL_OPTIONS` | Opsi JVM global (zona waktu) | `-Duser.timezone=Asia/Jakarta` | Opsional | CM |
| `SPRING_PROFILES_ACTIVE` | Profile Spring. Tetap `dev` seperti upstream; profile `prod` mengaktifkan log JSON tetapi properti swagger api hanya ada di profile `dev` | `dev` | Ya | CM |
| `MAX_FILE_SIZE` / `MAX_REQUEST_SIZE` | Batas upload multipart | `5MB` / `10MB` | Opsional | CM |
| `SAVE_IMAGES_TO_DB` | Simpan gambar wajah di tabel `img` | `true` | Opsional | CM |
| `ENABLE_EMAIL_SERVER` | Aktifkan email (registrasi/reset password) | `false` | Opsional | CM |
| `EMAIL_HOST` / `EMAIL_FROM` | SMTP relay internal & alamat pengirim | `smtp.example.internal` / `CompreFace <no-reply@example.internal>` | Jika email aktif | CM |
| `EMAIL_USERNAME` / `EMAIL_PASSWORD` | Kredensial SMTP | – | Jika email aktif | Secret |
| `FRS_CRUD_HOST` | URL publik UI (dipakai di tautan email) | `http://localhost:8000` | Jika email aktif | CM |
| `MANAGEMENT_SERVER_PORT` | Port actuator terpisah (probe) | `8081` | Ya | CM + Image |
| `MANAGEMENT_HEALTH_MAIL_ENABLED` | Health tidak bergantung SMTP | `false` | Ya | CM + Image |
| `MANAGEMENT_ENDPOINT_HEALTH_PROBES_ENABLED` | Endpoint `/actuator/health/{liveness,readiness}` | `true` | Ya | CM + Image |
| `LOGGING_LEVEL_COM_EXADEL` | Level log aplikasi. **Prod: INFO** (DEBUG berisiko mencatat data pribadi) | `INFO` (dev overlay: `DEBUG`) | Opsional | CM |
| `TZ` | Zona waktu | `Asia/Jakarta` | Opsional | CM |

Env upstream lain yang **tidak di-set** (default aplikasi berlaku): `CRUD_PORT` (8080), `COMMON_ACCESS_TOKEN_VALIDITY` (2400 s), `COMMON_REFRESH_TOKEN_VALIDITY` (1209600 s), `DNS_URL`, `MODEL_STATISTIC_MONTHS` (6), `CONNECTION_TIMEOUT`, `READ_TIMEOUT`, `MAX_ATTEMPTS`. **`APPERY_API_KEY` sengaja tidak di-set** (telemetry nonaktif; [SECURITY §5](SECURITY.md#5-telemetry--transfer-data-ke-pihak-ketiga)).

## 4. compreface-api

| Env var | Deskripsi | Default | Wajib | Sumber |
|---|---|---|---|---|
| `POSTGRES_URL` | JDBC URL | `jdbc:postgresql://compreface-postgres-db:5432/frs` | Ya | CM |
| `POSTGRES_USER`, `POSTGRES_PASSWORD` | Kredensial DB | – | Ya | Secret |
| `PYTHON_URL` | URL core via Service ClusterIP ([SPEC](../SPEC.md) FR-12) | `http://compreface-core:3000` | Ya | CM |
| `API_JAVA_OPTS` | Opsi JVM | `-XX:MaxRAMPercentage=75.0` | Opsional | CM |
| `JAVA_TOOL_OPTIONS` | Zona waktu JVM | `-Duser.timezone=Asia/Jakarta` | Opsional | CM |
| `SPRING_PROFILES_ACTIVE` | lihat admin | `dev` | Ya | CM |
| `SAVE_IMAGES_TO_DB` | Simpan gambar wajah di DB (dibutuhkan untuk recalculation embedding saat ganti model) | `true` | Opsional | CM |
| `MAX_FILE_SIZE` / `MAX_REQUEST_SIZE` | Batas upload | `5MB` / `10MB` | Opsional | CM |
| `CONNECTION_TIMEOUT` | Timeout koneksi api → core (ms) | `10000` | Opsional | CM |
| `READ_TIMEOUT` | Timeout baca api → core (ms) | `60000` | Opsional | CM |
| `MAX_ATTEMPTS` | Retry Feign ke core | `1` | Opsional | CM |
| `MANAGEMENT_SERVER_PORT` | Port actuator (di 8080 `/actuator` diblokir filter `x-api-key`) | `8081` | Ya | CM + Image |
| `MANAGEMENT_ENDPOINT_HEALTH_PROBES_ENABLED` | Endpoint liveness/readiness | `true` | Ya | CM + Image |
| `LOGGING_LEVEL_COM_EXADEL` | Level log. Konfigurasi compose lama memakai DEBUG untuk request logging — jangan di prod | `INFO` (dev: `DEBUG`) | Opsional | CM |
| `TZ` | Zona waktu | `Asia/Jakarta` | Opsional | CM |

Env upstream lain yang tidak di-set: `API_PORT` (8080), `MODEL_STATISTIC_CRON_EXPRESSION`. Build arg: `ND4J_CLASSIFIER` (§8).

## 5. compreface-core

| Env var | Deskripsi | Default | Wajib | Sumber |
|---|---|---|---|---|
| `ML_PORT` | Port HTTP uWSGI (dibaca `uwsgi.ini`) | `3000` | Opsional | CM + Image |
| `IMG_LENGTH_LIMIT` | Sisi terpanjang gambar sebelum deteksi (px) | `640` | Opsional | CM + Image |
| `UWSGI_PROCESSES` | Jumlah worker uWSGI (dibaca otomatis oleh uWSGI). Lihat §7 | `2` (prod: `4`) | Opsional | CM + Image |
| `UWSGI_THREADS` | Thread per worker | `1` | Opsional | CM + Image |
| `UWSGI_MAX_WORKER_LIFETIME` | Worker di-recycle setelah N detik (mitigasi memory leak; nilai dari konfigurasi compose sebelumnya) | `93600` | Opsional | CM |
| `LOGGING_LEVEL_NAME` | Level log Python | `info` | Opsional | CM + Image |
| `TZ` | Zona waktu | `Asia/Jakarta` | Opsional | CM |
| `FACE_DETECTION_PLUGIN`, `CALCULATION_PLUGIN`, `EXTRA_PLUGINS`, `GPU_IDX`, `INTEL_OPTIMIZATION` | Ditetapkan saat **build** (§8) dan menjadi ENV image. **Jangan** di-override saat runtime: model plugin lain tidak ada di image | per varian | – | Image |
| `MPLCONFIGDIR`, `HOME`, `CUDA`, `TF_FORCE_GPU_ALLOW_GROWTH`, `MXNET_*` | Internal image (root FS read-only, GPU) | – | – | Image |

## 6. compreface-postgres-db

| Env var | Deskripsi | Default | Wajib | Sumber |
|---|---|---|---|---|
| `POSTGRES_DB` | Nama database | `frs` | Ya | CM + Image |
| `POSTGRES_USER`, `POSTGRES_PASSWORD` | Superuser awal (dibuat saat init volume kosong) | – | Ya | Secret |
| `PGDATA` | Direktori data. Subdirektori agar aman di PVC berisi `lost+found`. **Berbeda dengan volume compose lama** (lihat [MIGRATION](MIGRATION.md)) | `/var/lib/postgresql/data/pgdata` | Ya | CM + Image |
| `TZ` | Zona waktu | `Asia/Jakarta` | Opsional | CM |

## 7. Sizing core (`UWSGI_PROCESSES` vs resource)

Hasil ukur Fase 4 ([bukti](test-evidence/2026-09-29/tc-airgap-core-gpu.txt)): InsightFace ArcFace-r100 memakai ≈ **2,56 GB VRAM per proses**.

| Environment | Varian | CPU req/limit | Memori req/limit | GPU | `UWSGI_PROCESSES` | Aturan |
|---|---|---|---|---|---|---|
| base/dev | FaceNet CPU `1.2.0` | 1 / 2 | 3Gi / 6Gi | – | 2 | ≈ 1 proses per core limit |
| prod | ArcFace GPU `1.2.0-arcface-r100-gpu` | 2 / 4 | 8Gi / 12Gi | 1 | 4 | ≤ CPU limit **dan** ≤ VRAM/2,6 GB (GPU 24 GB: maks ≈ 8) |

Ubah `UWSGI_PROCESSES` bersamaan dengan patch resource di `k8s/overlays/prod/patches/core-resources.yaml`.

## 8. Build args

### 8.1 compreface-core — [`services/compreface-core/build-args.env`](../services/compreface-core/build-args.env)

| Build arg | Deskripsi | `[default]` (tag `1.2.0`) | `[arcface-r100-gpu]` (tag `1.2.0-arcface-r100-gpu`) |
|---|---|---|---|
| `TAG_SUFFIX` *(build.sh)* | Suffix tag | *(kosong)* | `-arcface-r100-gpu` |
| `COMPUTE` | Stage base: `cpu` / `gpu` | `cpu` | `gpu` |
| `GPU_IDX` | -1 = CPU, 0 = GPU pertama | `-1` | `0` |
| `INTEL_OPTIMIZATION` | MKL | `false` | `false` |
| `FACE_DETECTION_PLUGIN` | Detector | `facenet.FaceDetector` | `insightface.FaceDetector@retinaface_r50_v1` |
| `CALCULATION_PLUGIN` | Calculator (embedding) | `facenet.Calculator` | `insightface.Calculator@arcface-r100-msfdrop75` |
| `EXTRA_PLUGINS` | Plugin tambahan | `facenet.LandmarksDetector, agegender.AgeDetector, agegender.GenderDetector, facenet.facemask.MaskDetector, facenet.PoseEstimator` | `insightface.LandmarksDetector, insightface.GenderDetector, insightface.AgeDetector, insightface.facemask.MaskDetector, insightface.PoseEstimator` |
| `SKIP_TESTS` | Kosong = jalankan pytest saat build | *(kosong)* | `1` (tanpa GPU saat build) |
| `MODEL_SOURCE` | `image` / `gdrive` ([ADR-002](adr/ADR-002-model-ml-baked-air-gapped.md)) | `image` | `image` |
| `MODELS_IMAGE` | Sumber `/app/ml/.models` (di-pin digest) | `exadel/compreface-core:1.2.0@sha256:c9c70f0f…` | `exadel/compreface-core:1.2.0-arcface-r100@sha256:bc8b3831…` |

Build arg di Dockerfile (bukan di `build-args.env`): `CPU_BASE_IMAGE`, `GPU_BASE_IMAGE` (di-pin digest), `DEBIAN_SNAPSHOT` (default `20260801T000000Z`; kosong = mirror resmi), serta `VERSION`, `REVISION`, `VARIANT`, `BE_VERSION`, `APP_VERSION_STRING` yang diisi otomatis oleh `scripts/build.sh`.

Varian lain di `build-args.env`: `arcface-r100` (CPU), `facenet`, `mobilenet`, `mobilenet-gpu`.

### 8.2 Service lain

| Service | Build arg | Default | Keterangan |
|---|---|---|---|
| api | `ND4J_CLASSIFIER` | `linux-x86_64` | `linux-x86_64-avx2` / `-avx512` untuk CPU modern (env `ND4J_CLASSIFIER` di `build.sh`) |
| admin, api | `MAVEN_IMAGE`, `JRE_IMAGE` | di-pin digest | |
| fe | `NODE_IMAGE`, `NGINX_IMAGE` | di-pin digest | |
| postgres-db | `POSTGRES_IMAGE` | `postgres:11.5@sha256:b3770d9c…` | |
| semua | `VERSION`, `REVISION` | dari `build.sh` | Label OCI |

## 9. Variabel khusus compose / script

| Variabel | Dipakai | Default | Keterangan |
|---|---|---|---|
| `COMPOSE_PROJECT_NAME` | compose | `compreface` | Prefix container/volume |
| `REGISTRY` | compose | *(kosong)* | Compose: prefix **dengan** `/` di akhir (mis. `registry.example.internal/`). `build.sh`: host tanpa `/` |
| `FE_VERSION`, `ADMIN_VERSION`, `API_VERSION`, `CORE_VERSION`, `POSTGRES_VERSION` | compose, build.sh | `1.2.0` | Tag image per service |
| `CORE_GPU_VERSION` | `docker-compose.gpu.yml` | `1.2.0-arcface-r100-gpu` | |
| `FE_HTTP_PORT` | compose | `8000` | Port host → fe:8080 |
| `ADMIN_MEM_LIMIT`, `API_MEM_LIMIT`, `CORE_MEM_LIMIT`, `CORE_GPU_MEM_LIMIT` | compose | `1536m`, `3g`, `6g`, `12g` | Batas memori container |
| `IMAGE_NAMESPACE`, `DOCKER_BUILD_ARGS` | build.sh, push.sh | `mega`, – | |
| `E2E_EMAIL`, `E2E_PASSWORD`, `LATENCY_N`, `CLEANUP` | e2e-test.sh | – | Lihat header skrip |
