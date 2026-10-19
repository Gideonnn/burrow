#!/usr/bin/env bash
# Deploys the current origin/main to Dobby. Run on the Mac from the repository:
#
#   ./infra/dobby/deploy.sh               deploy
#   DOBBY=other-host ./infra/dobby/deploy.sh
#
# It decrypts infra/dobby/burrow.env.enc with SOPS locally and streams it to
# Dobby, so Dobby needs no age key and the plaintext never touches the Mac's
# disk. On Dobby the repository lives in ~/burrow.
set -euo pipefail
cd "$(dirname "$0")/../.."

HOST="${DOBBY:-dobby}"
REMOTE_DIR="burrow"
ENC="infra/dobby/burrow.env.enc"

[ -f "$ENC" ] || { echo "missing $ENC; see the deploy topic for the first setup" >&2; exit 1; }
command -v sops >/dev/null || { echo "sops is not installed" >&2; exit 1; }

echo "→ updating the checkout on $HOST"
ssh "$HOST" "set -e
  if [ ! -d $REMOTE_DIR/.git ]; then git clone https://github.com/Gideonnn/burrow.git $REMOTE_DIR; fi
  cd $REMOTE_DIR && git fetch --quiet origin && git checkout --quiet --detach origin/main
  mkdir -p infra/dobby/backups"

echo "→ writing the environment"
sops --decrypt --input-type dotenv --output-type dotenv "$ENC" |
  ssh "$HOST" "umask 077 && cat > $REMOTE_DIR/infra/dobby/burrow.env"

echo "→ building and starting"
ssh "$HOST" "cd $REMOTE_DIR/infra/dobby && docker compose up -d --build --remove-orphans && docker image prune -f >/dev/null"

echo "→ checking health"
for _ in $(seq 1 30); do
  if ssh "$HOST" "curl -fsS http://127.0.0.1:4717/health" 2>/dev/null; then echo; exit 0; fi
  sleep 2
done
echo "the server did not become healthy; look at: ssh $HOST 'cd $REMOTE_DIR/infra/dobby && docker compose logs --tail 50'" >&2
exit 1
