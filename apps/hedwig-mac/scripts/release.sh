#!/usr/bin/env bash
# Publishes the current commit of Hedwig to every Mac in the household:
#
#   pnpm hedwig:release
#
# See packages/burrow-kit/scripts/release.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
exec ../../packages/burrow-kit/scripts/release.sh . Hedwig hedwig
