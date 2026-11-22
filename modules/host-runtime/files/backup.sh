#!/bin/bash
# Nightly dumps. Every file in /etc/hhc/backup-jobs/NAME.sh prints one dump to stdout.
# Dumps go to /srv/backup/NAME/, gzip compressed. Older than KEEP_DAYS days are removed.
# The Hetzner VM backup afterwards contains consistent dumps instead of open database files.
set -uo pipefail

keep_days="${1:-3}"
stamp="$(date +%Y%m%d-%H%M%S)"
status=0

for job in /etc/hhc/backup-jobs/*.sh; do
  [ -f "$job" ] || continue
  name="$(basename "$job" .sh)"
  dir="/srv/backup/$name"
  mkdir -p "$dir"
  chmod 0700 "$dir"
  out="$dir/$name-$stamp.gz"
  if bash "$job" | gzip > "$out.part"; then
    mv "$out.part" "$out"
    echo "backup $name: $(du -h "$out" | cut -f1)"
  else
    rm -f "$out.part"
    echo "backup $name FAILED" >&2
    status=1
  fi
  find "$dir" -name "$name-*.gz" -mtime +"$keep_days" -delete
done

exit "$status"
