# Rencana Migrasi: docker compose → Kubernetes

| Metadata | |
|---|---|
| Judul | Rencana Migrasi CompreFace dari docker compose (host tunggal) ke Kubernetes |
| Versi | 1.0.1 |
| Tanggal | 2026-09-29 |
| Owner | Tim Platform / DevOps |
| Status | Review — **belum dieksekusi** (eksekusi cutover di luar scope proyek ini) |

| Versi | Tanggal | Penulis | Perubahan |
|---|---|---|---|
| 1.0.0 | 2026-09-29 | Claude Code | Versi awal |
| 1.0.1 | 2026-09-29 | Claude Code | Detail sistem berjalan (host, endpoint, kredensial, perbaikan & temuan) dipindah ke catatan internal; §1 menjadi template |

Terkait: [DEPLOYMENT](DEPLOYMENT.md) · [RUNBOOK §5](RUNBOOK.md#5-backup--restore-postgres) · [SECURITY](SECURITY.md) · [SPEC](../SPEC.md) FR-17, R-01, R-08

## 1. Kondisi sumber (as-is)

Detail sistem compose yang sedang berjalan (host, direktori & nama project compose, endpoint/port, kredensial, nama volume, jumlah record, perbaikan sementara yang sudah diterapkan, dan temuan keamanan) **sengaja tidak dicantumkan di repo** dan dicatat di **catatan internal** (bagian A, C, D, F). Isi tabel berikut dari catatan internal sebelum eksekusi:

| Item | Nilai (isi dari catatan internal) |
|---|---|
| Host & resource | … |
| Direktori / nama project compose | … |
| Image yang berjalan | `exadel/compreface-*:1.2.0` + override `mega/*` (bila sudah diterapkan) |
| Endpoint klien (api & UI) | … |
| DB | PostgreSQL **11.5**, DB `frs`, user, nama volume, `PGDATA=/var/lib/postgresql/data`, ukuran |
| Varian core / model embedding | `insightface.Calculator@arcface-r100-msfdrop75` |

Jumlah record acuan diambil dengan [`scripts/db-record-counts.sql`](../scripts/db-record-counts.sql) (read-only) dan **wajib dihitung ulang saat cutover** (§4.2).

## 2. Target (to-be)

- Namespace `compreface`, overlay `k8s/overlays/prod`, image `mega/compreface-*:1.2.0` + core **`1.2.0-arcface-r100-gpu`**. Model identik dengan sumber; embedding kompatibel, cosine similarity 0,999992 ([bukti](test-evidence/2026-09-29/tc-embedding-compat.txt)). **Tidak perlu recalculation embedding.**
- PostgreSQL 11.5 (major sama, sehingga `pg_dump`/`pg_restore` aman), StatefulSet + PVC terenkripsi.
- Kredensial DB baru (bukan kredensial default) dari Secret.
- Endpoint klien: `https://<host-ingress>/api/v1/...` (via fe). Path API sama; **host/port berubah**. API key collection (`model.api_key`) ikut termigrasi, sehingga klien **tidak** perlu API key baru.

Perbedaan yang memengaruhi migrasi:

| Aspek | Compose lama | Kubernetes | Dampak |
|---|---|---|---|
| `PGDATA` | `/var/lib/postgresql/data` | `/var/lib/postgresql/data/pgdata` | Volume lama **tidak bisa** dipasang langsung, harus lewat dump/restore |
| User DB | superuser default | dari Secret (mis. `compreface`, superuser pada DB baru) | Restore dengan `--no-owner --role` |
| Route `/core/` via UI | ada (image fe upstream) | dihapus | Klien yang memanggil `/core/` harus pindah ke api |
| api expose langsung (bypass UI) | ya | tidak (lewat fe/ingress) | Ubah base URL klien |

## 3. Persiapan (H-7 s.d. H-1)

1. **Build & transfer image** ke registry internal ([DEPLOYMENT §2–3](DEPLOYMENT.md#2-build-mesin-berinternet)). Catat digest.
2. **Siapkan cluster**: namespace, Secret ([DEPLOYMENT §4](DEPLOYMENT.md#4-buat-secret)), storage class terenkripsi, node GPU, ingress + sertifikat TLS, NetworkPolicy aktif.
3. **Gladi (dry-run) di dev/staging**: lakukan seluruh langkah §4–§5 memakai dump produksi di namespace terpisah. Hapus data sesudahnya sesuai prosedur penghapusan data pribadi, karena dump berisi data biometrik. Catat durasi aktual untuk menetapkan window.
4. **Inventaris klien**: daftar aplikasi pemanggil endpoint api & UI lama, PIC, dan cara mengganti base URL.
5. **Persetujuan**: CAB/change request, persetujuan DPO/Compliance terkait pemindahan data biometrik antar-sistem (UU PDP), dan jadwal window.
6. Pastikan media/lokasi penyimpanan dump **terenkripsi** dengan akses terbatas.

## 4. Backup sumber

Dump dibuat saat **write freeze**: api dan admin dihentikan sehingga tidak ada penulisan baru.

```bash
REPO=/path/ke/repo-ini       # berisi scripts/db-record-counts.sql
TS=$(date +%Y%m%d-%H%M)
BK=/secure/backup/compreface-$TS; mkdir -p $BK && chmod 700 $BK

# 4.1 freeze penulisan
docker stop compreface-api compreface-admin compreface-ui

# 4.2 hitung record sumber (acuan validasi) — scripts/db-record-counts.sql
docker exec -i compreface-postgres-db psql -U postgres -d frs -At -F '|' \
  < $REPO/scripts/db-record-counts.sql > $BK/counts-source.txt

# 4.3 dump (format custom, terkompresi) + checksum + cek TOC
docker exec compreface-postgres-db pg_dump -U postgres -d frs -Fc -Z 6 > $BK/frs.dump
sha256sum $BK/frs.dump > $BK/frs.dump.sha256
docker exec -i compreface-postgres-db pg_restore -l < $BK/frs.dump | grep -c 'TABLE DATA'   # > 0
```
Simpan juga snapshot volume/VM bila tersedia (lapisan cadangan kedua).

## 5. Restore ke Kubernetes & validasi

```bash
NS=compreface
# 5.1 deploy seluruh stack, lalu tahan admin & api agar tidak ada penulisan / migrasi saat restore
kubectl apply -k k8s/overlays/prod
kubectl -n $NS scale deploy/compreface-admin deploy/compreface-api --replicas=0
kubectl -n $NS rollout status statefulset/compreface-postgres-db --timeout=5m

# 5.2 restore (stream dari mesin operator; tidak menyalin file dump ke pod)
sha256sum -c $BK/frs.dump.sha256
kubectl -n $NS exec -i compreface-postgres-db-0 -- sh -c \
  'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists --no-owner --role="$POSTGRES_USER" --exit-on-error' \
  < $BK/frs.dump
```
`--clean --if-exists` menghapus objek yang mungkin sudah dibuat Liquibase bila admin sempat start sebelum di-scale ke 0, sehingga hasil restore identik dengan sumber.

```bash
# 5.3 hitung record target dengan query yang sama, bandingkan
kubectl -n $NS exec -i compreface-postgres-db-0 -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At -F "|"' \
  < $REPO/scripts/db-record-counts.sql > $BK/counts-target.txt
diff $BK/counts-source.txt $BK/counts-target.txt && echo "VALIDASI JUMLAH RECORD: SAMA"

# 5.4 nyalakan kembali admin & api (Liquibase melihat changelog dari dump → tidak ada perubahan skema)
kubectl -n $NS scale deploy/compreface-admin deploy/compreface-api --replicas=2
kubectl -n $NS rollout status deploy/compreface-admin --timeout=10m
kubectl -n $NS rollout status deploy/compreface-api --timeout=10m
kubectl -n $NS logs deploy/compreface-admin | grep -i liquibase | tail -5     # tidak ada ChangeSet baru yang "ran"

# 5.5 validasi fungsional
kubectl -n $NS exec deploy/compreface-core -- curl -s http://127.0.0.1:3000/status   # calculator = arcface-r100-msfdrop75
kubectl -n $NS exec deploy/compreface-api -- curl -s http://127.0.0.1:8080/api/v1/consistence/status
```
Validasi recognition memakai **collection uji** yang disetujui (bukan wajah nasabah acak): recognize satu gambar referensi dan pastikan subject yang benar kembali dengan similarity ≥ threshold operasional. Setelah itu jalankan `scripts/e2e-test.sh` terhadap ingress; skrip membuat app/collection uji sendiri dan menghapus subject ujinya.

## 6. Cutover, downtime window & go/no-go

### 6.1 Timeline (estimasi; kalibrasi dengan gladi §3.3)

| T | Langkah | Estimasi |
|---|---|---|
| T-30 m | Stack k8s sudah ter-deploy dan kosong (§5.1 tanpa restore), smoke test lulus | – |
| T0 | Umumkan mulai window; write freeze (§4.1) | 2 m |
| T0+2 | Count + dump + checksum (ukuran DB, lihat catatan internal) | 5–10 m |
| T0+12 | Restore + count target + diff | 10–15 m |
| T0+27 | Start admin/api, validasi fungsional & e2e | 10 m |
| T0+37 | **Go/No-go** | 5 m |
| T0+42 | Alihkan klien (DNS/LB/base URL) ke ingress | 5–15 m |
| T0+60 | Monitoring intensif 60 menit, window ditutup | – |

**Downtime window yang diusulkan: 90 menit**, di luar jam operasional. Bila stack lama sedang melayani recognition, downtime berdampak langsung ke aplikasi pemanggil; koordinasikan dengan pemilik aplikasi.

### 6.2 Kriteria Go / No-go

| # | Kriteria | Go bila |
|---|---|---|
| G1 | Checksum dump | `sha256sum -c` OK |
| G2 | Jumlah record per tabel & per `calculator` | `diff` kosong (selisih = 0) |
| G3 | Pod | Semua Running/Ready, restart 0, tidak ada event Warning baru |
| G4 | Varian core | `/status` → `insightface.Calculator@arcface-r100-msfdrop75` |
| G5 | Konsistensi | `/api/v1/consistence/status` → `OK`, `dbIsInconsistent: false` |
| G6 | Recognition collection uji | Subject benar, similarity ≥ threshold |
| G7 | `scripts/e2e-test.sh` | 0 FAIL |
| G8 | Liquibase | Tidak ada ChangeSet baru dieksekusi |
| G9 | Keamanan | TLS aktif di ingress, NetworkPolicy terpasang, Secret bukan default |

Satu saja kriteria gagal dan tidak bisa diperbaiki dalam 15 menit → **No-go** → rollback §7.

## 7. Rollback plan

Stack compose lama **tidak dihapus** dan volume lama tidak disentuh selama minimal 14 hari setelah cutover.

| Kapan | Langkah |
|---|---|
| Sebelum klien dialihkan (No-go) | `docker start compreface-admin compreface-api compreface-ui` di host lama. Umumkan window selesai tanpa perubahan. Scale deployment k8s ke 0 atau hapus namespace, lalu hapus PVC & dump sesuai prosedur penghapusan data |
| Setelah klien dialihkan, ada data baru di k8s | 1) freeze k8s (scale admin/api ke 0); 2) `pg_dump` dari k8s; 3) restore ke **DB compose baru**. Dump k8s tidak bisa ditimpa ke volume lama secara aman selama user/owner berbeda: restore dengan `pg_restore --clean --if-exists --no-owner --role=postgres` ke `frs`; 4) validasi jumlah record; 5) start stack lama; 6) kembalikan base URL klien |
| Kapan tidak bisa rollback murni | Setelah stack lama dihapus (≥ H+14). Rollback kemudian = restore backup terbaru ke k8s ([RUNBOOK §5](RUNBOOK.md#5-backup--restore-postgres)) |

Catatan: bila stack lama memakai `docker-compose.override.yml` (lihat catatan internal), pertahankan file tersebut selama rollback masih mungkin. Troubleshooting: [RUNBOOK §7.1–7.2](RUNBOOK.md#71-compreface-ui--fe-restart-terus).

## 8. Perubahan model core (tidak dalam scope cutover)

Jika suatu saat model diganti (mis. ke FaceNet atau model lain), embedding lama **tidak kompatibel**:
1. Pastikan `SAVE_IMAGES_TO_DB=true` sejak awal (gambar ada di tabel `img`). Kondisi produksi: lihat catatan internal.
2. Deploy core model baru, lalu gunakan fitur migrasi upstream `POST /api/v1/migrate` untuk menghitung ulang embedding dari `img` (lihat [docs/upstream/Face-data-migration.md](upstream/Face-data-migration.md)).
3. Perlakukan sebagai rilis MAJOR ([ADR-005](adr/ADR-005-varian-core.md)), dengan backup, gladi, dan window tersendiri.

## 9. Pasca-migrasi

- Hapus dump dan salinan sementara setelah retensi backup terpenuhi, lalu catat penghapusannya (audit UU PDP).
- Aktifkan backup terjadwal di k8s ([RUNBOOK §5](RUNBOOK.md#5-backup--restore-postgres)).
- H+14: dekomisioning stack compose lama. Hapus volume data compose lama dengan persetujuan dan berita acara penghapusan data.
