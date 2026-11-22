# shellcheck shell=bash
# Functions of the apply bundle. Sourced into the generated script, runs as root on the host.
# Every function is safe to run again. Nothing here deletes data volumes.

HHC_STATE=/var/lib/hhc
HHC_CHANGED=0

log() { printf '[hhc] %s\n' "$*"; }
die() { printf '[hhc] ERROR: %s\n' "$*" >&2; exit 1; }

hhc_wait_bootstrap() {
  if command -v cloud-init >/dev/null 2>&1; then
    cloud-init status --wait >/dev/null || log "cloud-init reports errors, see /var/log/cloud-init-output.log"
  fi
  [ -f "$HHC_STATE/bootstrap-done" ] || die "bootstrap of cloud-init is not finished"
  command -v podman-compose >/dev/null 2>&1 || die "podman-compose is missing"
  mkdir -p "$HHC_STATE/stacks"
}

# Starts a group of file writes. hhc_changed tells whether one of them changed a file.
hhc_begin() { HHC_CHANGED=0; }
hhc_changed() { [ "$HHC_CHANGED" -eq 1 ]; }

# hhc_put PATH MODE BASE64. Writes only when the content differs, atomically.
hhc_put() {
  local path="$1" mode="$2" data="$3" tmp
  mkdir -p "$(dirname "$path")"
  tmp="$(mktemp "$(dirname "$path")/.hhc.XXXXXX")"
  printf '%s' "$data" | base64 -d > "$tmp"
  chmod "$mode" "$tmp"
  if [ -f "$path" ] && cmp -s "$tmp" "$path" && [ "$(stat -c %a "$path")" = "$(stat -c %a "$tmp")" ]; then
    rm -f "$tmp"
    return 0
  fi
  mv -f "$tmp" "$path"
  HHC_CHANGED=1
  log "updated $path"
}

# Removes files in DIR that match GLOB and are not in the KEEP list (one path per line).
hhc_prune() {
  local dir="$1" glob="$2" keep="$3" f
  [ -d "$dir" ] || return 0
  shopt -s nullglob
  for f in "$dir"/$glob; do
    if ! grep -qxF "$f" <<<"$keep"; then
      rm -f "$f"
      HHC_CHANGED=1
      log "removed $f"
    fi
  done
  shopt -u nullglob
}

hhc_daemon_reload() { systemctl daemon-reload; }

# --- SSH users -------------------------------------------------------------------------------------------------

# hhc_users_sync ADMIN_USER LINES. LINES: "name sudo principal,principal" per user.
# Users that were managed before and are gone now are locked, their principals removed. Home folders stay.
hhc_users_sync() {
  local admin="$1" lines="$2" name sudo principals keep="" old
  getent group hhc-admins >/dev/null || groupadd --system hhc-admins
  hhc_begin
  hhc_put /etc/sudoers.d/90-hhc-admins 0440 "$(printf '%%hhc-admins ALL=(ALL) NOPASSWD: ALL\n' | base64 -w0)"
  visudo -cqf /etc/sudoers.d/90-hhc-admins || die "sudoers file is invalid"

  while read -r name sudo principals; do
    [ -n "$name" ] || continue
    [ "$name" = "$admin" ] && die "user $name is the bootstrap user and cannot be managed in users"
    keep="$keep$name"$'\n'
    if ! id "$name" >/dev/null 2>&1; then
      useradd --create-home --shell /bin/bash "$name"
      log "created user $name"
    fi
    passwd -l "$name" >/dev/null
    usermod --expiredate '' "$name"
    if [ "$sudo" = "true" ]; then usermod -aG hhc-admins "$name"; else gpasswd -d "$name" hhc-admins >/dev/null 2>&1 || true; fi
    hhc_put "/etc/ssh/auth_principals/$name" 0644 "$(tr ',' '\n' <<<"$principals" | base64 -w0)"
  done <<<"$lines"

  if [ -f "$HHC_STATE/users" ]; then
    while read -r old; do
      [ -n "$old" ] || continue
      grep -qxF "$old" <<<"$keep" && continue
      rm -f "/etc/ssh/auth_principals/$old"
      usermod --lock --expiredate 1 "$old" 2>/dev/null || true
      pkill -KILL -u "$old" 2>/dev/null || true
      log "locked removed user $old"
    done <"$HHC_STATE/users"
  fi
  printf '%s' "$keep" >"$HHC_STATE/users"
}

