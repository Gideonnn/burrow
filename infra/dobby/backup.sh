#!/usr/bin/env bash
# Nightly backup on Dobby: a consistent copy of the database, encrypted with
# age to the recipients in backup-recipients.txt, keeping the last 30.
# Installed as a systemd timer by the deploy topic's first setup.
set -euo pipefail
cd "$(dirname "$0")"

stamp="$(date +%Y-%m-%d-%H%M)"
docker compose exec -T server node dist/cli.js backup "/backups/burrow-$stamp.sqlite" >/dev/null
age --encrypt --recipients-file backup-recipients.txt \
  --output "backups/burrow-$stamp.sqlite.age" "backups/burrow-$stamp.sqlite"
rm -f "backups/burrow-$stamp.sqlite"
ls -1t backups/burrow-*.sqlite.age | tail -n +31 | xargs -r rm -f
echo "backups/burrow-$stamp.sqlite.age"
