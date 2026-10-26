#!/usr/bin/env bash
# Publishes the current commit of one face of Hogsmeade to every Mac in the
# household:
#
#   pnpm hogsmeade:release          the native face (client `hogsmeade`)
#   pnpm hogsmeade:release:feest    the playful face (client `hogsmeade-feest`)
#
# See packages/burrow-kit/scripts/release.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
PRODUCT="${1:-Hogsmeade}"
case "$PRODUCT" in
  Hogsmeade) exec env BUNDLE_PRODUCT=Hogsmeade ../../packages/burrow-kit/scripts/release.sh . Hogsmeade hogsmeade ;;
  HogsmeadeFeest) exec env BUNDLE_PRODUCT=HogsmeadeFeest ../../packages/burrow-kit/scripts/release.sh . "Hogsmeade Feest" hogsmeade-feest ;;
  *) echo "✗ product is Hogsmeade or HogsmeadeFeest" >&2; exit 2 ;;
esac