# --- firewalld -----------------------------------------------------------------------------------------------------

# Opens exactly the extra ports of the list (e.g. "9987/udp 30033/tcp") on top of ssh, http and https.
# Note: ports published by Podman bypass firewalld zones. The Hetzner firewall is the real gate for them.
hhc_firewalld_ports() {
  local want="$1" have p changed=0
  have="$(firewall-cmd --permanent --zone=public --list-ports)"
  for p in $want; do
    grep -qw -- "$p" <<<"$have" || { firewall-cmd --permanent --zone=public --add-port="$p" >/dev/null; changed=1; }
  done
  for p in $have; do
    grep -qw -- "$p" <<<"$want" || { firewall-cmd --permanent --zone=public --remove-port="$p" >/dev/null; changed=1; }
  done
  [ "$changed" -eq 1 ] && firewall-cmd --reload >/dev/null && log "firewalld ports: $want"
  return 0
}

# --- Podman networks -----------------------------------------------------------------------------------------------

hhc_network() {
  local name="$1" internal="$2"
  podman network exists "$name" && return 0
  if [ "$internal" = "true" ]; then podman network create --internal "$name" >/dev/null; else podman network create "$name" >/dev/null; fi
  log "created network $name"
}

# --- Compose stacks ------------------------------------------------------------------------------------------------

HHC_STACK_CHANGED=0

hhc_stack_begin() {
  HHC_STACK_CHANGED=0
  mkdir -p "/srv/stacks/$1"
  chmod 0750 "/srv/stacks/$1"
}

# Marks the stack as changed when the last hhc_put group changed something.
hhc_stack_mark() { hhc_changed && HHC_STACK_CHANGED=1; return 0; }

# hhc_git_sync NAME DIR URL REF KEYFILE. Checks out exactly REF into DIR. Same commit: tree stays as it is,
# including files patched by post_checkout. New commit: exact checkout, local edits of tracked files are reset.
hhc_git_sync() {
  local name="$1" dir="$2" url="$3" ref="$4" key="$5" before after
  local ssh_cmd="ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/srv/stacks/$name/known_hosts"
  [ -n "$key" ] && [ -f "$key" ] && ssh_cmd="$ssh_cmd -i $key -o IdentitiesOnly=yes"
  export GIT_SSH_COMMAND="$ssh_cmd"
  if [ ! -d "$dir/.git" ]; then
    mkdir -p "$dir"
    git init -q "$dir"
    git -C "$dir" remote add origin "$url"
  fi
  git -C "$dir" remote set-url origin "$url"
  before="$(git -C "$dir" rev-parse -q --verify HEAD || true)"
  git -C "$dir" fetch -q --depth 1 origin "$ref"
  after="$(git -C "$dir" rev-parse FETCH_HEAD)"
  unset GIT_SSH_COMMAND
  if [ "$before" != "$after" ]; then
    git -C "$dir" checkout -q --detach -f "$after"
    HHC_STACK_CHANGED=1
    log "stack $name: $dir at $ref ($after)"
  fi
}

# hhc_stack_post NAME BASE64_SCRIPT. Runs an idempotent script in the checkout, e.g. a config patch.
# The stack counts as changed when the script changes the working tree.
hhc_stack_post() {
  local name="$1" script="$2" dir="/srv/stacks/$1/src" before after
  [ -d "$dir/.git" ] || die "post_checkout of stack $name needs a git checkout"
  before="$(git -C "$dir" status --porcelain | sha256sum)"
  ( cd "$dir" && printf '%s' "$script" | base64 -d | bash -euo pipefail ) || die "post_checkout of stack $name failed"
  after="$(git -C "$dir" status --porcelain | sha256sum)"
  [ "$before" != "$after" ] && HHC_STACK_CHANGED=1
  return 0
}

