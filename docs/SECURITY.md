# Keamanan & Pelindungan Data Pribadi — CompreFace (mega)

| Metadata | |
|---|---|
| Judul | Keamanan — secret, non-root, NetworkPolicy, pelindungan data biometrik (UU PDP / OJK), gap |
| Versi | 1.0.1 |
| Tanggal | 2026-09-29 |
| Owner | Tim Platform / DevOps; review wajib: Keamanan Informasi & DPO |
| Status | Review |

| Versi | Tanggal | Penulis | Perubahan |
|---|---|---|---|
| 1.0.0 | 2026-09-29 | Claude Code | Versi awal (kondisi teknis hasil implementasi & verifikasi Fase 4) |
| 1.0.1 | 2026-09-29 | Claude Code | Temuan sistem berjalan & status/owner gap dipindah ke catatan internal; §9 menjadi checklist |

> Dokumen ini menjelaskan kontrol **teknis** yang diimplementasikan dan gap-nya. Penilaian kepatuhan hukum (UU No. 27/2022 tentang Pelindungan Data Pribadi, ketentuan OJK tentang penyelenggaraan TI oleh bank umum seperti POJK 11/POJK.03/2022, dan kebijakan internal) serta DPIA **wajib** divalidasi oleh Compliance/DPO. Rujukan pasal di bawah bersifat indikatif.

## 1. Klasifikasi data

| Data | Lokasi | Klasifikasi | Dasar |
|---|---|---|---|
| Gambar wajah (`img.content`) | Postgres, tabel `img` (bytea) | **Data Pribadi Spesifik – biometrik** / Rahasia | UU PDP Pasal 4 ayat (2) huruf b |
| Embedding wajah (`embedding.embedding`, 512 dimensi) | Postgres, tabel `embedding`; cache heap api | **Data Pribadi Spesifik – biometrik** (templat biometrik) | idem |
| Nama/ID subject (`subject.subject_name`) | Postgres, tabel `subject` | Data Pribadi (identitas) | Pasal 4 ayat (3) |
| Akun admin (email, nama, hash password) | Postgres, tabel `user` | Data Pribadi / Internal | |
| API key collection, token OAuth | Postgres (`model.api_key`, `oauth_*`) | Rahasia (kredensial) | |
| Gambar pada request recognition/detection | Memori api & core saja (tidak disimpan) | Biometrik, transien | |
| Log aplikasi | stdout → platform logging | Internal (harus bebas data biometrik) | |

