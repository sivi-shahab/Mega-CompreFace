# compreface-api

| Metadata | |
|---|---|
| Judul | README service compreface-api |
| Versi | 1.0.0 |
| Tanggal | 2026-09-29 |
| Owner | Tim Platform / DevOps |
| Status | Review |

| Versi | Tanggal | Penulis | Perubahan |
|---|---|---|---|
| 1.0.0 | 2026-09-29 | Claude Code | Versi awal |

## Tujuan
REST API publik `/api/v1` (Spring Boot, modul `java/api` + `java/common`): kelola subject/example wajah, recognition, verification, detection. Memanggil core untuk deteksi & embedding, menyimpan embedding (dan gambar bila `SAVE_IMAGES_TO_DB=true`) ke Postgres, cache embedding di heap. Referensi API: [docs/upstream/Rest-API-description.md](../../docs/upstream/Rest-API-description.md).

## File
| File | Isi |
|---|---|
| `Dockerfile` | Stage 1 Maven (`-pl api -am`, build arg `ND4J_CLASSIFIER`); stage 2 JRE 17, uid 1001 |
| `Dockerfile.dockerignore` | Context: `java/pom.xml`, `java/common`, `java/api`, `java/admin/pom.xml` |

## Build
```bash
scripts/build.sh api                                  # → mega/compreface-api:1.2.0
ND4J_CLASSIFIER=linux-x86_64-avx2 scripts/build.sh api   # CPU modern (opsional)
```

## Env var utama
`POSTGRES_URL`, `POSTGRES_USER`/`POSTGRES_PASSWORD` (Secret), `PYTHON_URL` (URL core, ClusterIP), `CONNECTION_TIMEOUT`, `READ_TIMEOUT`, `SAVE_IMAGES_TO_DB`, `API_JAVA_OPTS` — lengkap di [CONFIGURATION §4](../../docs/CONFIGURATION.md#4-compreface-api).

## Port & healthcheck
| Port | Fungsi | Healthcheck |
|---|---|---|
| 8080 | `/api/v1/**` (header `x-api-key`) | `/api/v1/consistence/status` (fungsional, memanggil core) |
| 8081 | Actuator (di 8080 `/actuator` diblokir filter api-key) | `/actuator/health/liveness`, `/actuator/health/readiness` |

⚠️ `/tmp` harus **exec** (ND4J memuat library native OpenBLAS dari `/tmp`) — di compose `tmpfs: /tmp:exec`; emptyDir k8s sudah sesuai ([RUNBOOK §7.3](../../docs/RUNBOOK.md#73-admin--api)).
