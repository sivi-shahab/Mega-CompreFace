#!/bin/sh
# Menyiapkan env untuk envsubst sebelum entrypoint resmi nginx dijalankan.
#  - NGINX_RESOLVER    : jika kosong, diambil dari nameserver pertama di /etc/resolv.conf
#                        (docker: 127.0.0.11, kubernetes: IP kube-dns).
#  - *_UPSTREAM        : resolver nginx TIDAK memakai "search" domain. Jika
#                        NGINX_UPSTREAM_AUTO_FQDN=true dan host tanpa titik, domain search
#                        pertama ditambahkan (mis. <ns>.svc.cluster.local), kecuali di DNS docker.
set -eu

first_nameserver() {
  awk '/^nameserver/ { print $2; exit }' /etc/resolv.conf 2>/dev/null
}

first_search_domain() {
  awk '/^search/ { print $2; exit }' /etc/resolv.conf 2>/dev/null
}

if [ -z "${NGINX_RESOLVER:-}" ]; then
  NGINX_RESOLVER="$(first_nameserver)"
  [ -n "$NGINX_RESOLVER" ] || NGINX_RESOLVER="127.0.0.11"
fi
case "$NGINX_RESOLVER" in
  *:*:*) case "$NGINX_RESOLVER" in \[*) ;; *) NGINX_RESOLVER="[$NGINX_RESOLVER]" ;; esac ;;
esac

qualify() {
  upstream="$1"
  host="${upstream%%:*}"
  port="${upstream#*:}"
  [ "$port" = "$upstream" ] && port=""
  if [ "${NGINX_UPSTREAM_AUTO_FQDN:-true}" = "true" ] && [ "$NGINX_RESOLVER" != "127.0.0.11" ]; then
    case "$host" in
      *.*) ;;
      *)
        domain="$(first_search_domain)"
        [ -n "$domain" ] && host="${host}.${domain}"
        ;;
    esac
  fi
  if [ -n "$port" ]; then echo "${host}:${port}"; else echo "$host"; fi
}

ADMIN_UPSTREAM="$(qualify "$ADMIN_UPSTREAM")"
API_UPSTREAM="$(qualify "$API_UPSTREAM")"
export NGINX_RESOLVER ADMIN_UPSTREAM API_UPSTREAM

echo "compreface-fe: resolver=${NGINX_RESOLVER} admin=${ADMIN_UPSTREAM} api=${API_UPSTREAM}"
exec /docker-entrypoint.sh "$@"
