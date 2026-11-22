#!/usr/bin/env bash
# Moves nginx behind HAProxy on a host that serves other sites with nginx today.
#
#   convert   Back up /etc/nginx, move the listeners to 127.0.0.1:8180 (http) and 127.0.0.1:8543 (https)
#             with PROXY protocol, add the real-ip settings, run nginx -t. Does not reload nginx.
#   switch    Reload nginx (frees ports 80 and 443), start HAProxy on them. Rolls back when HAProxy does not come up.
#   restore   Stop HAProxy, put the last backup back, reload nginx on ports 80 and 443.
#   check     Ask every host name of the nginx config through HAProxy and print the status codes.
#
# Run as root on the server. Needs the HAProxy config at /etc/haproxy/haproxy.cfg first (see docs/runbook-ludite-umzug.md).
# Variables: NGINX_DIR (default /etc/nginx), BACKUP_ROOT (default /root), HTTP_PORT (8180), HTTPS_PORT (8543), SKIP_NGINX_TEST=1 for tests.
set -euo pipefail

NGINX_DIR="${NGINX_DIR:-/etc/nginx}"
BACKUP_ROOT="${BACKUP_ROOT:-/root}"
HTTP_PORT="${HTTP_PORT:-8180}"
HTTPS_PORT="${HTTPS_PORT:-8543}"
MARKER="# haproxy-edge:"
REALIP="$NGINX_DIR/conf.d/00-haproxy-edge.conf"

die() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || [ "${SKIP_NGINX_TEST:-0}" = "1" ] || die "Run as root."; }

latest_backup() { ls -1d "$BACKUP_ROOT"/nginx-before-haproxy-* 2>/dev/null | tail -1; }

reload_nginx() {
  if [ "${SKIP_NGINX_TEST:-0}" = "1" ]; then return 0; fi
  nginx -s reload
}

nginx_test() {
  if [ "${SKIP_NGINX_TEST:-0}" = "1" ]; then return 0; fi
  nginx -t
}

config_files() {
  echo "$NGINX_DIR/nginx.conf"
  find "$NGINX_DIR/conf.d" -maxdepth 1 -name '*.conf' ! -name '00-haproxy-edge.conf' | sort
}

# Listen lines that still bind a public address. Commented lines do not count.
leftovers() {
  config_files | xargs grep -nE '^\s*listen\s' | grep -vE 'listen\s+127\.0\.0\.1:' || true
}

convert() {
  need_root
  [ ! -f "$REALIP" ] || die "Already converted. Run '$0 restore' first if you want to start again."
  local backup="$BACKUP_ROOT/nginx-before-haproxy-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup"
  cp -a "$NGINX_DIR/." "$backup/"
  echo "Backup: $backup"

  while read -r file; do
    sed -E -i \
      -e "s/^(\s*)(listen\s+\[::\]:[0-9]+[^;]*;)/\1$MARKER \2/" \
      -e "s/^(\s*)listen\s+80\s*;/\1listen 127.0.0.1:$HTTP_PORT proxy_protocol;/" \
      -e "s/^(\s*)listen\s+80\s+([^;]*);/\1listen 127.0.0.1:$HTTP_PORT proxy_protocol \2;/" \
      -e "s/^(\s*)listen\s+443\s+([^;]*);/\1listen 127.0.0.1:$HTTPS_PORT proxy_protocol \2;/" \
      "$file"
  done < <(config_files)

  cat > "$REALIP" <<CONF
# HAProxy sits in front and sends the PROXY protocol. Without this nginx logs 127.0.0.1 for every visitor.
set_real_ip_from 127.0.0.1;
real_ip_header proxy_protocol;
CONF

  local rest
  rest="$(leftovers)"
  if [ -n "$rest" ]; then
    echo "These listen lines were not converted:" >&2
    echo "$rest" >&2
    restore_from "$backup"
    die "Config restored from the backup. Convert those lines by hand or extend the script."
  fi
  if ! nginx_test; then
    restore_from "$backup"
    die "nginx -t failed. Config restored from the backup."
  fi
  echo "Converted. nginx still runs on the old ports. Next: haproxy -c -f /etc/haproxy/haproxy.cfg, then '$0 switch'."
}

restore_from() {
  local backup="$1"
  [ -d "$backup" ] || die "No backup in $BACKUP_ROOT."
  rm -f "$REALIP"
  cp -a "$backup/." "$NGINX_DIR/"
}

wait_free() {
  local port="$1" i
  for i in $(seq 1 20); do
    if ! ss -ltn "sport = :$port" | grep -q LISTEN; then return 0; fi
    sleep 0.5
  done
  return 1
}

switch() {
  need_root
  haproxy -c -f /etc/haproxy/haproxy.cfg
  nginx_test
  [ -z "$(leftovers)" ] || die "nginx is not converted yet. Run '$0 convert' first."
  reload_nginx
  if ! wait_free 80 || ! wait_free 443; then
    echo "Ports 80 or 443 are still taken after the reload. Rolling back." >&2
    restore; die "Rolled back."
  fi
  if ! systemctl enable --now haproxy; then
    echo "HAProxy did not start. Rolling back." >&2
    restore; die "Rolled back."
  fi
  sleep 1
  if ! systemctl is-active --quiet haproxy; then
    echo "HAProxy is not active. Rolling back." >&2
    restore; die "Rolled back."
  fi
  echo "HAProxy owns ports 80 and 443. Run '$0 check'."
}

restore() {
  need_root
  systemctl stop haproxy 2>/dev/null || true
  restore_from "$(latest_backup)"
  nginx_test
  reload_nginx
  echo "nginx is back on ports 80 and 443."
}

check() {
  local hosts host code
  hosts="$(nginx -T 2>/dev/null | grep -oE 'server_name\s+[^;]+' | sed -E 's/server_name\s+//' | tr ' ' '\n' | grep -vE '^(_|)$|\*' | sort -u)"
  for host in $hosts; do
    code="$(curl -sk -o /dev/null -m 10 -w '%{http_code}' --resolve "$host:443:127.0.0.1" "https://$host/" || true)"
    printf '%-45s https %s\n' "$host" "$code"
  done
  echo "000 means no answer. 3xx and 401 are normal for redirects and password protected sites."
}

case "${1:-}" in
  convert) convert ;;
  switch) switch ;;
  restore) restore ;;
  check) check ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac
