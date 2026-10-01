# Menjalankan CompreFace (docker compose, host tunggal, GPU)

| Metadata | |
|---|---|
| Judul | Panduan menjalankan stack `mega/compreface-*` dengan docker compose — varian SubCenter-ArcFace-r100 GPU |
| Versi | 1.0.0 |
| Tanggal | 2026-10-01 |
| Owner | Tim Platform / DevOps |
| Status | Aktif |

| Versi | Tanggal | Penulis | Perubahan |
|---|---|---|---|
| 1.0.0 | 2026-10-01 | Claude Code | Versi awal |

Terkait: [CONFIGURATION](CONFIGURATION.md) · [RUNBOOK](RUNBOOK.md) · [MIGRATION](MIGRATION.md) · [ADR-002](adr/ADR-002-model-ml-baked-air-gapped.md) · [ADR-005](adr/ADR-005-varian-core.md)

Untuk Kubernetes lihat [DEPLOYMENT](DEPLOYMENT.md). Dokumen ini membahas docker compose di satu host.

## 1. Komponen

| Service compose | Image | Port | Keterangan |
|---|---|---|---|
| `compreface-fe` | `mega/compreface-fe:1.2.0` | host `8000`, `8502` → 8080 | UI + reverse proxy `/api/v1/` → api, `/admin/` → admin |
| `compreface-admin` | `mega/compreface-admin:1.2.0` | internal 8080 | Menjalankan migrasi Liquibase |
| `compreface-api` | `mega/compreface-api:1.2.0` | internal 8080 | REST API recognition/detection/verification |
| `compreface-core` | `mega/compreface-core:1.2.0-arcface-r100-gpu` | internal 3000 | Model **SubCenter-ArcFace r100** (`insightface.Calculator@arcface-r100-msfdrop75`) + RetinaFace r50, 1 GPU NVIDIA |
| `compreface-postgres-db` | `mega/compreface-postgres-db:1.2.0` | internal 5432 | PostgreSQL 11, volume `compreface_postgres-data` |

Hanya fe yang mem-publish port ke host. api tidak lagi diekspos langsung: klien memakai `http://<host>:8000/api/v1/...` dengan path yang sama seperti sebelumnya.

File compose:

| File | Fungsi |
|---|---|
| `docker-compose.yml` | Stack dasar (core CPU FaceNet) |
| `docker-compose.gpu.yml` | Override core → `1.2.0-arcface-r100-gpu` + reservasi 1 GPU |
| `docker-compose.legacy-ports.yml` | Menambah port `8502` agar URL UI lama tetap berlaku |

## 2. Prasyarat host