Alur data rinci: [ARCHITECTURE §4](ARCHITECTURE.md#4-alur-data-biometrik-uu-pdp).

## 2. Pengelolaan secret

| Kontrol | Implementasi | Bukti |
|---|---|---|
| Tidak ada secret di image | Tidak ada `ENV`/`ARG` berisi credential; `APPERY_API_KEY` upstream dihapus dari image admin | [tc-static-checks](test-evidence/2026-09-29/tc-static-checks.txt): `docker history` & env bersih untuk 6 image |
| Credential dari Secret | `compreface-postgres-credentials`, `compreface-admin-secrets` via `secretKeyRef` | `k8s/base/*/deployment.yaml` |
| Tidak ada secret di git | Hanya `secret.example.yaml` (placeholder) dan `.env.example`; `.env` + `/build/` di `.gitignore`; `.env` root upstream (`postgres/postgres`) dihapus | `git ls-files` |
| Default lemah dihilangkan | Password DB wajib diisi (compose `:?`); user default `compreface`; `security.signing-key` hardcoded upstream di-override `SECURITY_SIGNINGKEY` | `docker-compose.yml`, CONFIGURATION §1 |
| Rotasi | Prosedur di [RUNBOOK §6](RUNBOOK.md#6-rotasi-password-database) | |

## 3. Hardening container & cluster

| Kontrol | fe | admin | api | core | postgres |
|---|---|---|---|---|---|
| User non-root | uid 101 | uid 1001 | uid 1001 | uid 33 | uid 999 (k8s `runAsUser`; compose: gosu dari root) |
| `runAsNonRoot`, `seccompProfile: RuntimeDefault` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `readOnlyRootFilesystem` (emptyDir untuk /tmp dll.) | ✅ | ✅ | ✅ | ✅ | ✅ (diuji ala k8s) |
| `automountServiceAccountToken: false` | ✅ | ✅ | ✅ | ✅ | ✅ |
| Base image di-pin tag + digest | ✅ | ✅ | ✅ | ✅ | ✅ |
| Namespace Pod Security `restricted` | ✅ label `pod-security.kubernetes.io/enforce: restricted` di kedua overlay |

## 4. NetworkPolicy (default deny)

| Policy | Ingress diizinkan | Egress diizinkan |
|---|---|---|
| `default-deny-all` | – | – |
| `allow-dns-egress` | – | semua pod → kube-dns :53 |
| `compreface-fe` | dari namespace ingress controller → :8080 | → admin, api :8080 |
| `compreface-admin` | dari fe → :8080 | → postgres :5432, core :3000 (SMTP: dikomentari, aktifkan bila perlu) |
| `compreface-api` | dari fe → :8080 | → postgres :5432, core :3000 |
| `compreface-core` | dari api, admin, fe (hanya `/status`) → :3000 | **tidak ada** (air-gapped) |
| `compreface-postgres-db` | dari admin, api → :5432 | tidak ada |

Hasilnya: core dan DB tidak bisa dijangkau dari luar namespace, dan **tidak ada egress internet** dari pod mana pun. Route `/core/` (akses core tanpa autentikasi via UI) **dihapus** dari fe, kecuali `GET /core/status` (exact match, method lain 403). UI membutuhkannya untuk cek kesiapan core; isinya hanya status, nama model/plugin, dan versi build — tanpa data wajah. Karena itu NetworkPolicy core mengizinkan ingress dari fe di :3000; pembatasan path ada di nginx fe.

## 5. Telemetry & transfer data ke pihak ketiga

- Upstream mengirim statistik penggunaan ke `api.appery.io` bila `APPERY_API_KEY` terisi. Image resmi `exadel/compreface-admin:1.2.0` membawa key tersebut. **Image mega tidak membawa key** (FR-13), manifest tidak meng-set-nya, dan egress internet diblok NetworkPolicy.
- UI (browser): font Poppins dan Material Icons di-self-host di image fe (`ui/src/assets/fonts/`). Browser pengguna tidak lagi memanggil `fonts.googleapis.com`/`fonts.gstatic.com` — sebelumnya gagal (`ERR_CERT_AUTHORITY_INVALID`) di balik proxy SSL kantor dan membocorkan IP/user-agent pengguna ke Google.
- Core: runtime tanpa koneksi keluar (terverifikasi dengan `--network none`). Model sudah ada di image ([ADR-002](adr/ADR-002-model-ml-baked-air-gapped.md)).
- Tidak ada transfer data pribadi ke luar infrastruktur bank; data dan pemrosesan tetap on-prem di Indonesia.
- Deployment yang masih memakai image upstream `exadel/compreface-admin` harus mengosongkan `APPERY_API_KEY` (env) dan membatasi egress host. Temuan terkait sistem berjalan dicatat di catatan internal.

## 6. Pelindungan data biometrik (UU PDP)

### 6.1 Enkripsi
| Aspek | Status | Keterangan |
|---|---|---|
| In-transit: klien → cluster | ✅ **wajib** TLS di ingress (`ingress.example.yaml`) | Sertifikat PKI internal |
| In-transit: di dalam cluster (fe→api, api→core, api/admin→postgres) | ⚠️ **Gap** — HTTP/JDBC plain | Mitigasi: NetworkPolicy + namespace terisolasi. Rekomendasi: service mesh mTLS (Istio/Linkerd) atau TLS Postgres (`sslmode=require`, sertifikat server) |
| At-rest: volume Postgres | ⚠️ **Prasyarat infrastruktur** — StorageClass terenkripsi (`encrypted-block` placeholder) | Harus dikonfirmasi tim storage |
| At-rest: kolom `img`/`embedding` | ❌ **Gap** — tidak dienkripsi di level aplikasi | Butuh perubahan kode (pgcrypto/enkripsi aplikasi). Di luar scope |
| At-rest: backup/dump | ⚠️ Prosedural — simpan di lokasi terenkripsi, `umask 077` ([RUNBOOK §5](RUNBOOK.md#5-backup--restore-postgres)) | |

### 6.2 Kontrol akses & audit
| Aspek | Status |
|---|---|
| Akses API | Per collection via `x-api-key`; role user OWNER/ADMIN/USER ([upstream](upstream/User-Roles-System.md)) |
| Akses UI admin | Login + cookie `HttpOnly` (`CFSESSION`, path `/admin`). ⚠️ Cookie **tanpa atribut `Secure`**, sehingga TLS wajib di ingress |
| Akses cluster | RBAC Kubernetes (di luar repo): batasi `exec`/`port-forward` ke pod postgres, api, dan core hanya untuk peran operasional terotorisasi, dengan audit log API server aktif |
| Audit log akses data | ⚠️ **Gap parsial** — aplikasi tidak mencatat siapa mengakses/mengenali subject apa. Tersedia: log akses nginx (JSON, tanpa query string, tanpa body), log Kubernetes audit. Rekomendasi: audit log di API gateway/ingress (identitas klien = API key/aplikasi) dan retensi sesuai kebijakan |
| Log bebas data biometrik | Request log uWSGI dimatikan; nginx tidak mencatat query/body; `LOGGING_LEVEL_COM_EXADEL=INFO` di prod. ⚠️ Konfigurasi compose lama yang memakai `DEBUG` + `CommonsRequestLoggingFilter` **jangan** dipakai di prod |

### 6.3 Retensi & penghapusan
| Aspek | Mekanisme |
|---|---|
| Hapus data subject (hak subjek data, UU PDP Pasal 8 & 43) | `DELETE /api/v1/recognition/subjects/<subject>` (x-api-key collection) → hapus subject + embedding. ⚠️ **Bug upstream 1.2.0 (terverifikasi):** baik endpoint ini maupun `DELETE /api/v1/recognition/faces?subject=` **meninggalkan gambar wajah di tabel `img`** ([bukti](test-evidence/2026-09-29/tc-subject-deletion.txt); penyebab: `SubjectDao.deleteSubjectByName` menghapus embedding sebelum query hapus `img` yang join ke embedding). **Wajib** jalankan [`scripts/db-purge-orphan-images.sql`](../scripts/db-purge-orphan-images.sql) setelah penghapusan (atau terjadwal harian) — [RUNBOOK §5.5](RUNBOOK.md#55-purge-gambar-orphan-hak-penghapusan-data). Verifikasi: `select count(*) from img i where not exists (select 1 from embedding e where e.img_id=i.id)` = 0. |
| Retensi | ⚠️ Tidak ada penghapusan otomatis di aplikasi. Harus ditetapkan pemilik proses bisnis (mis. penghapusan saat hubungan nasabah berakhir) dan dijalankan via API/job terjadwal |
| Minimisasi | Pertimbangkan `SAVE_IMAGES_TO_DB=false` bila gambar asli tidak diperlukan. Trade-off: tanpa gambar, embedding tidak dapat dihitung ulang saat ganti model ([MIGRATION §8](MIGRATION.md#8-perubahan-model-core-tidak-dalam-scope-cutover)) |
| Backup | Data yang dihapus masih ada di backup sampai backup kedaluwarsa; retensi backup harus selaras dengan kebijakan |
| Dekomisioning | Hapus PVC/volume dan dump dengan berita acara ([MIGRATION §9](MIGRATION.md#9-pasca-migrasi)) |

## 7. Supply chain

- Base image dan sumber model di-pin **digest**, dan apt dikunci ke snapshot Debian.
- Label OCI `revision` = commit git. Digest hasil push dicatat (`build/digests.txt`).
- Checksum model di image: `/app/ml/.models/MODELS.sha256`.
- Transfer air-gapped memakai `SHA256SUMS` ([DEPLOYMENT §3](DEPLOYMENT.md#3-transfer-ke-registry-internal)).
- ⚠️ Belum ada vulnerability scan, SBOM, atau signing image di pipeline (gap §9).

## 8. Komponen EOL (risiko R-03)

| Komponen | Versi | Status |
|---|---|---|
| Python | 3.8 | EOL Okt 2024 |
| TensorFlow | 2.2 | EOL |
| Debian | 11 bullseye (core CPU) | LTS berakhir Agu 2026 |
| Ubuntu | 20.04 (core GPU, JRE admin/api) | Standard support berakhir Mei 2025 |
| Node.js | 12 (hanya stage build fe) | EOL |
| nginx | 1.21.1 | Tidak lagi dipelihara |
| PostgreSQL | 11 | EOL Nov 2023 |
| Spring Boot | 2.5 | EOL |
| Angular | 11 | EOL |

Upgrade memerlukan perubahan kode upstream dan berada di luar scope proyek ini.

## 9. Gap & rekomendasi

Checklist kontrol yang harus dipastikan sebelum go-live, berdasarkan desain teknis repo ini dan perilaku upstream CompreFace 1.2.0. Status, tingkat risiko, dan owner per lingkungan dikelola di **register gap internal** (catatan internal bagian E), bukan di repo.

| # | Area | Rekomendasi |
|---|---|---|
| S-01 | Tidak ada TLS/mTLS di dalam cluster | Service mesh mTLS atau TLS Postgres + HTTPS internal |
| S-02 | Enkripsi at-rest bergantung StorageClass; kolom biometrik tidak dienkripsi | Konfirmasi StorageClass terenkripsi; evaluasi enkripsi level aplikasi |
| S-03 | Tidak ada audit log akses data per subject | Audit di ingress/API gateway + log aplikasi pemanggil; SIEM |
| S-04 | OAuth client SPA `CommonClientId:password` hardcoded di bundle FE (public client) | Terima sebagai public client, atau ubah source FE + admin untuk rotasi |
| S-05 | Komponen EOL (§8) | Proyek upgrade terpisah; scan CVE rutin |
| S-06 | Belum ada scan CVE / SBOM / signing image | Trivy/Grype + Syft + cosign di pipeline build; kebijakan admission |
| S-07 | Backup terjadwal & NetworkPolicy untuk backup belum tersedia | Velero/CronJob + policy khusus |
| S-08 | Tidak ada retensi otomatis data biometrik | Tetapkan kebijakan retensi & job penghapusan |
| S-09 | Cookie admin tanpa `Secure` | Wajib TLS; tambah `proxy_cookie_flags` di ingress bila didukung |
| S-10 | File `.env` upstream lama di `dev/` & `custom-builds/` berisi kredensial default `postgres` | Tidak dipakai alur baru; jangan dipakai di lingkungan nyata |
| S-11 | Header CORS `Access-Control-Allow-Origin: *` untuk `/api/v1` (perilaku upstream) | Batasi origin di ingress sesuai aplikasi pemanggil |
| S-12 | DPIA belum dilakukan | DPIA oleh DPO sebelum go-live (UU PDP Pasal 34) |
| S-13 | Hapus subject meninggalkan gambar wajah (`img` orphan) — bug upstream | Mitigasi operasional: `scripts/db-purge-orphan-images.sql` terjadwal + setelah setiap penghapusan. Perbaikan permanen: patch `SubjectDao` (hapus `img` sebelum `embedding`) & kontribusi ke upstream |
