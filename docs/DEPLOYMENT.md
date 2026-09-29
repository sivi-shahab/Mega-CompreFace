# Deployment CompreFace (mega)

| Metadata | |
|---|---|
| Judul | Panduan Deployment — build, transfer air-gapped, deploy per environment, verifikasi, rollback |
| Versi | 1.0.0 |
| Tanggal | 2026-09-29 |
| Owner | Tim Platform / DevOps |
| Status | Review |

| Versi | Tanggal | Penulis | Perubahan |
|---|---|---|---|
| 1.0.0 | 2026-09-29 | Claude Code | Versi awal |

Terkait: [CONFIGURATION](CONFIGURATION.md) · [MIGRATION](MIGRATION.md) (compose → Kubernetes, data existing) · [RUNBOOK](RUNBOOK.md) · [SECURITY](SECURITY.md)

## 1. Prasyarat

### 1.1 Mesin build (berinternet)
| Kebutuhan | Keterangan |
|---|---|
| Docker Engine ≥ 23 dengan BuildKit/buildx | Wajib untuk `Dockerfile.dockerignore` per service dan `RUN --mount` |
| Akses keluar | Docker Hub (base image + `exadel/compreface-core` sebagai sumber model), `snapshot.debian.org`, `archive.ubuntu.com`, PyPI, `bootstrap.pypa.io`, GitHub (lib native imagecodecs), Maven Central, npm registry |
| Disk kosong di storage Docker | ≥ 40 GB untuk build semua image + varian GPU (image final ±18 GB di disk + build cache). Catatan: dengan containerd snapshotter, lokasi data Docker bisa berbeda dari `Docker Root Dir` di `docker info` — cek partisi sebenarnya |
| Waktu build (host acuan 8 vCPU) | Build dingin: fe ± 4–5 menit, admin ± 2 menit, api ± 1 menit, core CPU ± 6 menit, core GPU ± 6 menit |
| Git | Untuk label `revision` |

### 1.2 Cluster target (air-gapped)
| Kebutuhan | Keterangan |
|---|---|
| Kubernetes ≥ 1.25 | Pod Security Admission (`restricted`), `policy/v1` PDB, `autoscaling/v2` |
| CNI yang menegakkan NetworkPolicy | Calico/Cilium/dll. Tanpa ini, isolasi [SPEC](../SPEC.md) NFR-07 tidak berlaku |
| StorageClass | Prod: **terenkripsi at-rest** (ganti `encrypted-block` di `overlays/prod/patches/postgres-storage.yaml`) |
| Ingress controller + TLS | Sertifikat dari PKI internal. Label namespace controller harus cocok dengan `k8s/base/compreface-fe/networkpolicy.yaml` (default `ingress-nginx`) |
| Node GPU (prod) | NVIDIA driver + device plugin / GPU Operator (resource `nvidia.com/gpu`, label `nvidia.com/gpu.present=true`, taint `nvidia.com/gpu:NoSchedule`) |
| Registry internal | Mis. Harbor. Ganti `registry.example.internal` di kedua overlay |
| `kubectl` ≥ 1.27 (kustomize built-in) | |

## 2. Build (mesin berinternet)

```bash
cd CompreFace
git checkout <tag-rilis>            # pastikan working tree bersih → label revision tanpa "-dirty"

# semua service; core varian default (FaceNet CPU) + varian prod (ArcFace GPU)
REGISTRY=registry.example.internal \
  scripts/build.sh --variant default,arcface-r100-gpu all

# atau per service, versi independen:
REGISTRY=registry.example.internal API_VERSION=1.2.1 scripts/build.sh api
```

Output: daftar image di `build/images.txt`. Ukuran referensi (Fase 4, terkompresi / di disk):

| Image | Terkompresi | Disk |
|---|---|---|
| fe 1.2.0 | 55 MB | 203 MB |
| admin 1.2.0 | 159 MB | 520 MB |
| api 1.2.0 | 239 MB | 686 MB |
| postgres-db 1.2.0 | 111 MB | 428 MB |
| core 1.2.0 | 1,47 GB | 4,72 GB |
| core 1.2.0-arcface-r100-gpu | 3,88 GB | 11,4 GB |