# hhc_stack_end NAME WAS_ACTIVE. Starts a stack that was not running, applies changes to a running one.
hhc_stack_end() {
  local name="$1" was_active="$2" unit="hhc-stack@$1.service"
  restorecon -R "/srv/stacks/$name" >/dev/null
  systemctl enable -q "$unit"
  if [ "$was_active" != "1" ]; then
    if systemctl is-active -q "$unit"; then
      log "stack $name: already started as a dependency"
    else
      log "stack $name: starting"
      systemctl start "$unit" || die "stack $name failed to start, see: journalctl -u $unit"
    fi
  elif [ "$HHC_STACK_CHANGED" -eq 1 ]; then
    log "stack $name: applying changes"
    systemctl reload "$unit" || die "stack $name failed to apply, see: journalctl -u $unit"
  fi
}

# Stops stacks that are no longer in the list. Their folder moves aside, volumes stay untouched.
hhc_stacks_prune() {
  local keep="$1" dir name
  shopt -s nullglob
  for dir in /srv/stacks/*/; do
    name="$(basename "$dir")"
    grep -qxF "$name" <<<"$keep" && continue
    log "stack $name: removed from config, stopping (volumes are kept)"
    systemctl disable -q --now "hhc-stack@$name.service" || true
    rm -rf "/etc/systemd/system/hhc-stack@$name.service.d"
    mkdir -p /srv/stacks/.removed
    mv "$dir" "/srv/stacks/.removed/$name-$(date +%Y%m%d%H%M%S)"
  done
  shopt -u nullglob
}

# --- Edge routes (Caddy snippets) ----------------------------------------------------------------------------------

# Prints the folder of the snippets. A volume name is resolved to its mount point.
hhc_edge_dir() {
  local volume="$1" dir="$2"
  if [ -n "$volume" ]; then
    podman volume exists "$volume" || die "edge volume $volume does not exist yet, is the edge stack running?"
    podman volume inspect --format '{{.Mountpoint}}' "$volume"
  else
    mkdir -p "$dir"
    printf '%s' "$dir"
  fi
}

# Validates the whole Caddyfile inside the running edge container, then reloads it gracefully.
hhc_edge_reload() {
  local container="$1" caddyfile="$2"
  podman container exists "$container" || die "edge container $container is not running"
  podman exec "$container" caddy validate --config "$caddyfile" --adapter caddyfile >/dev/null \
    || die "Caddy rejects the new config. The running config stays active."
  podman exec "$container" caddy reload --config "$caddyfile" --adapter caddyfile >/dev/null
  log "edge reloaded"
}

# Keeps a copy of the managed snippets, so a rejected config can be rolled back.
hhc_edge_backup() {
  local dir="$1"
  HHC_EDGE_BACKUP="$(mktemp -d)"
  shopt -s nullglob
  for f in "$dir"/hhc-*.caddy; do cp -p "$f" "$HHC_EDGE_BACKUP/"; done
  shopt -u nullglob
}

hhc_edge_restore() {
  local dir="$1"
  rm -f "$dir"/hhc-*.caddy
  shopt -s nullglob
  for f in "$HHC_EDGE_BACKUP"/hhc-*.caddy; do cp -p "$f" "$dir/"; done
  shopt -u nullglob
  log "edge snippets restored to the last working state"
}

# hhc_edge_apply DIR CONTAINER CADDYFILE. Reloads when snippets changed. Restores the old ones on failure.
hhc_edge_apply() {
  local dir="$1" container="$2" caddyfile="$3"
  hhc_changed || { rm -rf "$HHC_EDGE_BACKUP"; return 0; }
  if ! ( hhc_edge_reload "$container" "$caddyfile" ); then
    hhc_edge_restore "$dir"
    rm -rf "$HHC_EDGE_BACKUP"
    die "edge config rejected, nothing changed on the running proxy"
  fi
  rm -rf "$HHC_EDGE_BACKUP"
}

# --- HAProxy -------------------------------------------------------------------------------------------------------

# hhc_haproxy_apply BASE64_CONFIG. Checks the new config before it replaces the running one.
hhc_haproxy_apply() {
  local data="$1" cfg=/etc/haproxy/haproxy.cfg new=/etc/haproxy/haproxy.cfg.hhc-new
  command -v haproxy >/dev/null 2>&1 || dnf install -y -q haproxy
  # HAProxy must reach Caddy on 127.0.0.1:8080 and 8443. SELinux stays enforcing.
  [ "$(getsebool haproxy_connect_any | awk '{print $3}')" = "on" ] || setsebool -P haproxy_connect_any 1
  printf '%s' "$data" | base64 -d > "$new"
  chmod 0644 "$new"
  if [ -f "$cfg" ] && cmp -s "$new" "$cfg"; then
    rm -f "$new"
  else
    haproxy -c -q -f "$new" || { rm -f "$new"; die "HAProxy rejects the new config. The running config stays active."; }
    mv -f "$new" "$cfg"
    restorecon "$cfg"
    log "updated $cfg"
    systemctl is-active -q haproxy && systemctl reload haproxy
  fi
  systemctl enable -q --now haproxy
}

# --- Backups -------------------------------------------------------------------------------------------------------

# Installs the dump script and its timer. Jobs are shell commands that write a dump to stdout.
hhc_backup_setup() {
  local on_calendar="$1" keep_days="$2"
  hhc_begin
  hhc_put /etc/systemd/system/hhc-backup.service 0644 "$(printf '[Unit]\nDescription=Dumps of the databases (hetzner-host-config)\n\n[Service]\nType=oneshot\nExecStart=/usr/local/libexec/hhc/backup %s\n' "$keep_days" | base64 -w0)"
  hhc_put /etc/systemd/system/hhc-backup.timer 0644 "$(printf '[Unit]\nDescription=Dumps of the databases before the Hetzner backup window\n\n[Timer]\nOnCalendar=%s\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n' "$on_calendar" | base64 -w0)"
  hhc_changed && hhc_daemon_reload
  systemctl enable -q --now hhc-backup.timer
}

# Off-site copy with restic. hhc_offsite_setup ON_CALENDAR SCRIPT_B64 ENV_B64 PATHS_B64
hhc_offsite_setup() {
  local on_calendar="$1" script="$2" env="$3" paths="$4"
  hhc_begin
  hhc_put /usr/local/libexec/hhc/offsite 0755 "$script"
  hhc_put /etc/hhc/offsite.env 0600 "$env"
  hhc_put /etc/hhc/offsite.paths 0644 "$paths"
  hhc_put /etc/systemd/system/hhc-offsite.service 0644 "$(printf '[Unit]\nDescription=Off-site copy of the backups with restic (hetzner-host-config)\nAfter=hhc-backup.service network-online.target\nWants=network-online.target\n\n[Service]\nType=oneshot\nTimeoutStartSec=4h\nExecStart=/usr/local/libexec/hhc/offsite\n' | base64 -w0)"
  hhc_put /etc/systemd/system/hhc-offsite.timer 0644 "$(printf '[Unit]\nDescription=Off-site copy of the backups\n\n[Timer]\nOnCalendar=%s\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n' "$on_calendar" | base64 -w0)"
  hhc_changed && hhc_daemon_reload
  systemctl enable -q --now hhc-offsite.timer
}

# Off-site copy switched off: stops the timer and removes the credentials from the host. The repository stays where it is.
hhc_offsite_remove() {
  if [ -f /etc/systemd/system/hhc-offsite.timer ]; then
    systemctl disable -q --now hhc-offsite.timer || true
    rm -f /etc/systemd/system/hhc-offsite.timer /etc/systemd/system/hhc-offsite.service
    hhc_daemon_reload
    log "off-site copy switched off"
  fi
  rm -f /etc/hhc/offsite.env /etc/hhc/offsite.paths
}
