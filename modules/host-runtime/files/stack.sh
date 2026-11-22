#!/bin/bash
# Runs one compose stack. Called by the unit hhc-stack@NAME.service and by the update timer.
#   stack up NAME      start, pulls only missing images, builds nothing new (boot)
#   stack apply NAME   pull, build when BUILD=1, recreate. Used after a config change (systemctl reload)
#   stack down NAME    stop, volumes stay
#   stack update NAME  pull, recreate only when an image changed (auto-update timer)
#   stack update-all   update every stack with AUTO_UPDATE=1
# Jobs (JOB_SERVICES) are one-shot services of another compose project, run before the stack starts,
# e.g. the register jobs of a sothyr-pages club in the platform project. They must be safe to run again.
set -euo pipefail

export REGISTRY_AUTH_FILE=/etc/hhc/registry-auth.json

log() { printf '[stack %s] %s\n' "${NAME:-}" "$*"; }

load() {
  NAME="$1"
  DIR="/srv/stacks/$NAME"
  [ -f "$DIR/hhc.conf" ] || { echo "unknown stack $NAME" >&2; exit 1; }
  # shellcheck source=/dev/null
  . "$DIR/hhc.conf"
  set -a
  # shellcheck source=/dev/null
  . "$DIR/hhc.env"
  set +a
  cd "$WORKDIR"
}

compose() {
  local args=(-p "$PROJECT") f p
  for f in "${COMPOSE_FILES[@]}"; do args+=(-f "$f"); done
  args+=(--env-file "$DIR/hhc.env")
  for p in "${PROFILES[@]}"; do args+=(--profile "$p"); done
  podman-compose "${args[@]}" "$@"
}

run_jobs() {
  [ "${#JOB_SERVICES[@]}" -gt 0 ] || return 0
  (
    set -a
    # shellcheck source=/dev/null
    . "$DIR/hhc.jobs.env"
    set +a
    local args=(-p "$JOB_PROJECT") f p job
    for f in "${JOB_FILES[@]}"; do args+=(-f "$f"); done
    args+=(--env-file "$DIR/hhc.jobs.env")
    for p in "${JOB_PROFILES[@]}"; do args+=(--profile "$p"); done
    for job in "${JOB_SERVICES[@]}"; do
      log "job $job"
      podman-compose "${args[@]}" run --rm "$job"
    done
  )
  touch "$DIR/.jobs-done"
}

pull_missing() {
  local image
  for image in "${PULL[@]}"; do
    podman image exists "$image" || podman pull -q "$image" >/dev/null
  done
}

pull_all() {
  local image
  for image in "${PULL[@]}"; do podman pull -q "$image" >/dev/null; done
  compose pull >/dev/null 2>&1 || log "compose pull reported errors, local images are used"
}

build_flag() { [ "${BUILD:-0}" = "1" ] && printf -- '--build'; }

project_images() {
  podman ps -a --filter "label=io.podman.compose.project=$PROJECT" --format '{{.Image}}' | sort -u
}

image_ids() {
  local image
  for image in "$@"; do printf '%s=%s\n' "$image" "$(podman image inspect --format '{{.Id}}' "$image" 2>/dev/null || true)"; done
}

cmd="${1:-}"
case "$cmd" in
  up)
    load "$2"
    pull_missing
    [ -f "$DIR/.jobs-done" ] || run_jobs
    compose up -d
    ;;
  apply)
    load "$2"
    pull_all
    run_jobs
    # shellcheck disable=SC2046
    compose up -d --force-recreate $(build_flag)
    ;;
  down)
    load "$2"
    compose down
    ;;
  update)
    load "$2"
    mapfile -t images < <(project_images)
    before="$(image_ids "${images[@]}" "${PULL[@]}")"
    pull_all
    after="$(image_ids "${images[@]}" "${PULL[@]}")"
    if [ "$before" != "$after" ]; then
      log "new images found, recreating"
      compose up -d --force-recreate
      podman image prune -f >/dev/null
    else
      log "images are current"
    fi
    ;;
  update-all)
    status=0
    for conf in /srv/stacks/*/hhc.conf; do
      [ -f "$conf" ] || continue
      grep -qx 'AUTO_UPDATE=1' "$conf" || continue
      name="$(basename "$(dirname "$conf")")"
      "$0" update "$name" || { echo "update of $name failed" >&2; status=1; }
    done
    exit "$status"
    ;;
  *)
    echo "usage: stack up|apply|down|update NAME | stack update-all" >&2
    exit 2
    ;;
esac
