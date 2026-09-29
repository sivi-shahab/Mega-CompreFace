# syntax=docker/dockerfile:1.7
#
# compreface-postgres-db — PostgreSQL 11.5 + init script CompreFace.
# Build context: root repo  (docker build -f services/compreface-postgres-db/Dockerfile .)
#
# Major version sengaja tetap 11 (sama dengan data live, lihat SPEC R-03). Single stage:
# tidak ada artefak yang perlu di-compile, sehingga multi-stage tidak memberi manfaat.
# Entrypoint resmi postgres turun ke user "postgres" (uid 999) via gosu; di Kubernetes
# container langsung dijalankan sebagai uid 999 (securityContext) — keduanya didukung.

ARG POSTGRES_IMAGE=postgres:11.5@sha256:b3770d9c4ef11eba1ff5893e28049e98e2b70083e519e0b2bce0a20e7aa832fe
FROM ${POSTGRES_IMAGE}
ARG VERSION=dev
ARG REVISION=unknown
LABEL org.opencontainers.image.title="compreface-postgres-db" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.source="https://github.com/exadel-inc/CompreFace" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.vendor="mega (repackaged from Exadel CompreFace)"

COPY db/initdb.sql /docker-entrypoint-initdb.d/initdb.sql
COPY LICENSE NOTICE /usr/share/licenses/compreface/

# Subdirektori agar aman dipakai di PVC yang berisi lost+found.
ENV PGDATA=/var/lib/postgresql/data/pgdata \
    POSTGRES_DB=frs

EXPOSE 5432
HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --retries=5 \
  CMD pg_isready -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-frs}" -h 127.0.0.1 || exit 1