- Docker Engine ≥ 24 dengan plugin `docker compose` v2.
- Driver NVIDIA dan `nvidia-container-toolkit`. Cek dengan `docker run --rm --gpus all nvidia/cuda:11.8.0-base-ubuntu20.04 nvidia-smi`.
- RAM ≥ 24 GB untuk limit default (api 8g, core 12g, admin 1,5g). VRAM yang terpakai core ±5 GB (2 worker uWSGI).
- Image `mega/compreface-*` sudah ada di host (`docker images | grep mega/compreface`). Bila belum, build dengan `scripts/build.sh` ([DEPLOYMENT §2](DEPLOYMENT.md#2-build-mesin-berinternet)) atau `docker load` ([DEPLOYMENT §3](DEPLOYMENT.md#3-transfer-ke-registry-internal)).

## 3. Konfigurasi `.env`

```bash
cd /data/CompreFace
cp .env.example .env && chmod 600 .env
# isi secret WAJIB
sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=')|" .env
sed -i "s|^SECURITY_SIGNINGKEY=.*|SECURITY_SIGNINGKEY=$(openssl rand -hex 32)|" .env
# pakai varian GPU + port lama secara default (tanpa perlu -f di setiap perintah)
echo 'COMPOSE_FILE=docker-compose.yml:docker-compose.gpu.yml:docker-compose.legacy-ports.yml' >> .env
```

Nilai yang biasanya disesuaikan:

| Variabel | Nilai host ini | Keterangan |
|---|---|---|
| `FE_HTTP_PORT` | `8000` | Port utama (UI + API) |
| `FE_LEGACY_UI_PORT` | `8502` (default) | Port UI lama, dari `docker-compose.legacy-ports.yml` |
| `API_MEM_LIMIT` | `8g` | Heap = 75% dari limit. Cache embedding 88 rb wajah butuh heap besar |
| `CONNECTION_TIMEOUT` / `READ_TIMEOUT` | `600000` | ms, sama dengan stack lama |
| `CORE_GPU_MEM_LIMIT` | `12g` | |
| `UWSGI_PROCESSES` | `2` | Tiap proses memuat model sendiri di GPU (±2,4 GB VRAM/proses) |

`.env` berisi secret dan tidak di-commit. Daftar lengkap variabel ada di [CONFIGURATION](CONFIGURATION.md).

## 4. Menjalankan

### 4.1 Instalasi baru (DB kosong)

```bash
docker compose up -d
docker compose ps        # tunggu semua (healthy); core butuh hingga ±3 menit memuat model
```
Buka `http://<host>:8000`, lalu register. User pertama otomatis menjadi OWNER.

### 4.2 Dengan data dari backup / stack lama

admin menjalankan Liquibase saat start, jadi restore harus dilakukan **sebelum** admin pertama kali jalan:

```bash
docker compose up -d compreface-postgres-db          # postgres saja
sha256sum -c $BK/frs.dump.sha256
docker compose exec -T compreface-postgres-db sh -c \
  'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists --no-owner --role="$POSTGRES_USER" --exit-on-error' \
  < $BK/frs.dump
docker compose exec -T compreface-postgres-db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At -F "|"' \
  < scripts/db-record-counts.sql > $BK/counts-target.txt
diff $BK/counts-source.txt $BK/counts-target.txt && echo "JUMLAH RECORD SAMA"
docker compose up -d                                  # sisanya
```
Cara membuat dump dari sumber dijelaskan di [MIGRATION §4](MIGRATION.md#4-backup-sumber). API key collection ikut termigrasi, jadi klien tidak perlu key baru. Karena `SECURITY_SIGNINGKEY` baru, user UI harus login ulang.

### 4.3 Operasional

```bash
docker compose ps
docker compose logs -f compreface-api
docker compose restart compreface-core
docker compose stop                    # hentikan tanpa menghapus
docker compose down                    # hapus container; volume data TETAP ada
# JANGAN `docker compose down -v` — menghapus volume DB (data biometrik)
```

## 5. Verifikasi

```bash
# model aktif → calculator_version = insightface.Calculator@arcface-r100-msfdrop75
docker compose exec -T compreface-core curl -s localhost:3000/status
# konsistensi DB ↔ model → status OK, dbIsInconsistent false
docker compose exec -T compreface-api curl -s localhost:8080/api/v1/consistence/status
# GPU dipakai proses core
nvidia-smi --query-compute-apps=pid,used_memory --format=csv
# UI & proxy API (400 tanpa x-api-key = normal)
curl -s -o /dev/null -w '%{http_code}\n' localhost:8000/
curl -s -o /dev/null -w '%{http_code}\n' localhost:8000/api/v1/recognition/subjects
```
Setelah start, request recognition **pertama** per collection bisa memakan waktu ±1–2 menit karena api memuat seluruh embedding ke cache memori. Request berikutnya ±0,5 detik.

Uji end-to-end (membuat app/collection uji sendiri dengan gambar fixture publik): `scripts/e2e-test.sh http://127.0.0.1:8000`. Lihat header skrip untuk env `E2E_EMAIL`/`E2E_PASSWORD` bila DB sudah berisi data.

## 6. File model SubCenter-ArcFace-r100

Model di-bake ke image core di `/app/ml/.models` ([ADR-002](adr/ADR-002-model-ml-baked-air-gapped.md)). Image core sudah cukup untuk menjalankan stack, sedangkan arsip model berguna sebagai cadangan atau untuk build ulang tanpa image Exadel.

| File | Isi |
|---|---|
| `insightface/calculator/arcface-r100-msfdrop75/` | **SubCenter-ArcFace r100**, embedding 512-d |
| `insightface/detector/retinaface_r50_v1/` | Detektor wajah RetinaFace r50 |
| `insightface/age/`, `insightface/gender/` (genderage_v1) | Plugin umur/gender |
| `facemask/mask/mobilenet_v2_on_mafa_kaggle123/` | Plugin masker |
| `MODELS.sha256` | Checksum semua file (dibuat saat build) |

### 6.1 Ekspor arsip (mis. untuk disimpan di Google Drive)

```bash
mkdir -p /data/compreface-models && cd /data/compreface-models
docker compose -f /data/CompreFace/docker-compose.yml -f /data/CompreFace/docker-compose.gpu.yml \
  exec -T compreface-core tar -C /app/ml -czf - .models > compreface-models-1.2.0-arcface-r100-gpu.tar.gz
sha256sum compreface-models-1.2.0-arcface-r100-gpu.tar.gz > compreface-models-1.2.0-arcface-r100-gpu.tar.gz.sha256
```
Unggah `.tar.gz` dan `.sha256` ke folder Google Drive dengan akses terbatas. Untuk verifikasi setelah diunduh, jalankan `sha256sum -c *.sha256`, lalu ekstrak dan jalankan `cd .models && sha256sum -c MODELS.sha256`.

### 6.2 Build core dari arsip model

Dockerfile core menyalin `/app/ml/.models` dari `MODELS_IMAGE`. Arsip bisa dijadikan image "models-only":

```bash
cd /data/compreface-models
printf 'FROM scratch\nADD compreface-models-1.2.0-arcface-r100-gpu.tar.gz /app/ml/\n' > Dockerfile.models
docker build -f Dockerfile.models -t mega/compreface-models:1.2.0-arcface-r100 .
# lalu di services/compreface-core/build-args.env, varian [arcface-r100-gpu]:
#   MODELS_IMAGE=mega/compreface-models:1.2.0-arcface-r100
cd /data/CompreFace && scripts/build.sh core --variant arcface-r100-gpu
```
Model harus tetap `arcface-r100-msfdrop75`. Model lain menghasilkan embedding yang **tidak kompatibel** dengan data di DB ([MIGRATION §8](MIGRATION.md#8-perubahan-model-core-tidak-dalam-scope-cutover)).

## 7. Rollback ke stack lama

Stack lama (`custom-builds/SubCenter-ArcFace-r100-gpu`, image `exadel/*` + override `mega/*`) dan volume DB-nya tidak dihapus. Untuk kembali ke stack lama:

```bash
cd /data/CompreFace && docker compose down                 # volume baru tetap ada
cd <dir-stack-lama>/custom-builds/SubCenter-ArcFace-r100-gpu && docker compose up -d
```
Data yang ditulis ke stack baru setelah cutover **tidak** ikut kembali. Bila data itu perlu dibawa, dump dari stack baru lalu restore ke DB lama ([MIGRATION §7](MIGRATION.md#7-rollback-plan)).

## 8. Troubleshooting singkat

| Gejala | Penyebab / tindakan |
|---|---|
| core `unhealthy` / restart | GPU tidak terlihat → cek `nvidia-smi` & toolkit; VRAM penuh → kurangi `UWSGI_PROCESSES`. [RUNBOOK §7.2](RUNBOOK.md#72-core-gagal-start--gagal-load-model) |
| api tidak start, menunggu | api menunggu admin dan core `healthy` (depends_on) |
| `variable is not set ... POSTGRES_PASSWORD` | `.env` belum diisi (§3) |
| api `OutOfMemoryError` | Naikkan `API_MEM_LIMIT` |
| UI tidak bisa login setelah migrasi | Signing key berubah, jadi bersihkan cookie atau login ulang |
| Port 8000/8502 bentrok | Ubah `FE_HTTP_PORT` / `FE_LEGACY_UI_PORT` |