Verifikasi lokal sebelum transfer (disarankan): jalankan compose dan [`scripts/e2e-test.sh`](../scripts/e2e-test.sh) (lihat [TEST_PLAN](TEST_PLAN.md)).

## 3. Transfer ke registry internal

### Opsi A — `docker save` / `docker load` (paling sederhana)
```bash
# mesin berinternet
scripts/push.sh --save /media/transfer/compreface-1.2.0       # *.tar.gz + SHA256SUMS
# pindahkan media sesuai prosedur transfer data bank

# mesin di jaringan internal (punya akses ke registry)
cd /media/transfer/compreface-1.2.0 && sha256sum -c SHA256SUMS
for f in *.tar.gz; do gunzip -c "$f" | docker load; done
REGISTRY=registry.example.internal
for i in $(docker images --format '{{.Repository}}:{{.Tag}}' | grep '/mega/compreface-'); do docker push "$i"; done
```
Jika image di-build tanpa `REGISTRY`, beri tag dulu: `docker tag mega/compreface-api:1.2.0 $REGISTRY/mega/compreface-api:1.2.0`.

### Opsi B — `skopeo` (tanpa Docker daemon, menjaga digest)
```bash
# mesin berinternet: ekspor ke direktori OCI
skopeo copy docker-daemon:mega/compreface-api:1.2.0 oci:/media/transfer/oci:compreface-api-1.2.0
# jaringan internal
skopeo copy oci:/media/transfer/oci:compreface-api-1.2.0 \
  docker://registry.example.internal/mega/compreface-api:1.2.0
```

### Opsi C — push langsung (bila mesin build punya akses ke registry)
```bash
scripts/push.sh            # digest dicatat ke build/digests.txt
```

Setelah push, catat digest (`build/digests.txt` atau `skopeo inspect`). Untuk prod disarankan pin digest di overlay:
```yaml
images:
  - name: mega/compreface-api
    newName: registry.example.internal/mega/compreface-api
    digest: sha256:<digest>
```

## 4. Buat Secret

