# syntax=docker/dockerfile:1.7
#
# compreface-core — embedding-calculator (Python/Flask/uWSGI), non-root, model ML ter-bake.
# Build context: root repo  (docker build -f services/compreface-core/Dockerfile .)
# Ignore file  : services/compreface-core/Dockerfile.dockerignore (BuildKit)
# Build args   : lihat services/compreface-core/build-args.env (dipakai scripts/build.sh)
#
# Stage:
#   base-cpu / base-gpu : base runtime minimal (dipilih lewat build arg COMPUTE=cpu|gpu)
#   builder             : compile lib native imagecodecs, pip install, DOWNLOAD MODEL (internet),
#                         jalankan unit test, hitung daftar paket OS yang dibutuhkan runtime
#   runtime             : base + paket OS runtime + /usr/local + /app/ml (model) — tanpa toolchain
#
# Runtime TIDAK melakukan koneksi keluar: semua model berada di /app/ml/.models.

ARG COMPUTE=cpu
ARG CPU_BASE_IMAGE=python:3.8-slim-bullseye@sha256:e191a71397fd61fbddb6712cd43ef9a2c17df0b5e7ba67607128554cd6bff267
ARG GPU_BASE_IMAGE=nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu20.04@sha256:c2336dadc71ae5b5ce490a55cc0100d876287d28f429a5d2840c8a3a8e86fef0
# Sumber model ML (lihat docs/adr/ADR-002):
#   MODEL_SOURCE=image  → salin /app/ml/.models dari MODELS_IMAGE (image resmi Exadel, di-pin digest)
#   MODEL_SOURCE=gdrive → unduh dari Google Drive (perilaku upstream; per 2026-09 file upstream
#                         meminta sign-in sehingga gagal)
ARG MODEL_SOURCE=image
ARG MODELS_IMAGE=exadel/compreface-core:1.2.0@sha256:c9c70f0f270b1767bdf59d8e549f00f7d8f06e29315ac2ff624e276dcf37385b

########################################################################################
FROM ${MODELS_IMAGE} AS models-src

########################################################################################
FROM ${CPU_BASE_IMAGE} AS base-cpu
ENV PYTHON=python
# Debian 11 (bullseye) sudah EOL: mirror security sedang dipindah ke arsip dan indeksnya bisa
# menunjuk paket yang sudah 404. apt dikunci ke snapshot.debian.org pada timestamp tetap
# (reproducible). Kosongkan DEBIAN_SNAPSHOT untuk memakai mirror resmi.
ARG DEBIAN_SNAPSHOT=20260801T000000Z
RUN if [ -n "${DEBIAN_SNAPSHOT}" ]; then \
      printf '%s\n' \
        "deb http://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT} bullseye main" \
        "deb http://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT} bullseye-updates main" \
        "deb http://snapshot.debian.org/archive/debian-security/${DEBIAN_SNAPSHOT} bullseye-security main" \
        > /etc/apt/sources.list \
   && printf 'Acquire::Check-Valid-Until "false";\nAcquire::Retries "5";\n' > /etc/apt/apt.conf.d/99snapshot ; \
    fi

