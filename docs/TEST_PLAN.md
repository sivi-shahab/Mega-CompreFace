# Test Plan & Hasil Uji — CompreFace (mega)

| Metadata | |
|---|---|
| Judul | Test Plan, Traceability Matrix & Hasil Eksekusi |
| Versi | 1.0.0 |
| Tanggal | 2026-09-29 |
| Owner | Tim Platform / DevOps |
| Status | Review |

| Versi | Tanggal | Penulis | Perubahan |
|---|---|---|---|
| 1.0.0 | 2026-09-29 | Claude Code | Versi awal; hasil eksekusi Fase 4 (2026-09-29) |

Requirement: [SPEC.md](../SPEC.md) (FR-01..FR-19, NFR-01..NFR-13). Bukti mentah: [`docs/test-evidence/2026-09-29/`](test-evidence/2026-09-29/).

## 1. Strategi uji

| Level | Cakupan | Alat | Lingkungan |
|---|---|---|---|
| Build | Build per service/varian, unit test core (pytest upstream saat build CPU) | `scripts/build.sh` | Host build (8 vCPU, GPU NVIDIA 24 GB) |
| Statis | Label, user, secret di layer, lisensi, diff source, lint manifest | `docker inspect/history`, `git`, `kubeconform` | Host build |
| Container | Air-gapped core, fe tanpa backend, postgres ala securityContext k8s | `docker run --network none`, `--read-only`, `--user` | Host build |
| Integrasi / E2E | 5 service via compose, UI → admin → api → core → db | `docker compose` (project terisolasi `cfverify`, port 18000) + [`scripts/e2e-test.sh`](../scripts/e2e-test.sh) | Host build |
| Performa | Startup core, latensi recognition (20 request setelah warm-up) | `e2e-test.sh` | Host build |
| Migrasi | Gladi dump/restore + validasi jumlah record | [`scripts/db-record-counts.sql`](../scripts/db-record-counts.sql) | Data sintetis |
| Manifest | Render + validasi skema, review nilai | `kubectl kustomize`, `kubeconform -strict` (k8s 1.30) | Tanpa cluster |
| Dokumentasi | Konsistensi FR/NFR↔TC, env var↔CONFIGURATION, link | [`scripts/check-docs.sh`](../scripts/check-docs.sh) | Repo |

Data uji: hanya fixture publik upstream (`embedding-calculator/sample_images`). **Tidak ada data nasabah** yang dipakai; DB produksi hanya dibaca untuk `count(*)`.

Batasan: **tidak ada cluster Kubernetes** yang tersedia saat pengujian. Manifest divalidasi secara statis, dan perilaku runtime k8s disimulasikan dengan docker (UID, read-only FS, resolv.conf kube-dns). Uji di cluster nyata tercatat sebagai TC-36 (Not Run).

## 2. Test case & hasil

Status: ✅ PASS · ⚠️ PASS dengan catatan · ❌ FAIL · ⏸ NOT RUN

