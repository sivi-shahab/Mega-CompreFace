# Contributing

| Metadata | |
|---|---|
| Judul | Panduan Kontribusi — branching, commit, build & test lokal, review |
| Versi | 1.0.0 |
| Tanggal | 2026-09-29 |
| Owner | Tim Platform / DevOps |
| Status | Review |

| Versi | Tanggal | Penulis | Perubahan |
|---|---|---|---|
| 1.0.0 | 2026-09-29 | Claude Code | Versi awal (panduan upstream dipindah ke [docs/upstream/CONTRIBUTING-upstream.md](docs/upstream/CONTRIBUTING-upstream.md)) |

## 1. Branching strategy

Trunk-based dengan branch rilis:

| Branch | Tujuan | Aturan |
|---|---|---|
| `main` | Selalu dapat di-build & di-deploy ke dev | Proteksi: merge hanya lewat PR + review + CI hijau |
| `feat/<id>-<ringkas>`, `fix/<id>-<ringkas>`, `docs/…`, `chore/…` | Pekerjaan harian | Umur pendek (≤ 1 minggu), rebase dari `main` |
| `release/<service>-<versi>` | Stabilisasi rilis prod (opsional) | Hanya fix; di-tag setelah lolos UAT |
| `upstream-sync/<versi>` | Merge rilis baru `exadel-inc/CompreFace` | Wajib uji penuh TEST_PLAN + cek kompatibilitas embedding |

**Tag rilis** per service: `<service>/v<semver>` (mis. `compreface-api/v1.2.1`, `compreface-core/v1.2.0-arcface-r100-gpu`). Tag harus sama dengan versi image.

## 2. Konvensi commit — Conventional Commits

```
<type>(<scope>): <ringkasan imperatif, ≤ 72 karakter>

[body: apa & mengapa]

[footer: BREAKING CHANGE: …, Refs: <tiket>]
```
- `type`: `feat`, `fix`, `docs`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`, `security`
- `scope`: `fe`, `admin`, `api`, `core`, `postgres-db`, `k8s`, `compose`, `scripts`, `docs`, `common` (java/common → memengaruhi admin **dan** api)
- Contoh:
  - `fix(fe): gunakan resolver dinamis agar nginx tidak crash tanpa upstream`
  - `feat(core)!: ganti model default ke arcface-r100` + footer `BREAKING CHANGE: embedding lama harus di-recalculate`

## 3. Versioning (ringkas, detail di [SPEC §8](SPEC.md#8-strategi-build-versioning--tagging))

| Perubahan | Naikkan |
|---|---|
| Dockerfile/konfigurasi image tanpa perubahan perilaku API | PATCH service terkait |
| Fitur kompatibel | MINOR |
| Kontrak API/skema DB tidak kompatibel, **atau model core berbeda** | MAJOR |
| `java/common` | admin **dan** api |
| Hanya `k8s/` atau `docs/` | tidak ada versi image baru; catat di CHANGELOG |

Tag `latest` dilarang (`scripts/build.sh` menolak).

## 4. Build & test lokal

Prasyarat: Docker ≥ 23 dengan BuildKit, `python3`, `curl`, `openssl`; opsional `kubectl` ≥ 1.27, `kubeconform`.

```bash
# build satu / semua service
scripts/build.sh api
scripts/build.sh --variant default all

# jalankan & uji end-to-end
cp .env.example .env && $EDITOR .env          # isi POSTGRES_PASSWORD, SECURITY_SIGNINGKEY
docker compose up -d --wait
scripts/e2e-test.sh http://127.0.0.1:8000     # harus "0 FAIL"
docker compose down -v

# manifest
kubectl kustomize k8s/overlays/dev  | kubeconform -strict -summary -
kubectl kustomize k8s/overlays/prod | kubeconform -strict -summary -

# konsistensi dokumentasi
scripts/check-docs.sh
```
Unit test upstream: core menjalankan `pytest` saat build varian CPU. Java/UI mengikuti [docs/upstream/CONTRIBUTING-upstream.md](docs/upstream/CONTRIBUTING-upstream.md) (Maven/npm).

**Jangan** memakai data wajah nasabah untuk pengujian. Gunakan `embedding-calculator/sample_images`.

## 5. Proses review (Pull Request)

Checklist PR:
- [ ] Judul PR mengikuti Conventional Commits; tiket direferensikan
- [ ] `scripts/build.sh <service terdampak>` sukses; `scripts/e2e-test.sh` 0 FAIL (bila menyentuh image/compose)
- [ ] `kubectl kustomize` + `kubeconform` lulus (bila menyentuh `k8s/`)
- [ ] `scripts/check-docs.sh` lulus; dokumen terkait diperbarui (CONFIGURATION untuk env var baru, TEST_PLAN untuk TC baru, ADR untuk keputusan arsitektur)
- [ ] CHANGELOG `[Unreleased]` diperbarui; versi image dinaikkan sesuai §3
- [ ] Tidak ada secret/credential/data pribadi di diff, log, atau bukti uji
- [ ] Perubahan pada `java/`, `ui/`, `embedding-calculator/` (source upstream) dijustifikasi — utamakan konfigurasi; tandai agar mudah di-merge ulang dengan upstream

Reviewer: minimal **1 approver tim Platform**. Tambahan **Security/DPO** bila PR menyentuh alur data biometrik, NetworkPolicy, Secret, logging, atau retensi. PR di-merge dengan *squash* ke `main`.

## 6. Lisensi & kontribusi upstream

Kode tetap Apache 2.0. Jangan menghapus header copyright atau `LICENSE`/`NOTICE`. Perbaikan bug upstream (mis. SECURITY S-13) sebaiknya juga diajukan ke `exadel-inc/CompreFace` (lihat CLA di [CLA.md](CLA.md)), tanpa menyertakan data internal bank.