########################################################################################
# Setara embedding-calculator/gpu.Dockerfile upstream, tanpa toolchain build.
FROM ${GPU_BASE_IMAGE} AS base-gpu
ENV DEBIAN_FRONTEND=noninteractive \
    CUDA=11.8 \
    PYTHON=python3 \
    TF_FORCE_GPU_ALLOW_GROWTH=true \
    MXNET_CPU_WORKER_NTHREADS=24 \
    MXNET_ENGINE_TYPE=ThreadedEnginePerDevice \
    MXNET_CUDNN_AUTOTUNE_DEFAULT=0
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-distutils \
 && ln -sf "$(command -v python3)" /usr/local/bin/python \
 && rm -rf /var/lib/apt/lists/*

########################################################################################
FROM base-${COMPUTE} AS builder
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake git wget unzip curl ca-certificates yasm pkg-config \
        libswscale-dev libtbb2 libtbb-dev libjpeg-dev libpng-dev libtiff-dev libavformat-dev \
        libpq-dev libfreeimage3 libgl1 libglib2.0-0 \
        libaec-dev libblosc-dev libbrotli-dev libbz2-dev libgif-dev libopenjp2-7-dev \
        liblcms2-dev libcharls-dev libjxr-dev liblz4-dev libcfitsio-dev libpcre3 libpcre3-dev \
        libsnappy-dev libwebp-dev libzopfli-dev libzstd-dev \
 && if [ "${PYTHON}" = "python3" ]; then \
        apt-get install -y --no-install-recommends python3-dev \
     && curl -fsSL https://bootstrap.pypa.io/pip/3.8/get-pip.py -o /tmp/get-pip.py \
     && python3 /tmp/get-pip.py "pip==23.0.1" "setuptools==57.5.0" "wheel==0.41.1" \
     && rm /tmp/get-pip.py ; \
    fi \
 && rm -rf /var/lib/apt/lists/*

# Dependencies for imagecodecs (sama dengan Dockerfile upstream, versi di-pin via tag git)
WORKDIR /tmp
RUN git clone --depth=1 --shallow-submodules --recursive -b v0.1 https://github.com/google/brunsli \
 && cd brunsli && cmake -DCMAKE_BUILD_TYPE=Release . && make -j"$(nproc)" install \
 && rm -rf /tmp/brunsli
RUN git clone --depth=1 --shallow-submodules --recursive -b v0.7.0 https://github.com/libjxl/libjxl \
 && cd libjxl && cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF . && make -j"$(nproc)" install \
 && rm -rf /tmp/libjxl
RUN git clone --depth=1 -b 0.5.5 https://github.com/LLNL/zfp \
 && cd zfp && mkdir build && cd build && cmake -DCMAKE_BUILD_TYPE=Release .. && make -j"$(nproc)" install \
 && rm -rf /tmp/zfp
RUN ldconfig

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
WORKDIR /app/ml
COPY embedding-calculator/requirements.txt .
# numpy dulu: imagecodecs 2020.5.30 tidak mendeklarasikan dependency dengan benar.
RUN pip --no-cache-dir install "$(grep ^numpy requirements.txt)" \
 && pip --no-cache-dir install -r requirements.txt

ARG BE_VERSION
ARG APP_VERSION_STRING
ARG INTEL_OPTIMIZATION=false
ARG GPU_IDX=-1
ARG FACE_DETECTION_PLUGIN="facenet.FaceDetector"
ARG CALCULATION_PLUGIN="facenet.Calculator"
ARG EXTRA_PLUGINS="facenet.LandmarksDetector,agegender.AgeDetector,agegender.GenderDetector,facenet.facemask.MaskDetector,facenet.PoseEstimator"
ENV HOME=/app/ml LC_ALL=C.UTF-8 LANG=C.UTF-8 PYTHONUNBUFFERED=0 JOBLIB_MULTIPROCESSING=0 \
    BE_VERSION=${BE_VERSION} APP_VERSION_STRING=${APP_VERSION_STRING} \
    GPU_IDX=${GPU_IDX} INTEL_OPTIMIZATION=${INTEL_OPTIMIZATION} \
    FACE_DETECTION_PLUGIN=${FACE_DETECTION_PLUGIN} CALCULATION_PLUGIN=${CALCULATION_PLUGIN} \
    EXTRA_PLUGINS=${EXTRA_PLUGINS}

COPY embedding-calculator/src src
COPY embedding-calculator/srcext srcext
ARG MODEL_SOURCE
COPY --from=models-src /app/ml/.models /tmp/models-src
# Install requirement plugin (tensorflow / mxnet / insightface) lalu pastikan semua model plugin
# tersedia di ~/.models. setup upstream hanya mengunduh model yang BELUM ada, sehingga dengan
# MODEL_SOURCE=image tidak ada unduhan model sama sekali. Checksum dicatat untuk audit.
RUN if [ "${MODEL_SOURCE}" = "image" ]; then mv /tmp/models-src /app/ml/.models; else rm -rf /tmp/models-src; fi \
 && python -m src.services.facescan.plugins.setup \
 && python - <<'PY'
from src.services.facescan.plugins.managers import plugin_manager
missing = [str(p) for p in plugin_manager.plugins if p.ml_model and not p.ml_model.exists()]
assert not missing, f"model plugin tidak tersedia: {missing}"
for p in plugin_manager.plugins:
    print("model OK:", p, "->", p.ml_model.path if p.ml_model else "(tanpa model)")
PY
RUN cd /app/ml/.models && find . -type f ! -name MODELS.sha256 -print0 | sort -z | xargs -0 sha256sum > MODELS.sha256 \
 && wc -l MODELS.sha256 && du -sh /app/ml/.models

COPY embedding-calculator/tools tools
COPY embedding-calculator/sample_images sample_images
COPY embedding-calculator/pytest.ini .

# Unit test (dilewati untuk GPU: tidak ada device GPU saat build).
ARG SKIP_TESTS
RUN if [ -z "${SKIP_TESTS}" ]; then pytest -p no:cacheprovider -m "not performance" /app/ml/src; fi

# Hitung paket OS yang dibutuhkan shared object di /usr/local (lib native + wheel python).
RUN set -e; \
    find /usr/local -type f \( -name '*.so' -o -name '*.so.*' -o -perm -u+x \) -print0 \
      | xargs -0 -r -n 200 sh -c 'ldd "$@" 2>/dev/null; true' ldd \
      | awk '$2 == "=>" && $3 ~ /^\// { print $3 }' | sort -u \
      | while read -r lib; do \
          case "$lib" in /usr/local/*) continue ;; esac; \
          for p in "$lib" "$(readlink -f "$lib")" "/usr${lib}" "${lib#/usr}"; do \
            pkg="$(dpkg -S "$p" 2>/dev/null | head -n1 | cut -d: -f1)" && [ -n "$pkg" ] && { echo "$pkg"; break; }; \
          done; \
        done \
      | grep -vE '^(libc6|libgcc-s1|libgcc1|libstdc\+\+6)$' | sort -u > /runtime-packages.txt; \
    echo "Runtime OS packages:"; cat /runtime-packages.txt

########################################################################################
FROM base-${COMPUTE} AS runtime
ARG VERSION=dev
ARG REVISION=unknown
ARG VARIANT=default
ARG MODEL_SOURCE
ARG MODELS_IMAGE
ARG BE_VERSION
ARG APP_VERSION_STRING
ARG INTEL_OPTIMIZATION=false
ARG GPU_IDX=-1
ARG FACE_DETECTION_PLUGIN="facenet.FaceDetector"
ARG CALCULATION_PLUGIN="facenet.Calculator"
ARG EXTRA_PLUGINS="facenet.LandmarksDetector,agegender.AgeDetector,agegender.GenderDetector,facenet.facemask.MaskDetector,facenet.PoseEstimator"
LABEL org.opencontainers.image.title="compreface-core" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.source="https://github.com/exadel-inc/CompreFace" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.vendor="mega (repackaged from Exadel CompreFace)" \
      id.co.bankmega.compreface.core.variant="${VARIANT}" \
      id.co.bankmega.compreface.core.model-source="${MODEL_SOURCE}:${MODELS_IMAGE}" \
      id.co.bankmega.compreface.core.face-detection-plugin="${FACE_DETECTION_PLUGIN}" \
      id.co.bankmega.compreface.core.calculation-plugin="${CALCULATION_PLUGIN}" \
      id.co.bankmega.compreface.core.extra-plugins="${EXTRA_PLUGINS}"

COPY --from=builder /runtime-packages.txt /tmp/runtime-packages.txt
# Hanya paket yang belum ada di base (base CUDA mem-"hold" libcudnn8/libnccl2 → jangan disentuh).
RUN apt-get update \
 && missing="$(while read -r p; do dpkg -s "$p" >/dev/null 2>&1 || echo "$p"; done < /tmp/runtime-packages.txt)" \
 && echo "install runtime packages: ${missing}" \
 && apt-get install -y --no-install-recommends curl ${missing} \
 && rm -rf /var/lib/apt/lists/* /tmp/runtime-packages.txt
COPY --from=builder /usr/local /usr/local
RUN ldconfig
COPY --from=builder /app/ml /app/ml
COPY services/compreface-core/uwsgi.ini /app/ml/uwsgi.ini
COPY LICENSE NOTICE /usr/share/licenses/compreface/

ENV HOME=/app/ml LC_ALL=C.UTF-8 LANG=C.UTF-8 PYTHONUNBUFFERED=0 JOBLIB_MULTIPROCESSING=0 \
    MPLCONFIGDIR=/tmp/matplotlib \
    BE_VERSION=${BE_VERSION} APP_VERSION_STRING=${APP_VERSION_STRING} \
    GPU_IDX=${GPU_IDX} INTEL_OPTIMIZATION=${INTEL_OPTIMIZATION} \
    FACE_DETECTION_PLUGIN=${FACE_DETECTION_PLUGIN} CALCULATION_PLUGIN=${CALCULATION_PLUGIN} \
    EXTRA_PLUGINS=${EXTRA_PLUGINS} \
    ML_PORT=3000 IMG_LENGTH_LIMIT=640 \
    UWSGI_PROCESSES=2 UWSGI_THREADS=1 \
    LOGGING_LEVEL_NAME=info

WORKDIR /app/ml
# www-data (uid 33) tersedia di base Debian & Ubuntu. File aplikasi & model milik root (read-only).
USER 33:33
EXPOSE 3000
HEALTHCHECK --interval=10s --timeout=5s --start-period=180s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${ML_PORT}/healthcheck" || exit 1
CMD ["uwsgi", "--ini", "/app/ml/uwsgi.ini"]
