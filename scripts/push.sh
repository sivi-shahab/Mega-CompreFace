#!/usr/bin/env bash
# Push image CompreFace ke registry, atau ekspor ke tarball untuk transfer air-gapped.
#
# Pemakaian:
#   scripts/push.sh [--save <dir>] [image...]
#   Tanpa argumen image → membaca build/images.txt (hasil scripts/build.sh).
#
# Mode:
#   (default)       docker push setiap image; digest dicatat ke build/digests.txt
#   --save <dir>    docker save setiap image ke <dir>/<nama>_<tag>.tar.gz + SHA256SUMS
#                   (dibawa ke jaringan internal, lalu `docker load` / `skopeo copy`)
#
# Image dengan tag 'latest' atau tanpa namespace mega/ ditolak.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_NAMESPACE="${IMAGE_NAMESPACE:-mega}"
SAVE_DIR=""
IMAGES=()

die() { echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --save) [[ $# -ge 2 ]] || die "--save butuh direktori"; SAVE_DIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) IMAGES+=("$1"); shift ;;
  esac
done

if [[ ${#IMAGES[@]} -eq 0 ]]; then
  [[ -f "$ROOT/build/images.txt" ]] || die "tidak ada image; jalankan scripts/build.sh dulu atau berikan argumen"
  mapfile -t IMAGES <"$ROOT/build/images.txt"
fi

for ref in "${IMAGES[@]}"; do
  [[ "$ref" == *":latest" || "$ref" != *:* ]] && die "tag latest/implisit dilarang: $ref"
  [[ "$ref" == *"${IMAGE_NAMESPACE}/compreface-"* ]] || die "image di luar namespace ${IMAGE_NAMESPACE}/: $ref"
  docker image inspect "$ref" >/dev/null 2>&1 || die "image tidak ada secara lokal: $ref"
done

if [[ -n "$SAVE_DIR" ]]; then
  mkdir -p "$SAVE_DIR"
  for ref in "${IMAGES[@]}"; do
    name="${ref##*/}"; file="$SAVE_DIR/${name/:/_}.tar.gz"
    echo "==> save $ref → $file"
    docker save "$ref" | gzip -1 >"$file"
  done
  (cd "$SAVE_DIR" && sha256sum ./*.tar.gz >SHA256SUMS)
  echo "Selesai. Verifikasi di sisi tujuan: (cd $SAVE_DIR && sha256sum -c SHA256SUMS)"
  exit 0
fi

mkdir -p "$ROOT/build"
: >"$ROOT/build/digests.txt"
for ref in "${IMAGES[@]}"; do
  [[ "${ref%%/*}" == *.* || "${ref%%/*}" == *:* || "${ref%%/*}" == localhost ]] \
    || die "image tanpa registry host ($ref); build ulang dengan REGISTRY=<host> atau docker tag dulu"
  echo "==> push $ref"
  docker push "$ref"
  digest="$(docker image inspect -f '{{join .RepoDigests "\n"}}' "$ref" | grep -F "${ref%:*}@" | head -n1)"
  echo "$ref  $digest" | tee -a "$ROOT/build/digests.txt"
done
echo "Digest tercatat di build/digests.txt (gunakan untuk pin @sha256 di overlay prod)."
