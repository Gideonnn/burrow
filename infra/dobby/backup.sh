#!/usr/bin/env bash
# Nightly backup: a consistent copy of the database, encrypted with age when
# backup-recipients.txt exists next to this script (one age public key per
# line), keeping the last 30. Runs from the burrow-backup timer that
# install.sh sets up, with the server's environment loaded.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dir="${BURROW_DATA_DIR:?}/backups"
mkdir -p "$dir"

stamp="$(date +%Y-%m-%d-%H%M)"
copy="$dir/burrow-$stamp.sqlite"
node "$here/../../apps/server/dist/cli.js" backup "$copy" >/dev/null

if [ -s "$here/backup-recipients.txt" ] && command -v age >/dev/null; then
  age --encrypt --recipients-file "$here/backup-recipients.txt" --output "$copy.age" "$copy"
  rm -f "$copy"
  copy="$copy.age"
fi
ls -1t "$dir"/burrow-*.sqlite* | tail -n +31 | xargs -r rm -f
echo "$copy"
