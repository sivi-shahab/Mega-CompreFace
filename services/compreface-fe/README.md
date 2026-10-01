# compreface-fe

| Metadata | |
|---|---|
| Judul | README service compreface-fe |
| Versi | 1.0.0 |
| Tanggal | 2026-09-29 |
| Owner | Tim Platform / DevOps |
| Status | Review |

| Versi | Tanggal | Penulis | Perubahan |
|---|---|---|---|
| 1.0.0 | 2026-09-29 | Claude Code | Versi awal |

## Tujuan
UI admin CompreFace (Angular 11, source `ui/`) disajikan oleh nginx, sekaligus reverse proxy ke admin (`/admin/**`) dan api (`/api/v1/**`, swagger). Ini satu-satunya service yang diekspos ke luar (lewat ingress).

## File
| File | Isi |
|---|---|
| `Dockerfile` | Stage 1 `node:12.22.12` → `npm run build:prod`; stage 2 `nginxinc/nginx-unprivileged:1.21.1` (uid 101) |
| `Dockerfile.dockerignore` | Context hanya `ui/` (tanpa `node_modules`), `LICENSE`, `NOTICE`, direktori ini |
| `nginx.conf` | Konfigurasi utama (pid/temp di `/tmp`, log akses JSON tanpa query string) |
| `nginx.conf.template` | Server block: resolver dinamis, upstream dari env, **tanpa** route `/core/` (kecuali `GET /core/status` untuk UI), `/healthz` ([ADR-004](../../docs/adr/ADR-004-nginx-envsubst-resolver.md)) |
| `docker-entrypoint-fe.sh` | Deteksi resolver dari resolv.conf + auto-FQDN, lalu memanggil entrypoint nginx resmi (envsubst) |

## Build
```bash
scripts/build.sh fe                                   # → mega/compreface-fe:1.2.0
# manual: docker build -f services/compreface-fe/Dockerfile -t mega/compreface-fe:1.2.0 .
```

## Env var utama
`ADMIN_UPSTREAM`, `API_UPSTREAM`, `CORE_UPSTREAM`, `NGINX_RESOLVER`, `NGINX_UPSTREAM_AUTO_FQDN`, `CLIENT_MAX_BODY_SIZE`, `PROXY_READ_TIMEOUT`, `PROXY_CONNECT_TIMEOUT` — lengkap di [CONFIGURATION §2](../../docs/CONFIGURATION.md#2-compreface-fe).

## Port & healthcheck
| Port | Healthcheck | Catatan |
|---|---|---|
| 8080 (Service: 80) | `GET /healthz` → `ok` | Hanya mengecek nginx. fe tetap healthy walau admin/api down (respons 502) |

Butuh `/tmp` dan `/etc/nginx/conf.d` yang writable (emptyDir/tmpfs) saat root FS read-only.
