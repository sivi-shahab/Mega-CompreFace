# Monitoring CompreFace (Prometheus + Grafana, docker compose)

| Metadata | |
|---|---|
| Judul | Monitoring stack `mega/compreface-*` dengan Prometheus, Grafana, dan exporter |
| Versi | 1.1.0 |
| Tanggal | 2026-10-01 |
| Owner | Tim Platform / DevOps |
| Status | Aktif |

| Versi | Tanggal | Penulis | Perubahan |
|---|---|---|---|
| 1.0.0 | 2026-10-01 | Claude Code | Versi awal |
| 1.1.0 | 2026-10-01 | Claude Code | Alertmanager untuk notifikasi (email / Teams / webhook) |

Terkait: [RUNNING](RUNNING.md) · [RUNBOOK](RUNBOOK.md) · [CONFIGURATION](CONFIGURATION.md)

## 1. Arsitektur

`docker-compose.monitoring.yml` adalah override opsional. Service-nya bergabung ke network project yang sama (`compreface_default`), jadi Prometheus bisa menjangkau admin, api, core, dan postgres lewat nama service tanpa membuka port tambahan.

| Service | Image (default) | Fungsi | Port host |
|---|---|---|---|
| `prometheus` | `prom/prometheus:v3.5.0` | Scrape metrik tiap 15 s dan evaluasi alert, retensi 15 hari / 10 GB | `127.0.0.1:9090` |
| `alertmanager` | `prom/alertmanager:v0.28.1` | Routing, grouping, dan pengiriman notifikasi alert | `127.0.0.1:9093` |
| `grafana` | `grafana/grafana:12.1.1` | Dashboard "CompreFace — Overview" (ter-provision, jadi halaman utama) | `3000` |
| `cadvisor` | `gcr.io/cadvisor/cadvisor:v0.55.1` | CPU, RAM vs limit, network, dan restart per container | – |
| `node-exporter` | `prom/node-exporter:v1.9.1` | CPU, RAM, disk, dan load host | – |
| `gpu-exporter` | `utkuozdemir/nvidia_gpu_exporter:1.3.2` | Utilisasi GPU dan VRAM (via `nvidia-smi`) | – |
| `postgres-exporter` | `quay.io/prometheuscommunity/postgres-exporter:v0.17.1` | Koneksi, TPS, ukuran DB, cache hit | – |
| `blackbox-exporter` | `prom/blackbox-exporter:v0.27.0` | Probe health endpoint aplikasi | – |

Health check yang di-probe (`monitoring/prometheus/prometheus.yml`, job `health`):

| Service | Target | Dianggap sehat bila |
|---|---|---|
| fe | `http://compreface-fe:8080/` | HTTP 2xx |
| admin | `http://compreface-admin:8081/actuator/health` | body `"status":"UP"` |
| api | `http://compreface-api:8081/actuator/health` | body `"status":"UP"` |
| core | `http://compreface-core:3000/healthcheck` | body `"status":"OK"` |
| postgres | `compreface-postgres-db:5432` | koneksi TCP berhasil |

Alasan pemilihan komponen:

- **Probe health, bukan metrik JVM.** Image admin dan api belum menyertakan `micrometer-registry-prometheus`, sehingga `/actuator/prometheus` tidak tersedia. Bila nanti ditambahkan, cukup tambah job scrape ke `compreface-admin:8081` dan `compreface-api:8081`.
- **`nvidia_gpu_exporter`, bukan DCGM.** GPU host ini vGPU (L40S-24Q). Exporter berbasis `nvidia-smi` sudah terbukti mengeluarkan metrik utilisasi dan VRAM. Daya dan suhu memang tidak diteruskan ke guest vGPU, jadi panel "Daya & suhu" kosong.
- **cAdvisor ≥ v0.55.** Pada Docker 29 dengan containerd snapshotter, v0.52 gagal membaca container (`failed to identify the read-write layer ID`) sehingga metrik per container kosong.

## 2. Menjalankan

