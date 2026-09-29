# syntax=docker/dockerfile:1.7
#
# compreface-admin — Spring Boot (modul java/admin + java/common), non-root.
# Build context: root repo  (docker build -f services/compreface-admin/Dockerfile .)
# Ignore file  : services/compreface-admin/Dockerfile.dockerignore (BuildKit)
#
# Catatan: APPERY_API_KEY (telemetry upstream ke api.appery.io) sengaja TIDAK di-bake.

ARG MAVEN_IMAGE=maven:3.8.2-eclipse-temurin-17@sha256:154dd1166c8ff0050f406899465b570fd6861b7266d0bd6276427314ce10276c
ARG JRE_IMAGE=eclipse-temurin:17.0.8_7-jre-focal@sha256:fec0b0f6cb7d2c41c0381c6828211a5adedb1ed6822d3f8209596042a9c606e7

### STAGE 1: build ###
FROM ${MAVEN_IMAGE} AS build
WORKDIR /workspace/compreface
# Layer dependency: hanya pom → cache Maven tetap valid selama pom tidak berubah.
COPY java/pom.xml ./
COPY java/common/pom.xml common/
COPY java/admin/pom.xml admin/
COPY java/api/pom.xml api/
RUN --mount=type=cache,target=/root/.m2 \
    mvn -B -q -pl admin -am dependency:go-offline -Dmaven.gitcommitid.skip || true
COPY java/common common
COPY java/admin admin
RUN --mount=type=cache,target=/root/.m2 \
    mvn -B -pl admin -am package \
      -Dmaven.test.skip=true -Dmaven.site.skip=true -Dmaven.javadoc.skip=true \
      -Dcheckstyle.skip -Djacoco.skip -Dmaven.gitcommitid.skip \
 && cp admin/target/frs-crud-app-*.jar /workspace/app.jar

### STAGE 2: runtime ###
FROM ${JRE_IMAGE}
ARG VERSION=dev
ARG REVISION=unknown
LABEL org.opencontainers.image.title="compreface-admin" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.source="https://github.com/exadel-inc/CompreFace" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.vendor="mega (repackaged from Exadel CompreFace)"

RUN groupadd --system --gid 1001 app \
 && useradd --system --uid 1001 --gid app --home-dir /app --shell /usr/sbin/nologin app \
 && apt-get update && apt-get install -y --no-install-recommends curl \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build --chown=0:0 /workspace/app.jar /app/app.jar
COPY LICENSE NOTICE /usr/share/licenses/compreface/

# Default non-rahasia (override via env / ConfigMap). Credential WAJIB dari env/Secret.
ENV ADMIN_JAVA_OPTS="-XX:MaxRAMPercentage=75.0" \
    SPRING_PROFILES_ACTIVE=dev \
    MANAGEMENT_SERVER_PORT=8081 \
    MANAGEMENT_HEALTH_MAIL_ENABLED=false \
    MANAGEMENT_ENDPOINT_HEALTH_PROBES_ENABLED=true \
    ENABLE_EMAIL_SERVER=false \
    PYTHON_URL=http://compreface-core:3000

USER 1001
EXPOSE 8080 8081
HEALTHCHECK --interval=15s --timeout=5s --start-period=120s --retries=5 \
  CMD curl -fsS http://127.0.0.1:${MANAGEMENT_SERVER_PORT}/actuator/health/liveness || exit 1
ENTRYPOINT ["sh", "-c", "exec java $ADMIN_JAVA_OPTS -jar /app/app.jar"]
