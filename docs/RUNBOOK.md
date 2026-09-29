# Runbook Operasional CompreFace (mega)

| Metadata | |
|---|---|
| Judul | Runbook — operasional harian, health check, scaling, backup/restore, troubleshooting, eskalasi |
| Versi | 1.0.0 |
| Tanggal | 2026-09-29 |
| Owner | Tim Platform / DevOps |
| Status | Review |

| Versi | Tanggal | Penulis | Perubahan |
|---|---|---|---|
| 1.0.0 | 2026-09-29 | Claude Code | Versi awal |

Konvensi: `NS=compreface` (prod) / `compreface-dev`. Untuk compose, ganti `kubectl -n $NS exec deploy/X` dengan `docker compose exec X`.

## 1. Ringkasan komponen

| Service | Kind | Port | Health | Log | Catatan |
|---|---|---|---|---|---|
| compreface-fe | Deployment | 8080 (Svc 80) | `/healthz` | JSON akses nginx | Tidak crash walau backend down (502) |
| compreface-admin | Deployment | 8080, mgmt 8081 | `:8081/actuator/health` | Spring | Menjalankan Liquibase saat start |
| compreface-api | Deployment | 8080, mgmt 8081 | `:8081/actuator/health` | Spring | Cache embedding di heap |
| compreface-core | Deployment | 3000 | `/healthcheck`, `/status` | JSON Python | Prod: GPU, varian `arcface-r100-gpu` |
| compreface-postgres-db | StatefulSet | 5432 | `pg_isready` | Postgres | PVC `data-compreface-postgres-db-0` |

## 2. Operasional harian