```bash
cd /data/CompreFace
# 1. password admin Grafana (sekali saja; .env tidak di-commit)
grep -q '^GRAFANA_ADMIN_PASSWORD=.\+' .env || \
  echo "GRAFANA_ADMIN_PASSWORD=$(openssl rand -base64 18 | tr -d '/+=')" >> .env

# 2. tambahkan override ke COMPOSE_FILE di .env
sed -i 's|^COMPOSE_FILE=.*|COMPOSE_FILE=docker-compose.yml:docker-compose.gpu.yml:docker-compose.monitoring.yml|' .env

# 3. jalankan HANYA service monitoring — container CompreFace tidak di-recreate
docker compose up -d --no-deps prometheus alertmanager grafana cadvisor node-exporter gpu-exporter postgres-exporter blackbox-exporter
```

Setelah `COMPOSE_FILE` diubah, `docker compose up -d` biasa juga ikut menjalankan monitoring. Agar perubahan konfigurasi CompreFace tidak ikut ter-deploy secara tak sengaja, gunakan `--no-deps <service>` saat hanya menyentuh monitoring.

Akses:

- Grafana: `http://<host>:3000`, user `admin`, password dari `GRAFANA_ADMIN_PASSWORD`. Dashboard **CompreFace — Overview** langsung terbuka.
- Prometheus (target, alert, query ad-hoc): hanya dari host, atau lewat tunnel `ssh -L 9090:localhost:9090 <host>`, lalu buka `http://localhost:9090`.
- Alertmanager (alert aktif, silence): sama, via `ssh -L 9093:localhost:9093 <host>`, lalu buka `http://localhost:9093`.

Bila `GRAFANA_ADMIN_PASSWORD` diubah setelah Grafana pertama kali jalan, nilai baru tidak berlaku karena password tersimpan di volume `compreface_grafana-data`. Reset dengan:

```bash
docker compose exec grafana grafana cli admin reset-admin-password '<password-baru>'
```

## 3. Dashboard "CompreFace — Overview"

File: `monitoring/grafana/dashboards/compreface-overview.json`. Disimpan read-only (`allowUiUpdates: false`). Ubah file ini lalu restart Grafana. Perubahan lewat UI harus di-export ke file ini supaya tidak hilang.

| Baris | Isi |
|---|---|
| Status layanan | UP/DOWN tiap service, jumlah alert aktif, gauge GPU & VRAM, latensi health check, restart container |
| Alerting | Tabel alert yang sedang menyala (alert, service, severity, target), jumlah alert di Alertmanager, alert yang diredam dan silence aktif, notifikasi gagal 24 jam, status config Alertmanager, notifikasi terkirim/gagal per kanal, riwayat alert per severity |
| Container | CPU (core), memory working set, memory vs `mem_limit`, network rx/tx per service |
| GPU | Utilisasi, VRAM terpakai/total, daya & suhu (kosong di vGPU) |
| PostgreSQL | Koneksi per state vs `max_connections`, commit/rollback per detik, ukuran DB, cache hit ratio, rows |
| Host | CPU & iowait, RAM, % disk terpakai per mount (termasuk `/data`) |

## 4. User PostgreSQL khusus monitoring (disarankan)

Secara default exporter memakai user aplikasi. Untuk prinsip least-privilege, buat user ber-role `pg_monitor`:

```bash
PW=$(openssl rand -base64 18 | tr -d '/+=')
docker compose exec -T compreface-postgres-db psql -U compreface -d frs -v pw="$PW" <<'SQL'
CREATE ROLE monitoring LOGIN PASSWORD :'pw';
GRANT pg_monitor TO monitoring;
SQL
printf 'POSTGRES_EXPORTER_USER=monitoring\nPOSTGRES_EXPORTER_PASSWORD=%s\n' "$PW" >> .env
docker compose up -d --no-deps postgres-exporter
```

## 5. Operasional

```bash
# status & resource
docker compose ps prometheus alertmanager grafana cadvisor node-exporter gpu-exporter postgres-exporter blackbox-exporter
# validasi konfigurasi sebelum reload
docker compose exec prometheus promtool check config /etc/prometheus/prometheus.yml
# reload prometheus.yml / alerts.yml tanpa restart
curl -X POST http://127.0.0.1:9090/-/reload
# mematikan monitoring saja (data metrik tetap di volume)
docker compose stop prometheus alertmanager grafana cadvisor node-exporter gpu-exporter postgres-exporter blackbox-exporter
```