| TC | Judul | Langkah ringkas | Ekspektasi | Hasil aktual | Status | Bukti |
|---|---|---|---|---|---|---|
| TC-01 | Build per service independen | `build.sh <svc>` untuk tiap service | exit 0, hanya service tsb dibangun | 5 service + 2 varian core dibangun terpisah; waktu cache: admin 4 s, api 1 s | ✅ | [tc-build-all](test-evidence/2026-09-29/tc-build-all.txt) |
| TC-02 | Perilaku build.sh | `all`, `--variant a,b`, `--version latest` | build sesuai; `latest` ditolak | `ERROR: tag 'latest' dilarang` | ✅ | [tc-static-checks](test-evidence/2026-09-29/tc-static-checks.txt) |
| TC-03 | Nama image & label OCI | `docker images`, `inspect` label | `mega/compreface-<svc>:<ver>`, label version/revision | Semua sesuai; revision = commit git (`-dirty` karena belum commit) | ✅ | tc-static-checks |
| TC-04 | Varian core sesuai build-args | `GET /status` | default=`facenet.Calculator`; gpu=`insightface.Calculator@arcface-r100-msfdrop75` | Sesuai | ✅ | [cpu](test-evidence/2026-09-29/tc-airgap-core-cpu.txt), [gpu](test-evidence/2026-09-29/tc-airgap-core-gpu.txt) |
| TC-05 | Core CPU air-gapped | `--network none --read-only`, healthcheck, `/find_faces` semua plugin | 200, wajah terdeteksi, egress gagal | healthy 47 s; 512-dim embedding + age/gender/mask; egress exit 6 | ✅ | tc-airgap-core-cpu |
| TC-06 | Core GPU air-gapped | idem + `--gpus` | idem | healthy 21 s; inferensi 1,1 s (7 plugin); 2,56 GB VRAM/proses | ✅ | tc-airgap-core-gpu |
| TC-07 | Hostname dari env (fe) | grep template; override `API_UPSTREAM`; resolv.conf ala k8s | 0 hardcode; nilai env dipakai; FQDN otomatis | 0 hardcode; `compreface-api.compreface-dev.svc.cluster.local:8080`; override eksplisit & IPv6 resolver OK | ✅ | [tc-fe-no-hardcode](test-evidence/2026-09-29/tc-fe-no-hardcode.txt) (+ uji Fase 3 di log sesi) |
| TC-08 | fe tanpa backend | fe jalan, admin/api dimatikan | fe healthy, `/`=200, API=502, restart 0 | Sesuai | ✅ | [tc-fe-resilience](test-evidence/2026-09-29/tc-fe-resilience.txt) |
| TC-09 | fe re-resolve setelah IP backend berubah | recreate api dengan IP berbeda | fe pulih tanpa restart | IP .6→.7, `/admin`=200, `/api`=200, restart 0 | ✅ | tc-fe-resilience |
| TC-10 | Route `/core/` dihapus | `GET /core/status` via fe | bukan respons core | Mengembalikan index SPA | ✅ | [tc-misc-cpu](test-evidence/2026-09-29/tc-misc-cpu.txt) |
| TC-11 | Render & validasi manifest | `kubectl kustomize` dev/prod + `kubeconform -strict` | exit 0, valid | dev 24/24, prod 28/28, opsional 4/4 valid | ✅ | [tc-k8s-validate](test-evidence/2026-09-29/tc-k8s-validate.txt) |
| TC-12 | Probe lengkap | parse output kustomize | readiness+liveness semua; startup core ≥ 600 s | Sesuai; core 600 s, admin/api 300 s | ✅ | tc-k8s-validate |
| TC-13 | api → core via ClusterIP + ConfigMap | review render prod | `PYTHON_URL=http://compreface-core:3000`, Service ClusterIP | Sesuai | ✅ | [tc-k8s-manifest-review](test-evidence/2026-09-29/tc-k8s-manifest-review.txt) |
| TC-14 | Telemetry Appery nonaktif | env image, grep manifest, NetworkPolicy | tidak ada key, tidak ada egress | 0 referensi | ✅ | tc-static-checks |
| TC-15 | Health admin tanpa SMTP | `:8081/actuator/health` | `UP` | `{"status":"UP"}` | ✅ | tc-misc-cpu |
| TC-16 | Signing key dari env | start admin dengan `SECURITY_SIGNINGKEY`; history image | start OK; key tidak di image | Sesuai | ✅ | tc-static-checks |
| TC-17 | Compose 5 container healthy | `docker compose up -d --wait` | 5 × `Up (healthy)` ≤ 5 menit | CPU 62 s, GPU 38 s | ✅ | [cpu](test-evidence/2026-09-29/tc-compose-startup.txt), [gpu](test-evidence/2026-09-29/tc-compose-startup-gpu.txt) |
| TC-18 | Gladi migrasi DB | dump → restore (uid 999, user beda, skema Liquibase sudah ada) → count → start admin | diff kosong; 0 changeset baru | diff kosong; `pg_restore` exit 0; changeset 0 | ✅ | [tc-db-restore-rehearsal](test-evidence/2026-09-29/tc-db-restore-rehearsal.txt) |
| TC-19 | Lisensi & source upstream | `git diff` LICENSE; status `java/ ui/ embedding-calculator/` | identik; 0 perubahan; NOTICE ada | Sesuai | ✅ | tc-static-checks |
| TC-20 | Konsistensi dokumentasi | `scripts/check-docs.sh` | 0 error | Lihat §4 | ✅ | §4 |
| TC-21 | E2E CPU | `e2e-test.sh` (UI, register/login, app, collection, add face, recognize, negatif) | 0 FAIL | 8 PASS, 0 FAIL; similarity 0,99485 vs negatif 0,0329 | ✅ | [tc-e2e-cpu](test-evidence/2026-09-29/tc-e2e-cpu.txt) |
| TC-22 | E2E GPU (varian prod) | idem dengan `docker-compose.gpu.yml` | 0 FAIL | 8 PASS, 0 FAIL; similarity 0,99985 vs 0,08363 | ✅ | [tc-e2e-gpu](test-evidence/2026-09-29/tc-e2e-gpu.txt) |
| TC-23 | Kompatibilitas embedding dengan produksi | embedding gambar sama: image baru GPU vs `exadel/compreface-core:1.2.0-arcface-r100` | cosine ≥ 0,999 | **0,999992** | ✅ | [tc-embedding-compat](test-evidence/2026-09-29/tc-embedding-compat.txt) |
| TC-24 | Availability prod | review render prod | replicas ≥ 2, PDB, `maxUnavailable: 0` | fe/admin/api 2 replica + PDB `minAvailable 1`. **Core 1 replica, `maxSurge 0/maxUnavailable 1`, PDB `maxUnavailable 1`** (1 GPU; deviasi terdokumentasi) | ⚠️ | tc-k8s-manifest-review |
| TC-25 | Startup core | waktu start → inferensi pertama | ≤ 180 s | CPU 48 s, GPU 25 s | ✅ | tc-airgap-core-* |
| TC-26 | Latensi recognition | 20 request 1 wajah setelah warm-up, via fe | p95 ≤ 3 s (CPU) / ≤ 1,5 s (GPU) | CPU p95 0,351 s; GPU p95 0,101 s | ✅ | tc-e2e-* |
| TC-27 | `UWSGI_PROCESSES` | ubah 2 → 3 | jumlah worker di log berubah | 2 → 3 worker | ✅ | [tc-uwsgi-processes](test-evidence/2026-09-29/tc-uwsgi-processes.txt) |
| TC-28 | Non-root & tanpa secret di image | `id -u`, `docker history` | uid ≠ 0 untuk fe/admin/api/core; 0 secret | fe 101, admin/api 1001, core 33; postgres image uid 0 → gosu 999 (compose), `runAsUser 999` (k8s) | ⚠️ | tc-static-checks, tc-misc-cpu |
| TC-29 | NetworkPolicy | review render | hanya alur SPEC NFR-07; core & DB tanpa egress | Sesuai (7 policy) | ✅ (statis) | tc-k8s-manifest-review |
| TC-30 | Tidak ada secret di git | `git ls-files` | tidak ada `.env`/secret asli baru | `.env` root dihapus; 6 `.env` **lama upstream** (`dev/`, `custom-builds/`) masih ter-track (default `postgres`, tidak dipakai) | ⚠️ | tc-static-checks |
| TC-31 | Logging prod | review ConfigMap prod | stdout; tanpa DEBUG | INFO/info; DEBUG hanya overlay dev | ✅ | tc-k8s-manifest-review |
| TC-32 | Postgres dengan securityContext k8s | `--user 999 --read-only`, volume group 999 | healthy, `uuid-ossp` ada | Sesuai | ✅ | [tc-postgres-k8s-sim](test-evidence/2026-09-29/tc-postgres-k8s-sim.txt) |
| TC-33 | Penghapusan data subject (hak hapus) | tambah 2 subject × 2 foto, hapus via API, hitung `img` | subject, embedding, **dan gambar** terhapus | **Gambar tertinggal (4 orphan)** — bug upstream. Setelah `db-purge-orphan-images.sql`: 0 | ❌ → ⚠️ (dimitigasi) | [tc-subject-deletion](test-evidence/2026-09-29/tc-subject-deletion.txt) |
| TC-34 | Kelengkapan kontrol UU PDP di dokumen | review SECURITY.md | klasifikasi, enkripsi, akses, retensi, audit, gap | Ada; gap S-01..S-13 tercatat | ✅ | [SECURITY.md](SECURITY.md) |
| TC-35 | Reproducibility | pin digest base & model, snapshot apt, label revision, digest push | semua ter-pin; digest tercatat | Pin & label ✅; **push ke registry belum dijalankan** (tidak ada registry internal) | ⚠️ | tc-static-checks, [CONFIGURATION §8](CONFIGURATION.md#8-build-args) |
| TC-36 | Deploy ke cluster Kubernetes nyata | `kubectl apply -k` dev/prod + [DEPLOYMENT §6](DEPLOYMENT.md#6-verifikasi-pasca-deploy) | semua pod Ready; e2e 0 FAIL; NetworkPolicy ditegakkan | Tidak ada cluster di lingkungan uji | ⏸ | – |

**Ringkasan:** 36 TC; 30 ✅, 5 ⚠️ (termasuk TC-33 yang awalnya FAIL dan sudah dimitigasi), 0 ❌ terbuka, 1 ⏸. TC-36 wajib dijalankan di cluster dev sebelum go-live prod.

## 3. Traceability matrix

| Requirement | Test case |
|---|---|
| FR-01 | TC-01 |
| FR-02 | TC-01, TC-02 |
| FR-03 | TC-03 |
| FR-04 | TC-04, TC-23 |
| FR-05 | TC-05, TC-06 |
| FR-06 | TC-07 |
| FR-07 | TC-08, TC-09 |
| FR-08 | TC-10 |
| FR-09 | TC-11, TC-32, TC-36 |
| FR-10 | TC-12, TC-36 |
| FR-11 | TC-11, TC-24, TC-27 |
| FR-12 | TC-13 |
| FR-13 | TC-14 |
| FR-14 | TC-15 |
| FR-15 | TC-16 |
| FR-16 | TC-17, TC-21, TC-22 |
| FR-17 | TC-18 |
| FR-18 | TC-19 |
| FR-19 | TC-20 |
| NFR-01 | TC-24, TC-36 |
| NFR-02 | TC-08, TC-09 |
| NFR-03 | TC-25 |
| NFR-04 | TC-26 |
| NFR-05 | TC-27 |
| NFR-06 | TC-28, TC-32 |
| NFR-07 | TC-29, TC-36 |
| NFR-08 | TC-30 |
| NFR-09 | TC-05, TC-06 |
| NFR-10 | TC-31 |
| NFR-11 | TC-33, TC-34 |
| NFR-12 | TC-03, TC-35 |
| NFR-13 | TC-20 |

## 4. Pemeriksaan konsistensi dokumentasi (TC-20)

`scripts/check-docs.sh` memeriksa:
1. setiap FR/NFR di SPEC punya ≥ 1 TC di matriks §3;
2. setiap env var di `k8s/**/configmap.env`, `secretKeyRef` manifest, `docker-compose*.yml`, dan `.env.example` tercantum di [CONFIGURATION.md](CONFIGURATION.md);
3. setiap link relatif markdown (file dan anchor) valid;
4. setiap dokumen SDLC memiliki blok metadata.

Hasil eksekusi terakhir: lihat [test-evidence/2026-09-29/tc-docs-consistency.txt](test-evidence/2026-09-29/tc-docs-consistency.txt).

## 5. Cara mengulang uji

```bash
scripts/build.sh --variant default,arcface-r100-gpu all
cp .env.example .env    # isi POSTGRES_PASSWORD, SECURITY_SIGNINGKEY; set FE_HTTP_PORT bila 8000 dipakai
docker compose up -d --wait                                   # CPU
scripts/e2e-test.sh http://127.0.0.1:${FE_HTTP_PORT:-8000}    # DB kosong → user pertama = OWNER
docker compose down -v
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d --wait   # GPU
# air-gapped core
docker run -d --name core-airgap --network none --read-only --tmpfs /tmp mega/compreface-core:1.2.0
docker exec core-airgap curl -s -F file=@/app/ml/sample_images/000_5.jpg localhost:3000/find_faces
scripts/check-docs.sh
```
