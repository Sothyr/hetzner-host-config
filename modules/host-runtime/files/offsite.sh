#!/bin/bash
# Off-site copy with restic to S3 (Hetzner Object Storage). Runs from hhc-offsite.timer after the nightly dumps.
# /etc/hhc/offsite.env  KEY=value lines: RESTIC_REPOSITORY, RESTIC_PASSWORD, AWS_*, OFFSITE_IMAGE, KEEP_*  (mode 0600)
# /etc/hhc/offsite.paths  one absolute path per line, mounted read-only
# restic runs in a container, so the host needs no restic package.
set -euo pipefail

env_file=/etc/hhc/offsite.env
paths_file=/etc/hhc/offsite.paths
[ -f "$env_file" ] || { echo "offsite: $env_file is missing" >&2; exit 1; }

set -a
# shellcheck disable=SC1090
. "$env_file"
set +a

mkdir -p /var/cache/hhc-restic
mounts=()
paths=()
while IFS= read -r p; do
  [ -n "$p" ] || continue
  mounts+=(-v "$p:$p:ro")
  paths+=("$p")
done < "$paths_file"
[ "${#paths[@]}" -gt 0 ] || { echo "offsite: no paths" >&2; exit 1; }

restic() {
  podman run --rm --network host --hostname "$(hostname -s)" --security-opt label=disable \
    --env-file "$env_file" -v /var/cache/hhc-restic:/root/.cache/restic "${mounts[@]}" \
    --entrypoint restic "$OFFSITE_IMAGE" "$@"
}

# First run: create the repository.
if ! restic cat config >/dev/null 2>&1; then
  restic init
fi

restic backup --tag hhc "${paths[@]}"
restic forget --tag hhc --keep-daily "${KEEP_DAILY:-7}" --keep-weekly "${KEEP_WEEKLY:-4}" --keep-monthly "${KEEP_MONTHLY:-6}" --prune

# Integrity check once a week.
if [ "$(date +%u)" = "7" ]; then
  restic check
fi
echo "offsite: done"