Secret **tidak** ada di git. Buat per namespace, idealnya lewat mekanisme secret management bank (Vault / External Secrets / Sealed Secrets). Contoh manual:
```bash
NS=compreface            # dev: compreface-dev
kubectl create namespace $NS --dry-run=client -o yaml | kubectl apply -f -   # atau apply overlay dulu
kubectl -n $NS create secret generic compreface-postgres-credentials \
  --from-literal=POSTGRES_USER=compreface \
  --from-literal=POSTGRES_PASSWORD="$(openssl rand -base64 24)"
kubectl -n $NS create secret generic compreface-admin-secrets \
  --from-literal=SECURITY_SIGNINGKEY="$(openssl rand -hex 32)"
  # + --from-literal=EMAIL_USERNAME=... --from-literal=EMAIL_PASSWORD=...  bila email aktif
```
Password DB **harus sama** dengan yang dipakai saat PVC postgres pertama kali diinisialisasi. Mengganti Secret tidak mengubah password di DB yang sudah ada (lihat [RUNBOOK §6](RUNBOOK.md#6-rotasi-password-database)).

## 5. Deploy per environment

### 5.1 Sesuaikan placeholder (sekali per cluster)
| File | Placeholder |
|---|---|
| `k8s/overlays/{dev,prod}/kustomization.yaml` | `registry.example.internal` |
| `k8s/overlays/prod/patches/postgres-storage.yaml` | `storageClassName: encrypted-block`, ukuran PVC |
| `k8s/base/compreface-fe/networkpolicy.yaml` | namespace ingress controller (`ingress-nginx`) |
| `k8s/overlays/prod/patches/core-resources.yaml` | `nodeSelector`/`tolerations` GPU |
| `k8s/overlays/prod/ingress.example.yaml` | host, `ingressClassName`, Secret TLS (aktifkan di `kustomization.yaml`) |
| `k8s/base/compreface-admin/configmap.env` | `FRS_CRUD_HOST`, `EMAIL_*` bila email dipakai |

### 5.2 Render & review
```bash
kubectl kustomize k8s/overlays/prod > /tmp/compreface-prod.yaml
kubeconform -strict -summary /tmp/compreface-prod.yaml     # opsional
kubectl diff -k k8s/overlays/prod                          # terhadap cluster
```

### 5.3 Apply
**Instalasi baru** (DB kosong, Liquibase dijalankan admin):
```bash
kubectl apply -k k8s/overlays/prod          # Namespace + semua resource
# (buat Secret §4 bila namespace baru terbentuk, lalu pod akan start ulang otomatis)
kubectl -n compreface rollout status statefulset/compreface-postgres-db --timeout=5m
kubectl -n compreface rollout status deploy/compreface-admin --timeout=10m
for d in compreface-api compreface-core compreface-fe; do
  kubectl -n compreface rollout status deploy/$d --timeout=15m
done
```
Urutan status di atas mengikuti dependency ([ARCHITECTURE §5](ARCHITECTURE.md#5-dependency--urutan-startup)). Semua resource boleh di-apply sekaligus karena probe menahan traffic.

**Dengan data existing dari compose**: ikuti [MIGRATION.md](MIGRATION.md).

**Dev**: sama, dengan `k8s/overlays/dev` dan namespace `compreface-dev`.

### 5.4 Update versi satu service
```bash
# ubah newTag service terkait di overlay (mis. api 1.2.0 → 1.2.1), commit, lalu:
kubectl apply -k k8s/overlays/prod
kubectl -n compreface rollout status deploy/compreface-api
```

## 6. Verifikasi pasca-deploy

```bash
NS=compreface
kubectl -n $NS get pods -o wide                         # semua Running, READY penuh, RESTARTS 0
kubectl -n $NS get pvc                                  # Bound, storage class benar
# 1. fe
kubectl -n $NS run chk --rm -it --restart=Never --image=registry.example.internal/mega/compreface-fe:1.2.0 \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":101}}}' -- \
  curl -s -o /dev/null -w '%{http_code}\n' http://compreface-fe/healthz      # 200
# 2. core: model & varian benar (prod harus arcface-r100-msfdrop75)
kubectl -n $NS exec deploy/compreface-core -- curl -s http://127.0.0.1:3000/status
# 3. api ↔ core ↔ db
kubectl -n $NS exec deploy/compreface-api -- curl -s http://127.0.0.1:8080/api/v1/consistence/status   # "status":"OK"
# 4. health actuator
kubectl -n $NS exec deploy/compreface-admin -- curl -s http://127.0.0.1:8081/actuator/health          # UP
# 5. end-to-end lewat ingress (akun OWNER/ADMIN, gambar uji non-nasabah)
E2E_EMAIL=<owner> E2E_PASSWORD=<pwd> scripts/e2e-test.sh https://compreface.example.internal
```
Kriteria lulus: semua perintah sesuai ekspektasi, `e2e-test.sh` **0 FAIL**, dan tidak ada event `Warning` baru (`kubectl -n $NS get events --field-selector type=Warning`).

Catatan: `kubectl run` untuk pod ad-hoc bisa ditolak NetworkPolicy default-deny/PSA. Alternatifnya, gunakan `kubectl exec` ke pod yang ada atau `kubectl port-forward svc/compreface-fe 8080:80`.

## 7. Rollback

| Situasi | Tindakan |
|---|---|
| Rilis image baru bermasalah | `kubectl -n $NS rollout undo deploy/<service>` (revisionHistoryLimit 5) — lalu kembalikan `newTag` di overlay dan commit agar git = cluster |
| Perubahan ConfigMap bermasalah | Revert commit overlay/`configmap.env`, lalu `kubectl apply -k`. ConfigMap ber-hash, sehingga Deployment kembali ke ConfigMap lama |
| Migrasi Liquibase gagal/merusak skema (versi admin baru) | Scale api & admin ke 0, restore DB dari backup sebelum rilis ([RUNBOOK §5](RUNBOOK.md#5-backup--restore-postgres)), deploy admin versi lama |
| Core varian salah | Kembalikan tag core. Embedding yang sempat dibuat dengan model salah harus dihapus/di-recalculate |
| Seluruh cutover compose → k8s gagal | [MIGRATION §7](MIGRATION.md#7-rollback-plan) |

Selalu ambil backup DB sebelum upgrade admin/api ([RUNBOOK §5](RUNBOOK.md#5-backup--restore-postgres)).
