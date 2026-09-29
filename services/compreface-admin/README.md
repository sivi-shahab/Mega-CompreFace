# compreface-admin

| Metadata | |
|---|---|
| Judul | README service compreface-admin |
| Versi | 1.0.0 |
| Tanggal | 2026-09-29 |
| Owner | Tim Platform / DevOps |
| Status | Review |

| Versi | Tanggal | Penulis | Perubahan |
|---|---|---|---|
| 1.0.0 | 2026-09-29 | Claude Code | Versi awal |

## Tujuan
Backend administrasi (Spring Boot, modul `java/admin` + `java/common`): user & role, aplikasi, face collection (model + API key), OAuth2 login (token di DB, cookie `CFSESSION`). **Menjalankan migrasi skema Liquibase** saat start, sehingga harus sukses sebelum api dipakai pada DB kosong.

## File
| File | Isi |
|---|---|
| `Dockerfile` | Stage 1 `maven:3.8.2-eclipse-temurin-17` (`mvn -pl admin -am package`); stage 2 `eclipse-temurin:17.0.8_7-jre-focal`, uid 1001. **Tanpa** `APPERY_API_KEY` |
| `Dockerfile.dockerignore` | Context: `java/pom.xml`, `java/common`, `java/admin`, `java/api/pom.xml` |

## Build
```bash
scripts/build.sh admin                                # → mega/compreface-admin:1.2.0
```
Perubahan di `java/common` → build ulang **admin dan api**.

## Env var utama
`POSTGRES_URL`, `POSTGRES_USER`/`POSTGRES_PASSWORD` (Secret), `SECURITY_SIGNINGKEY` (Secret), `PYTHON_URL`, `ENABLE_EMAIL_SERVER` + `EMAIL_*`, `ADMIN_JAVA_OPTS`, `MANAGEMENT_*` — lengkap di [CONFIGURATION §3](../../docs/CONFIGURATION.md#3-compreface-admin).

## Port & healthcheck
| Port | Fungsi | Healthcheck |
|---|---|---|
| 8080 | Aplikasi (`/admin/**`) | – |
| 8081 | Actuator | `/actuator/health/liveness`, `/actuator/health/readiness` (mail health dimatikan) |

Startup ± 30–40 s (lebih lama pada migrasi pertama). Butuh `/tmp` writable.
