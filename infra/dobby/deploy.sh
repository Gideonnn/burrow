#!/usr/bin/env bash
# Deploys origin/main to Dobby from the Mac:
#
#   ./infra/dobby/deploy.sh
#   DOBBY=other-host ./infra/dobby/deploy.sh
#
# It updates the checkout in ~/burrow on the host (cloning it the first time)
# and runs install.sh there, which builds, restarts the service and checks
# /health. Secrets are created and kept on the host itself.
set -euo pipefail

HOST="${DOBBY:-dobby}"
ssh "$HOST" 'set -e
  if [ ! -d burrow/.git ]; then git clone --quiet https://github.com/Gideonnn/burrow.git burrow; fi
  cd burrow
  git fetch --quiet origin
  git checkout --quiet --detach origin/main
  ./infra/dobby/install.sh'
