#!/usr/bin/env bash
# Build image CompreFace per service (independen).
#
# Pemakaian:
#   scripts/build.sh [opsi] <service...|all>
#   service: fe | admin | api | core | postgres-db   (boleh dengan prefix "compreface-")
#
# Opsi:
#   --variant <nama>   varian core dari services/compreface-core/build-args.env (default: "default").
#                      Boleh diulang / dipisah koma: --variant default,arcface-r100-gpu
#   --version <ver>    versi untuk SEMUA service yang di-build (override VERSION per service)
#   --no-cache         teruskan --no-cache ke docker build
#   --dry-run          tampilkan perintah tanpa menjalankan
#   -h | --help
#
# Env:
#   REGISTRY           prefix registry, mis. registry.example.internal  (kosong = lokal)
#   IMAGE_NAMESPACE    default: mega
#   FE_VERSION ADMIN_VERSION API_VERSION CORE_VERSION POSTGRES_VERSION   default: 1.2.0
#   ND4J_CLASSIFIER    build arg compreface-api (default linux-x86_64)
#   DOCKER_BUILD_ARGS  argumen tambahan untuk docker build (mis. "--progress=plain")
#
# Output: daftar image yang dibangun ditulis ke build/images.txt (dipakai scripts/push.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="${REGISTRY:-}"
IMAGE_NAMESPACE="${IMAGE_NAMESPACE:-mega}"
BUILD_ARGS_FILE="$ROOT/services/compreface-core/build-args.env"
OUT_DIR="$ROOT/build"
ALL_SERVICES=(postgres-db admin api core fe)

VARIANTS=()
VERSION_OVERRIDE=""
NO_CACHE=""
DRY_RUN=false
SERVICES=()

die() { echo "ERROR: $*" >&2; exit 1; }
usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --variant) [[ $# -ge 2 ]] || die "--variant butuh nilai"; IFS=',' read -r -a v <<<"$2"; VARIANTS+=("${v[@]}"); shift 2 ;;
    --version) [[ $# -ge 2 ]] || die "--version butuh nilai"; VERSION_OVERRIDE="$2"; shift 2 ;;
    --no-cache) NO_CACHE="--no-cache"; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    all) SERVICES+=("${ALL_SERVICES[@]}"); shift ;;
    -*) die "opsi tidak dikenal: $1" ;;
    *) SERVICES+=("${1#compreface-}"); shift ;;
  esac
done
[[ ${#SERVICES[@]} -gt 0 ]] || { usage; exit 1; }
[[ ${#VARIANTS[@]} -gt 0 ]] || VARIANTS=(default)

version_for() {
  local svc="$1" var
  if [[ -n "$VERSION_OVERRIDE" ]]; then echo "$VERSION_OVERRIDE"; return; fi
  case "$svc" in
    fe) var="${FE_VERSION:-1.2.0}" ;;
    admin) var="${ADMIN_VERSION:-1.2.0}" ;;
    api) var="${API_VERSION:-1.2.0}" ;;
    core) var="${CORE_VERSION:-1.2.0}" ;;
    postgres-db) var="${POSTGRES_VERSION:-1.2.0}" ;;
    *) die "service tidak dikenal: $svc (pilihan: ${ALL_SERVICES[*]})" ;;
  esac
  echo "$var"
}

validate_version() {
  local v="$1"
  [[ "$v" != "latest" ]] || die "tag 'latest' dilarang — gunakan versi SemVer (mis. 1.2.0)"
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || die "versi '$v' bukan SemVer (MAJOR.MINOR.PATCH[-suffix])"
}

image_ref() {
  local svc="$1" tag="$2" prefix=""
  [[ -n "$REGISTRY" ]] && prefix="${REGISTRY%/}/"
  echo "${prefix}${IMAGE_NAMESPACE}/compreface-${svc}:${tag}"
}

# Baca satu varian dari build-args.env → array global VARIANT_KV (KEY=VALUE)
load_variant() {
  local name="$1" section="" line found=false
  VARIANT_KV=()
  [[ -f "$BUILD_ARGS_FILE" ]] || die "tidak ditemukan: $BUILD_ARGS_FILE"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%$'\r'}"
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ ^\[(.+)\]$ ]]; then section="${BASH_REMATCH[1]}"; continue; fi
    if [[ "$section" == "$name" ]]; then found=true; VARIANT_KV+=("$line"); fi
  done <"$BUILD_ARGS_FILE"
  $found || die "varian '$name' tidak ada di $BUILD_ARGS_FILE"
}

REVISION="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
if [[ "$REVISION" != "unknown" ]] && ! git -C "$ROOT" diff --quiet HEAD -- 2>/dev/null; then
  REVISION="${REVISION}-dirty"
fi
mkdir -p "$OUT_DIR"
BUILT=()

run() {
  echo "+ $*"
  $DRY_RUN || "$@"
}

build_one() {
  local svc="$1" tag="$2"; shift 2
  local ref; ref="$(image_ref "$svc" "$tag")"
  echo "==> build ${ref}"
  local start=$SECONDS
  # shellcheck disable=SC2086
  run env DOCKER_BUILDKIT=1 docker build $NO_CACHE ${DOCKER_BUILD_ARGS:-} \
    -f "$ROOT/services/compreface-${svc}/Dockerfile" \
    --build-arg "VERSION=${tag}" \
    --build-arg "REVISION=${REVISION}" \
    "$@" \
    -t "$ref" "$ROOT"
  echo "==> selesai ${ref} ($((SECONDS - start)) s)"
  BUILT+=("$ref")
}

for svc in "${SERVICES[@]}"; do
  ver="$(version_for "$svc")"
  validate_version "$ver"
  case "$svc" in
    core)
      for variant in "${VARIANTS[@]}"; do
        load_variant "$variant"
        args=(--build-arg "VARIANT=${variant}" --build-arg "BE_VERSION=${ver}" --build-arg "APP_VERSION_STRING=${ver}")
        suffix=""
        for kv in "${VARIANT_KV[@]}"; do
          key="${kv%%=*}"; val="${kv#*=}"
          case "$key" in
            TAG_SUFFIX) suffix="$val" ;;
            *) args+=(--build-arg "${key}=${val}") ;;
          esac
        done
        validate_version "${ver}${suffix}"
        build_one core "${ver}${suffix}" "${args[@]}"
      done
      ;;
    api)
      build_one api "$ver" --build-arg "ND4J_CLASSIFIER=${ND4J_CLASSIFIER:-linux-x86_64}"
      ;;
    fe|admin|postgres-db)
      build_one "$svc" "$ver"
      ;;
    *) die "service tidak dikenal: $svc" ;;
  esac
done

if ! $DRY_RUN; then
  printf '%s\n' "${BUILT[@]}" >"$OUT_DIR/images.txt"
  echo
  echo "Image yang dibangun (ditulis ke build/images.txt):"
  for ref in "${BUILT[@]}"; do
    printf '  %-70s %s\n' "$ref" "$(docker image inspect -f '{{.Size}}' "$ref" | awk '{printf "%.0f MB", $1/1000/1000}')"
  done
fi