Konsumsi resource yang terukur saat idle: total ±180 MiB RAM dan CPU < 1%. Disk Prometheus kira-kira 1–2 GB untuk retensi 15 hari, dibatasi `PROMETHEUS_RETENTION_SIZE`.

Host air-gapped: tarik image di mesin berinternet, `docker save`, transfer, `docker load`, atau push ke registry internal dan isi `MON_REGISTRY` (lihat [DEPLOYMENT §3](DEPLOYMENT.md#3-transfer-ke-registry-internal)). Grafana dikonfigurasi agar tidak memanggil internet (analytics, update check, news feed dimatikan).

## 6. Alert & notifikasi

Aturan alert ada di `monitoring/prometheus/alerts.yml` dan dievaluasi Prometheus. Alert yang menyala dikirim ke Alertmanager, yang mengelompokkan lalu meneruskannya ke kanal notifikasi.

### 6.1 Mengaktifkan kanal

Config Alertmanager dibuat saat container start oleh `monitoring/alertmanager/entrypoint.sh` dari variabel `ALERT_*` di `.env`. Kanal aktif bila variabelnya terisi, dan boleh lebih dari satu. **Tanpa kanal**, alert tetap terkumpul dan terlihat di UI Alertmanager, tapi tidak dikirim ke mana pun. Ini kondisi default.

| Kanal | Variabel wajib | Opsional |
|---|---|---|
| Email (SMTP) | `ALERT_EMAIL_TO` (pisahkan dengan koma), `ALERT_SMTP_SMARTHOST` (`host:port`) | `ALERT_EMAIL_FROM`, `ALERT_SMTP_USERNAME` + `ALERT_SMTP_PASSWORD`, `ALERT_SMTP_REQUIRE_TLS` (default `true`; isi `false` untuk relay internal tanpa STARTTLS) |
| Microsoft Teams | `ALERT_MSTEAMS_WEBHOOK_URL` (URL webhook dari Workflows / Power Automate) | – |
| Webhook generik | `ALERT_WEBHOOK_URL`, menerima POST JSON [format Alertmanager](https://prometheus.io/docs/alerting/latest/configuration/#webhook_config), mis. untuk ITSM/tiket | – |

```bash
# contoh: email lewat relay SMTP internal
cat >> .env <<'ENV'
ALERT_EMAIL_TO=noc@contoh.co.id,platform@contoh.co.id
ALERT_EMAIL_FROM=CompreFace Alert <compreface-alert@contoh.co.id>
ALERT_SMTP_SMARTHOST=smtp-relay.contoh.internal:25
ALERT_SMTP_REQUIRE_TLS=false
ENV
docker compose up -d --no-deps alertmanager
docker compose logs alertmanager | grep kanal     # → "kanal notifikasi aktif: email"
```

URL webhook dan password SMTP ditulis ke file di tmpfs container lalu dirujuk dengan `*_file`, sehingga tidak muncul di config yang tampil di UI.

Alertmanager juga terdaftar sebagai datasource Grafana (`uid: alertmanager`, `monitoring/grafana/provisioning/datasources/datasources.yml`). Di Grafana, buka **Alerting → Alert groups** atau **Silences**, lalu pilih datasource **Alertmanager** di kanan atas. Dengan begitu alert bisa dilihat dan di-silence dari browser tanpa SSH tunnel ke port 9093. Hak membuat silence mengikuti role Grafana: Editor/Admin.

### 6.2 Uji kirim notifikasi

```bash
docker compose exec alertmanager amtool alert add TestNotifikasi severity=warning service=uji-coba \
  --annotation='summary="Uji notifikasi Alertmanager"' --alertmanager.url=http://localhost:9093
# notifikasi tiba ±30 s kemudian (group_wait). Alert uji hilang sendiri setelah resolve_timeout 5 menit.
```

### 6.3 Routing

- Alert dikelompokkan per `alertname` + `service`, dengan `group_wait` 30 s dan `group_interval` 5 m.
- Pengingat dikirim ulang selama alert masih menyala: **critical** tiap `ALERT_CRITICAL_REPEAT_INTERVAL` (default 1h), **warning** tiap `ALERT_REPEAT_INTERVAL` (default 4h). Notifikasi *resolved* juga dikirim.
- Inhibit: saat `ServiceDown` menyala, warning lain untuk service yang sama diredam. `PostgresDown` meredam `PostgresConnectionsHigh` dan `ScrapeTargetDown`.
- Silence (misalnya saat maintenance): lewat UI Alertmanager, atau `amtool silence add service=compreface-core --duration=2h --comment=maintenance --alertmanager.url=http://localhost:9093`. Silence tersimpan di volume `compreface_alertmanager-data`.

### 6.4 Daftar alert

| Alert | Kondisi | Severity |
|---|---|---|
| `ServiceDown` | Health check gagal > 2 menit | critical |
| `PostgresDown` | `pg_up == 0` > 1 menit | critical |
| `ServiceSlowHealthcheck` | Probe > 2 s selama 5 menit | warning |
| `AlertmanagerNotificationsFailing` | Pengiriman notifikasi ke suatu kanal gagal > 10 menit | warning |
| `ScrapeTargetDown` | Exporter tidak bisa di-scrape > 2 menit | warning |
| `ContainerMemoryNearLimit` | Working set > 90% `mem_limit` selama 5 menit (risiko OOMKilled) | warning |
| `ContainerRestarted` | Container start ulang dalam 15 menit terakhir | warning |
| `GpuMemoryHigh` | VRAM > 90% selama 10 menit | warning |
| `GpuExporterNoData` | Tidak ada metrik GPU > 5 menit | warning |
| `PostgresConnectionsHigh` | Koneksi > 80% `max_connections` | warning |
| `HostDiskSpaceLow` | Sisa disk < 10% | warning |
| `HostMemoryLow` | RAM tersedia < 10% | warning |

## 7. Keamanan

- Hanya Grafana yang terbuka ke jaringan (port 3000). Sign-up dan akses anonim dimatikan. Bila diakses dari luar segmen admin, batasi dengan firewall atau taruh di belakang reverse proxy TLS, lalu set `GRAFANA_COOKIE_SECURE=true`.
- Prometheus, Alertmanager, dan exporter tidak terautentikasi, karena itu hanya di-bind ke `127.0.0.1` atau tidak di-publish sama sekali.
- Variabel `ALERT_*` (password SMTP, URL webhook Teams) adalah secret: simpan hanya di `.env` (`chmod 600`, tidak di-commit).
- `cadvisor` berjalan `privileged` dengan mount read-only ke `/`, `/sys`, dan `/var/lib/docker` (kebutuhan cAdvisor). `node-exporter` memakai `pid: host` dan mount `/` read-only.
- Metrik tidak memuat data biometrik. Label yang tersimpan hanya nama service, database, dan mountpoint.

## 8. Troubleshooting

| Gejala | Penyebab / solusi |
|---|---|
| Panel Container kosong, log cadvisor `failed to identify the read-write layer ID` | Versi cAdvisor < v0.55 di Docker dengan containerd snapshotter. Pakai `CADVISOR_VERSION=v0.55.1` atau lebih baru. |
| Panel GPU kosong | `docker compose logs gpu-exporter`. Pastikan `nvidia-container-toolkit` ada dan runtime `nvidia` terdaftar (`docker info | grep -i runtime`). |
| `postgres` target down / `pg_up 0` | Cek kredensial `POSTGRES_EXPORTER_*` atau `POSTGRES_*` di `.env`, lalu `docker compose logs postgres-exporter`. |
| Notifikasi tidak terkirim | `docker compose logs alertmanager`: baris `kanal notifikasi aktif` menunjukkan kanal yang terbaca, dan error kirim muncul sebagai `Notify for alerts failed`. Pastikan host bisa menjangkau SMTP atau webhook (firewall/proxy). |
| Health check datasource Alertmanager di Grafana: `Plugin unavailable` | Normal: datasource ini tidak punya health check backend. Uji dengan membuka Alerting → Alert groups, pilih datasource Alertmanager. |
| Login Grafana gagal setelah ganti `.env` | Lihat reset password di §2. |
| `health` admin/api DOWN tapi container healthy | Port management 8081 berubah atau actuator health dimatikan. Cek `docker compose exec compreface-api curl -s localhost:8081/actuator/health`. |
