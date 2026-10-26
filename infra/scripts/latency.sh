#!/usr/bin/env bash
# Measures how fast the live server answers the routes the Macs lean on,
# from this machine, with a real key. The key is read from the environment,
# never typed into a command:
#
#   BURROW_SERVER=https://burrow.example.nl BURROW_KEY=bk_… infra/scripts/latency.sh
#
# Prints the median and the slowest of five calls per route, in ms. Seerr
# answers come from its cache after the first call, so run it twice to see
# the warm numbers.
set -euo pipefail
: "${BURROW_SERVER:?set BURROW_SERVER}"
: "${BURROW_KEY:?set BURROW_KEY}"

routes=(
  "/api/me"
  "/api/lumos/status"
  "/api/lumos/rows"
  "/api/lumos/explore?seed=1"
  "/api/lumos/browse?type=movie&sort=popular"
  "/api/lumos/browse?type=tv&sort=top"
  "/api/lumos/search?q=spider"
  "/api/lumos/lists/shared"
  "/api/outings"
)

printf '%-48s %8s %8s\n' route median slowest
for route in "${routes[@]}"; do
  times=()
  for _ in 1 2 3 4 5; do
    t=$(curl -s -o /dev/null -w '%{time_total}' -H "Authorization: Bearer $BURROW_KEY" "$BURROW_SERVER$route")
    times+=("$t")
  done
  sorted=$(printf '%s\n' "${times[@]}" | sort -n)
  median=$(echo "$sorted" | sed -n 3p)
  slowest=$(echo "$sorted" | tail -1)
  printf '%-48s %7.0fms %7.0fms\n' "$route" "$(echo "$median * 1000" | bc)" "$(echo "$slowest * 1000" | bc)"
done
