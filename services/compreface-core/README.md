# compreface-core

| Metadata | |
|---|---|
| Judul | README service compreface-core |
| Versi | 1.0.0 |
| Tanggal | 2026-09-29 |
| Owner | Tim Platform / DevOps |
| Status | Review |

| Versi | Tanggal | Penulis | Perubahan |
|---|---|---|---|
| 1.0.0 | 2026-09-29 | Claude Code | Versi awal |

## Tujuan
Layanan ML (`embedding-calculator/`, Python 3.8, Flask + uWSGI): deteksi wajah, embedding 512 dimensi, plugin age/gender/mask/landmarks/pose. Stateless, tanpa akses DB, **tanpa koneksi keluar saat runtime** (model ter-bake di image, [ADR-002](../../docs/adr/ADR-002-model-ml-baked-air-gapped.md)).

## File
| File | Isi |
|---|---|
| `Dockerfile` | Stage `base-cpu` (`python:3.8-slim-bullseye`, apt snapshot) / `base-gpu` (`nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu20.04`) → `builder` (lib native imagecodecs, pip, model dari `MODELS_IMAGE`, pytest) → `runtime` (tanpa toolchain, uid 33) |
| `build-args.env` | Definisi varian (plugin/model, CPU/GPU, sumber model) — dibaca `scripts/build.sh` |
| `uwsgi.ini` | uWSGI tanpa setuid, port `$(ML_PORT)`, request log off |
| `Dockerfile.dockerignore` | Context: `embedding-calculator/{src,srcext,tools,sample_images,requirements.txt,pytest.ini}` |

## Build
```bash
scripts/build.sh core                                  # varian default → mega/compreface-core:1.2.0 (FaceNet CPU)
scripts/build.sh core --variant arcface-r100-gpu       # → mega/compreface-core:1.2.0-arcface-r100-gpu (PROD)
scripts/build.sh core --variant default,arcface-r100-gpu
```

| Varian | Tag | Detector / Calculator | Pemakaian |
|---|---|---|---|
| `default` | `1.2.0` | `facenet.FaceDetector` / `facenet.Calculator` | dev (setara image resmi 1.2.0) |
| `arcface-r100-gpu` | `1.2.0-arcface-r100-gpu` | `insightface.FaceDetector@retinaface_r50_v1` / `insightface.Calculator@arcface-r100-msfdrop75` | **prod** (kompatibel dengan embedding produksi) |
| `arcface-r100`, `facenet`, `mobilenet`, `mobilenet-gpu` | `1.2.0-<varian>` | lihat `build-args.env` | opsional |

⚠️ Model berbeda = embedding tidak kompatibel ([ADR-005](../../docs/adr/ADR-005-varian-core.md)). Jangan override env plugin saat runtime.

## Env var utama
`UWSGI_PROCESSES`, `UWSGI_THREADS`, `UWSGI_MAX_WORKER_LIFETIME`, `IMG_LENGTH_LIMIT`, `ML_PORT`, `LOGGING_LEVEL_NAME` — lengkap + build args + sizing di [CONFIGURATION §5, §7, §8.1](../../docs/CONFIGURATION.md#5-compreface-core).

## Port & healthcheck
| Port | Endpoint | Catatan |
|---|---|---|
| 3000 | `GET /healthcheck` → `{"status":"OK"}` | liveness/readiness |
| 3000 | `GET /status` | varian, `calculator_version`, plugin |
| 3000 | `POST /find_faces` (multipart `file`) | dipakai api; startupProbe k8s mengirim sample image agar model termuat sebelum Ready |

Terukur (Fase 4): Ready + inferensi pertama 48 s (CPU) / 25 s (GPU); ≈ 2,56 GB VRAM per proses uWSGI (GPU). Butuh `/tmp` writable.