| Kapan | Cek | Perintah | Normal |
|---|---|---|---|
| Harian | Status pod | `kubectl -n $NS get pods` | Semua `Running`, READY penuh, RESTARTS tidak bertambah |
| Harian | Event warning | `kubectl -n $NS get events --field-selector type=Warning --sort-by=.lastTimestamp` | Kosong / tidak ada yang baru |
| Harian | Konsistensi api–core–db | `kubectl -n $NS exec deploy/compreface-api -- curl -s localhost:8080/api/v1/consistence/status` | `"status":"OK"` |
| Harian | Backup terakhir | Lihat job/berkas backup (§5) | Sukses < 24 jam, checksum ada |
| Mingguan | Kapasitas PVC | `kubectl -n $NS exec compreface-postgres-db-0 -- df -h /var/lib/postgresql/data` | < 70% |
| Mingguan | Ukuran DB & tabel | `… psql -U "$POSTGRES_USER" -d frs -c "select pg_size_pretty(pg_database_size('frs'))"` | Tren wajar |
| Mingguan | Pemakaian resource | `kubectl -n $NS top pods` (butuh metrics-server) | core < 80% limit memori |
| Bulanan | Uji restore backup | §5.3 di namespace terpisah | Jumlah record sama |
| Harian | Purge gambar orphan | §5.5 | `orphan_img_sesudah` = 0 |
| Bulanan | Review akses & log akses data | [SECURITY §6.2](SECURITY.md#62-kontrol-akses--audit) | – |

## 3. Health check manual

```bash
NS=compreface
kubectl -n $NS exec deploy/compreface-fe    -- curl -s localhost:8080/healthz                       # ok
kubectl -n $NS exec deploy/compreface-admin -- curl -s localhost:8081/actuator/health               # {"status":"UP",...}
kubectl -n $NS exec deploy/compreface-api   -- curl -s localhost:8081/actuator/health/readiness     # UP
kubectl -n $NS exec deploy/compreface-core  -- curl -s localhost:3000/healthcheck                   # {"status":"OK"}
kubectl -n $NS exec deploy/compreface-core  -- curl -s localhost:3000/status                        # calculator_version (prod: insightface.Calculator@arcface-r100-msfdrop75)
kubectl -n $NS exec compreface-postgres-db-0 -- sh -c 'pg_isready -U "$POSTGRES_USER" -h 127.0.0.1'
```
End-to-end (akun OWNER/ADMIN, gambar uji non-nasabah): `scripts/e2e-test.sh https://<host>` → 0 FAIL.

## 4. Scaling core

| Kebutuhan | Tindakan |
|---|---|
| Throughput kurang, resource node tersedia | Naikkan replica: `kubectl -n $NS scale deploy/compreface-core --replicas=N` (varian GPU: N ≤ jumlah GPU yang bisa dijadwalkan). Permanenkan di `overlays/prod/kustomization.yaml` (`replicas`) |
| Per-pod | Naikkan `UWSGI_PROCESSES` **bersama** CPU/memori/VRAM ([CONFIGURATION §7](CONFIGURATION.md#7-sizing-core-uwsgi_processes-vs-resource)). ConfigMap ber-hash → rollout otomatis setelah `kubectl apply -k` |
| Otomatis | Aktifkan `hpa-core.yaml` di overlay prod (butuh metrics-server). Batasi `maxReplicas` sesuai GPU |
| Replica ≥ 2 | Ubah PDB core ke `minAvailable: 1` dan strategi ke `maxSurge: 1 / maxUnavailable: 0` bila ada GPU cadangan |

Setelah scaling: pod baru baru Ready setelah startupProbe (inferensi sample image) sukses, ±25–50 s.

## 5. Backup & restore Postgres

### 5.1 Backup ad-hoc (sebelum upgrade/perubahan)
```bash
TS=$(date +%Y%m%d-%H%M); BK=/secure/backup/compreface; umask 077
kubectl -n $NS exec compreface-postgres-db-0 -- sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc -Z 6' > $BK/frs-$TS.dump
sha256sum $BK/frs-$TS.dump > $BK/frs-$TS.dump.sha256
kubectl -n $NS exec -i compreface-postgres-db-0 -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At -F "|"' \
  < scripts/db-record-counts.sql > $BK/frs-$TS.counts
```
Dump berisi **data biometrik**. Simpan di lokasi terenkripsi dengan akses terbatas, dan terapkan retensi (§5.4).

### 5.2 Backup terjadwal (rekomendasi)
Gunakan solusi backup standar bank (Velero + snapshot CSI terenkripsi, atau CronJob `pg_dump` ke storage terenkripsi). CronJob **harus** mendapat NetworkPolicy tambahan yang mengizinkan pod backup → postgres:5432, karena default-deny. Hal ini belum disediakan di `k8s/` (gap, lihat [SECURITY §9](SECURITY.md#9-gap--rekomendasi)).

### 5.3 Restore
Prosedur yang sama dengan [MIGRATION §5](MIGRATION.md#5-restore-ke-kubernetes--validasi), sudah digladikan ([bukti](test-evidence/2026-09-29/tc-db-restore-rehearsal.txt)):
```bash
kubectl -n $NS scale deploy/compreface-admin deploy/compreface-api --replicas=0
sha256sum -c $BK/frs-<TS>.dump.sha256
kubectl -n $NS exec -i compreface-postgres-db-0 -- sh -c \
  'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists --no-owner --role="$POSTGRES_USER" --exit-on-error' \
  < $BK/frs-<TS>.dump
kubectl -n $NS exec -i compreface-postgres-db-0 -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At -F "|"' \
  < scripts/db-record-counts.sql | diff $BK/frs-<TS>.counts - && echo SAMA
kubectl -n $NS scale deploy/compreface-admin deploy/compreface-api --replicas=2
```
api memuat ulang cache embedding dari DB setelah start.

### 5.4 Retensi backup
Ikuti kebijakan retensi data bank dan [SECURITY §6.3](SECURITY.md#63-retensi--penghapusan). Backup yang melewati retensi dihapus secara aman, dan penghapusannya dicatat.

### 5.5 Purge gambar orphan (hak penghapusan data)
CompreFace 1.2.0 meninggalkan baris `img` (gambar wajah) setelah subject/example dihapus lewat API ([SECURITY S-13](SECURITY.md#9-gap--rekomendasi)). Jalankan setelah setiap permintaan penghapusan data dan secara terjadwal (harian):
```bash
kubectl -n $NS exec -i compreface-postgres-db-0 -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1' \
  < scripts/db-purge-orphan-images.sql        # output: orphan_img_sebelum / orphan_img_sesudah (= 0)
```
Catat hasil (jumlah baris terhapus, waktu, operator) sebagai bukti penghapusan.

## 6. Rotasi password database

1. `kubectl -n $NS exec -it compreface-postgres-db-0 -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'` lalu `ALTER USER <user> PASSWORD '<baru>';`
2. Perbarui Secret `compreface-postgres-credentials` dengan password yang sama.
3. `kubectl -n $NS rollout restart deploy/compreface-admin deploy/compreface-api statefulset/compreface-postgres-db`
4. Verifikasi §3.

Rotasi `SECURITY_SIGNINGKEY`: perbarui Secret, lalu `rollout restart deploy/compreface-admin`.

## 7. Troubleshooting

### 7.1 compreface-ui / fe restart terus
| Gejala | Penyebab | Solusi |
|---|---|---|
| Log `[emerg] host not found in upstream "compreface-core:3000"` (image **lama** `exadel/compreface-fe`) | nginx lama me-resolve upstream statis saat start. Container core tidak ada, nginx exit, lalu restart loop | Pakai `mega/compreface-fe` (resolver dinamis, tanpa route `/core/`, [ADR-004](adr/ADR-004-nginx-envsubst-resolver.md)). Untuk stack compose lama: ganti image fe lewat `docker-compose.override.yml` (port host → `8080`, gunakan `ports: !override`) |
| Image mega: log `nginx: [emerg] ... resolver` | `NGINX_RESOLVER` tidak valid | Kosongkan (auto dari resolv.conf) atau isi IP DNS yang benar |
| Pod fe `CrashLoopBackOff` dengan `Read-only file system` di `/etc/nginx/conf.d` | emptyDir `nginx-conf-d` terhapus dari manifest | Kembalikan volume sesuai base |
| UI terbuka tapi login/API 502 | admin/api belum Ready atau salah upstream | `kubectl -n $NS get endpoints compreface-admin compreface-api`; cek log fe baris `compreface-fe: resolver=… admin=… api=…` (FQDN harus `<svc>.<ns>.svc.cluster.local`) |
| 504 pada recognition | `PROXY_READ_TIMEOUT`/`READ_TIMEOUT` terlalu kecil, atau core kelebihan beban | Scale core (§4); naikkan timeout bila memang wajar |

### 7.2 core gagal start / gagal load model
| Gejala | Penyebab | Solusi |
|---|---|---|
| Container/pod core tidak ada; api error `compreface-core executing GET http://compreface-core:3000/status` | Image `exadel/compreface-core:1.2.0-arcface-r100-gpu` tidak ada di host | Load image `mega/compreface-core:1.2.0-arcface-r100-gpu` dari registry/tarball ([DEPLOYMENT §3](DEPLOYMENT.md#3-transfer-ke-registry-internal)), lalu di direktori compose lama buat `docker-compose.override.yml` berisi `services: {compreface-core: {image: mega/compreface-core:1.2.0-arcface-r100-gpu}}` dan jalankan `docker compose up -d --no-deps compreface-core`. |
| `ModelImportException: Model … does not exists` | Plugin runtime tidak cocok dengan model di image (env plugin di-override) | **Jangan** override `FACE_DETECTION_PLUGIN`/`CALCULATION_PLUGIN`/`EXTRA_PLUGINS` saat runtime. Gunakan tag varian yang benar. Cek `cat /app/ml/.models/MODELS.sha256` |
| Build gagal `Access denied` / `BadZipFile` saat "Checking models" | `MODEL_SOURCE=gdrive` — Google Drive upstream butuh sign-in | Gunakan `MODEL_SOURCE=image` (default) ([ADR-002](adr/ADR-002-model-ml-baked-air-gapped.md)) |
| Build gagal `404 Not Found` dari `deb.debian.org/debian-security` | Repo bullseye EOL | Gunakan `DEBIAN_SNAPSHOT` (default) |
| Pod core `Pending` — `Insufficient nvidia.com/gpu` | GPU habis (replica/rollout `maxSurge`) | Kurangi replica; pastikan strategi prod `maxSurge: 0`; tambah node GPU |
| Log `CUDA … no CUDA-capable device` / inferensi sangat lambat pada varian GPU | GPU tidak ter-expose ke container | Cek device plugin (`kubectl describe node`), `resources.limits.nvidia.com/gpu`, `nvidia-smi` di node |
| Log `failed call to cuInit: UNKNOWN ERROR (303)` pada varian **CPU** | TensorFlow mencoba CUDA | Normal, abaikan |
| startupProbe gagal > 10 menit | Model gagal load / OOM | `kubectl logs --previous`; cek `OOMKilled` (`describe pod`), naikkan memori atau turunkan `UWSGI_PROCESSES` |
| Pod core di-restart saat beban tinggi (liveness) | `/healthcheck` antre di belakang inferensi (`UWSGI_THREADS=1`) | Tambah replica/proses; liveness sudah longgar (5 × 30 s) — jangan diperketat |

### 7.3 admin / api
| Gejala | Penyebab | Solusi |
|---|---|---|
| `/actuator/health` = `DOWN`, log `MailHealthIndicator … AuthenticationFailedException` | Health SMTP aktif padahal email tidak dikonfigurasi (perilaku image upstream) | `MANAGEMENT_HEALTH_MAIL_ENABLED=false` (default image mega) |
| api: `UnsatisfiedLinkError … libjniopenblas_nolapack.so: failed to map segment` saat add/recognize | `/tmp` di-mount `noexec`; ND4J/JavaCPP memuat library native dari `/tmp` | Compose: `tmpfs: /tmp:exec` (sudah di `docker-compose.yml`). K8s: emptyDir (default exec); jangan pasang policy noexec pada `/tmp` api |
| `/actuator/health` di port 8080 api → 400 `Missing header: x-api-key` | Filter api | Gunakan port management 8081 |
| Start lama / crash `Waiting for changelog lock` | Liquibase lock tertinggal (pod mati saat migrasi) | Pastikan tak ada admin lain yang sedang migrasi, lalu `UPDATE databasechangeloglock SET locked=false;` |
| `Action not allowed for current user` saat buat aplikasi | Hanya OWNER/global ADMIN yang boleh | Gunakan akun OWNER (user pertama) atau beri role |
| `OOMKilled` api | Cache embedding > heap/limit | Naikkan limit memori (`MaxRAMPercentage` 75% dari limit) |
| Recognition mengembalikan similarity rendah untuk semua subject | Varian core tidak cocok dengan embedding di DB | Bandingkan `/status` core dengan `select distinct calculator from embedding` ([MIGRATION §8](MIGRATION.md#8-perubahan-model-core-tidak-dalam-scope-cutover)) |

### 7.4 postgres
| Gejala | Penyebab | Solusi |
|---|---|---|
| `initdb: directory … exists but is not empty` | PVC berisi `lost+found` dan `PGDATA` di root volume | `PGDATA=/var/lib/postgresql/data/pgdata` (default image) |
| `Permission denied` di data dir | `fsGroup` hilang / storage tidak mendukung | Pastikan `securityContext.fsGroup: 999` |
| `password authentication failed` setelah ganti Secret | Password hanya diterapkan saat init volume kosong | §6 |
| PVC penuh | Pertumbuhan `img`/`embedding` | Perluas PVC (StorageClass `allowVolumeExpansion`), atau evaluasi retensi |

## 8. Eskalasi

| Level | Kondisi | Pihak | Target respons |
|---|---|---|---|
| L1 | Pod restart sesekali, alert tunggal, 502 sesaat | Operator on-call platform | 15 menit |
| L2 | Layanan recognition down > 15 menit, backup gagal 2× berturut-turut, PVC > 85% | Tim Platform/DevOps (owner dokumen) + pemilik aplikasi | 30 menit |
| L3 | Indikasi kebocoran/akses tidak sah data biometrik, kehilangan data, restore gagal | Tim Keamanan Informasi (CSIRT), DPO, manajemen TI | Segera — ikuti prosedur insiden bank. Kewajiban notifikasi kegagalan pelindungan data pribadi maks. **3×24 jam** (UU PDP Pasal 46) |
| Vendor | Bug aplikasi upstream | Komunitas/Exadel (GitHub issues) — tanpa menyertakan data pribadi | Best effort |

Isi kontak/nomor on-call sesuai direktori internal (tidak dicantumkan di repo).
