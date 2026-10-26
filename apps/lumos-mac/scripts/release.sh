#!/usr/bin/env bash
# Publishes the current commit of Lumos to every Mac in the household:
#
#   pnpm lumos:release
#
# See packages/burrow-kit/scripts/release.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
exec ../../packages/burrow-kit/scripts/release.sh . Lumos lumos
