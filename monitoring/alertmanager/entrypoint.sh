#!/bin/sh
# Render /tmp/alertmanager.yml dari env lalu jalankan Alertmanager.
# Kanal aktif bila variabelnya terisi (boleh lebih dari satu):
#   email   : ALERT_EMAIL_TO + ALERT_SMTP_SMARTHOST (+ ALERT_EMAIL_FROM, ALERT_SMTP_USERNAME/PASSWORD, ALERT_SMTP_REQUIRE_TLS)
#   teams   : ALERT_MSTEAMS_WEBHOOK_URL (Workflows / Power Automate webhook)
#   webhook : ALERT_WEBHOOK_URL (POST JSON format Alertmanager)
# Tanpa kanal: alert tetap dikumpulkan & terlihat di UI Alertmanager, tidak dikirim ke mana pun.
set -eu

CFG=/tmp/alertmanager.yml
SECRETS=/tmp/secrets
mkdir -p "$SECRETS"
umask 077

# Nilai string YAML single-quoted
q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }

channels=""
{
  cat <<YAML
global:
  resolve_timeout: 5m

route:
  receiver: default
  group_by: [alertname, service]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: ${ALERT_REPEAT_INTERVAL:-4h}
  routes:
    - matchers: ['severity="critical"']
      receiver: default
      repeat_interval: ${ALERT_CRITICAL_REPEAT_INTERVAL:-1h}

inhibit_rules:
  # Service down → redam warning lain untuk service yang sama
  - source_matchers: ['alertname="ServiceDown"']
    target_matchers: ['severity="warning"']
    equal: [service]
  - source_matchers: ['alertname="PostgresDown"']
    target_matchers: ['alertname=~"PostgresConnectionsHigh|ScrapeTargetDown"']

receivers:
  - name: default
YAML

  if [ -n "${ALERT_EMAIL_TO:-}" ] && [ -n "${ALERT_SMTP_SMARTHOST:-}" ]; then
    channels="$channels email"
    echo "    email_configs:"
    echo "      - to: $(q "$ALERT_EMAIL_TO")"
    echo "        from: $(q "${ALERT_EMAIL_FROM:-CompreFace Alert <alert@example.internal>}")"
    echo "        smarthost: $(q "$ALERT_SMTP_SMARTHOST")"
    echo "        require_tls: ${ALERT_SMTP_REQUIRE_TLS:-true}"
    echo "        send_resolved: true"
    if [ -n "${ALERT_SMTP_USERNAME:-}" ]; then
      printf '%s' "${ALERT_SMTP_PASSWORD:-}" > "$SECRETS/smtp_password"
      echo "        auth_username: $(q "$ALERT_SMTP_USERNAME")"
      echo "        auth_password_file: $SECRETS/smtp_password"
    fi
  fi

  if [ -n "${ALERT_MSTEAMS_WEBHOOK_URL:-}" ]; then
    channels="$channels teams"
    printf '%s' "$ALERT_MSTEAMS_WEBHOOK_URL" > "$SECRETS/msteams_url"
    echo "    msteamsv2_configs:"
    echo "      - webhook_url_file: $SECRETS/msteams_url"
    echo "        send_resolved: true"
  fi

  if [ -n "${ALERT_WEBHOOK_URL:-}" ]; then
    channels="$channels webhook"
    printf '%s' "$ALERT_WEBHOOK_URL" > "$SECRETS/webhook_url"
    echo "    webhook_configs:"
    echo "      - url_file: $SECRETS/webhook_url"
    echo "        send_resolved: true"
  fi
} > "$CFG"

echo "alertmanager: kanal notifikasi aktif:${channels:- (tidak ada — alert hanya terlihat di UI)}"
amtool check-config "$CFG" >/dev/null

exec alertmanager \
  --config.file="$CFG" \
  --storage.path=/alertmanager \
  --web.external-url="${ALERTMANAGER_EXTERNAL_URL:-http://localhost:9093}" \
  "$@"
