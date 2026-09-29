# syntax=docker/dockerfile:1.7
#
# compreface-fe — Angular SPA + nginx reverse proxy (non-root).
# Build context: root repo  (docker build -f services/compreface-fe/Dockerfile .)
# Ignore file  : services/compreface-fe/Dockerfile.dockerignore (BuildKit)

ARG NODE_IMAGE=node:12.22.12@sha256:01627afeb110b3054ba4a1405541ca095c8bfca1cb6f2be9479c767a2711879e
ARG NGINX_IMAGE=nginxinc/nginx-unprivileged:1.21.1@sha256:a27b272f1500ad4cec8dcbf24c8c1db8efbd79849a36e9c9e8cc322a33bddfdc

### STAGE 1: build Angular ###
FROM ${NODE_IMAGE} AS build
WORKDIR /usr/src/app
# Dependency layer terpisah agar cache tetap valid selama package.json tidak berubah.
COPY ui/package.json ./
RUN npm install --no-audit --no-fund
COPY ui/ ./
RUN npm run build:prod

### STAGE 2: runtime ###
FROM ${NGINX_IMAGE}
ARG VERSION=dev
ARG REVISION=unknown
LABEL org.opencontainers.image.title="compreface-fe" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.source="https://github.com/exadel-inc/CompreFace" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.vendor="mega (repackaged from Exadel CompreFace)"

USER root
RUN rm -f /etc/nginx/conf.d/default.conf
COPY ui/nginx/mime.types /etc/nginx/mime.types
COPY services/compreface-fe/nginx.conf /etc/nginx/nginx.conf
COPY services/compreface-fe/nginx.conf.template /etc/nginx/templates/nginx.conf.template
COPY --chmod=0755 services/compreface-fe/docker-entrypoint-fe.sh /usr/local/bin/docker-entrypoint-fe.sh
COPY --from=build /usr/src/app/dist/compreface /usr/share/nginx/html
COPY LICENSE NOTICE /usr/share/licenses/compreface/
# envsubst menulis ke conf.d saat start → harus writable oleh uid 101.
RUN chown -R 101:0 /etc/nginx/conf.d && chmod -R g+w /etc/nginx/conf.d
USER 101

# Default non-rahasia; override lewat env / ConfigMap.
ENV ADMIN_UPSTREAM=compreface-admin:8080 \
    API_UPSTREAM=compreface-api:8080 \
    NGINX_RESOLVER="" \
    NGINX_RESOLVER_VALID=10s \
    NGINX_UPSTREAM_AUTO_FQDN=true \
    CLIENT_MAX_BODY_SIZE=10M \
    PROXY_READ_TIMEOUT=60000ms \
    PROXY_CONNECT_TIMEOUT=10000ms

EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
  CMD curl -fsS http://127.0.0.1:8080/healthz || exit 1
ENTRYPOINT ["/usr/local/bin/docker-entrypoint-fe.sh"]
CMD ["nginx", "-g", "daemon off;"]
