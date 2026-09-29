# ADR-004 — envsubst + resolver di nginx FE

| Metadata | |
|---|---|
| Judul | ADR-004 envsubst + resolver di nginx FE |
| Versi | 1.0.0 |
| Tanggal | 2026-09-29 |
| Owner | Tim Platform / DevOps |
| Status | Review — keputusan: **Accepted** |

| Versi | Tanggal | Penulis | Perubahan |
|---|---|---|---|
| 1.0.0 | 2026-09-29 | Claude Code | Versi awal |

## Context

- Template nginx upstream memakai blok `upstream` statis dengan hostname hardcoded (`compreface-admin`, `compreface-api`, `compreface-core`). nginx me-resolve hostname tersebut **sekali saat start**. Jika salah satu tidak ter-resolve, muncul `[emerg] host not found in upstream`, nginx exit, dan container restart terus. Ini penyebab `compreface-ui` restart loop pada deployment compose ketika core tidak tersedia.
- Di Kubernetes, IP Service/Pod bisa berubah, dan urutan startup tidak dijamin.
- Resolver nginx **tidak memakai `search` domain** dari `/etc/resolv.conf`, sehingga nama pendek `compreface-api` tidak ter-resolve oleh kube-dns.
- Route `/core/` mengekspos core tanpa autentikasi dan tidak dipakai UI.

## Decision

1. `services/compreface-fe/nginx.conf.template` dirender oleh envsubst (bawaan image nginx). Upstream diambil dari `ADMIN_UPSTREAM` dan `API_UPSTREAM`.
2. Direktif `resolver ${NGINX_RESOLVER} valid=${NGINX_RESOLVER_VALID}` dipasang, dan `proxy_pass` memakai **variabel** (`proxy_pass http://$api_upstream;`), sehingga nama di-resolve per request/TTL dan nginx tetap start tanpa upstream.
3. Entrypoint `docker-entrypoint-fe.sh`:
   - `NGINX_RESOLVER` kosong → diambil dari `nameserver` pertama di resolv.conf (docker: 127.0.0.11, k8s: IP kube-dns; IPv6 dibungkus `[]`).
   - `NGINX_UPSTREAM_AUTO_FQDN=true` dan host tanpa titik → ditambahkan domain `search` pertama (`<ns>.svc.cluster.local`), kecuali di DNS docker.
4. Route `/core/` dihapus. Endpoint `/healthz` ditambahkan untuk probe, container listen di 8080 dan berjalan non-root (`nginx-unprivileged`).

## Consequences

- ✅ fe tetap healthy tanpa backend (502, bukan crash), dan otomatis pulih ketika IP backend berubah ([bukti](../test-evidence/2026-09-29/tc-fe-resilience.txt)).
- ✅ ConfigMap base portabel lintas namespace.
- ⚠️ Load balancing nginx antar-endpoint hilang (tanpa blok `upstream`). Ini tidak masalah karena target adalah Service ClusterIP yang sudah melakukan load balancing.
- ⚠️ `proxy_pass` berbasis variabel tidak melakukan URI rewrite otomatis. Route swagger ditulis ulang secara eksplisit per service.
- ⚠️ Konsumen yang dulu memanggil `/core/` via fe harus beralih ke api (`/api/v1/detection/detect`, dll.).
