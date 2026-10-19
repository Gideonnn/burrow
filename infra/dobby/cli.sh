#!/usr/bin/env bash
# Runs the server CLI with the installed settings loaded, e.g.:
#   ~/burrow/infra/dobby/cli.sh init Gideon
#   ~/burrow/infra/dobby/cli.sh list
set -euo pipefail
set -a
# shellcheck disable=SC1091
. "$HOME/.config/burrow/burrow.env"
set +a
exec node "$(cd "$(dirname "$0")/../.." && pwd)/apps/server/dist/cli.js" "$@"
